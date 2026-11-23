import Foundation

/// Twenty-byte legacy Swing Caddie frame. All fields retain wire byte order.
/// Framing/command identities were corroborated with the installed MySwingCaddie
/// v3.7.0 by the parent investigation; related public implementations are:
/// https://github.com/maxwelltollefson/SC300i-OGS-Plugin/blob/main/index.js
/// SC4Pro uses a different service, so its initializer/control commands are not used.
struct SC4Frame: Equatable {
    let command: UInt8
    let payload: [UInt8]
    let raw: Data

    var shotIndex: UInt16 { UInt16(payload[0]) | (UInt16(payload[1]) << 8) }
    var sequence: UInt8 { payload[2] }

    init?(raw: Data) {
        let bytes = [UInt8](raw)
        guard bytes.count == 20, bytes[0] == 0x53, bytes[18] == 0x45,
              bytes.reduce(UInt8(0), { $0 &+ $1 }) == 0 else { return nil }
        self.command = bytes[1]
        self.payload = Array(bytes[2...17])
        self.raw = raw
    }
}

/// Incremental decoder: GATT may fragment or coalesce protocol frames.
/// Storage is bounded independently of input size; invalid candidates never emit.
struct SC4FrameDecoder {
    private var buffer: [UInt8] = []
    private let processingChunkSize = 1024
    private(set) var rejectedCandidateCount = 0
    private(set) var discardedByteCount = 0
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) -> [SC4Frame] {
        var result: [SC4Frame] = []
        for byte in data {
            buffer.append(byte)
            if buffer.count >= processingChunkSize { drain(into: &result) }
        }
        drain(into: &result)
        return result
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    private mutating func drain(into result: inout [SC4Frame]) {
        var offset = 0
        while buffer.count - offset >= 20 {
            guard buffer[offset] == 0x53 else {
                offset += 1
                discardedByteCount &+= 1
                continue
            }
            if let frame = SC4Frame(raw: Data(buffer[offset..<(offset + 20)])) {
                result.append(frame)
                offset += 20
            } else {
                rejectedCandidateCount &+= 1
                discardedByteCount &+= 1
                offset += 1
            }
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }
}

/// The send surface deliberately exposes only the validated read/shot-pull
/// requests. There is no deletion (0x44), firmware, mode, club or EQ builder.
enum SC4Wire {
    static func deviceInfoRequest() -> Data {
        make(command: 0x64, payload: [UInt8](repeating: 0, count: 16))
    }

    static func shotSequenceACK(index: UInt16, sequence: UInt8) -> Data? {
        guard (1...5).contains(sequence) else { return nil }
        var payload = [UInt8](repeating: 0, count: 16)
        payload[0] = UInt8(truncatingIfNeeded: index)
        payload[1] = UInt8(truncatingIfNeeded: index >> 8)
        payload[2] = sequence
        return make(command: 0x73, payload: payload)
    }

    static func shotSequenceACK(for frame: SC4Frame) -> Data? {
        guard frame.command == 0x73 else { return nil }
        return shotSequenceACK(index: frame.shotIndex, sequence: frame.sequence)
    }

    private static func make(command: UInt8, payload: [UInt8]) -> Data {
        precondition(payload.count == 16)
        var bytes: [UInt8] = [0x53, command] + payload + [0x45]
        bytes.append(0 &- bytes.reduce(UInt8(0), { $0 &+ $1 }))
        return Data(bytes)
    }
}

/// Reassembles only measurement command 0x73, sequences 1...5. Incoming settings,
/// battery and device-info records cannot become a ShotRecord. No transport writes
/// occur here. The transport must separately enforce its outbound allowlist.
final class SC4ShotAssembler {
    private struct Key: Hashable { let device: String; let index: UInt16 }
    private struct PartialShot {
        var updatedAt: Date
        var frames: [UInt8: SC4Frame]
    }
    private var partials: [Key: PartialShot] = [:]
    private var completed: Set<String> = []
    private var completionOrder: [String] = []
    private let timeToLive: TimeInterval
    private let now: () -> Date
    private let maxPending = 128
    private let maxCompleted = 2048
    private(set) var lastRejectionReason: String?
    /// Available even for a retransmitted complete shot. Transport may acknowledge
    /// its terminal sequence only after this identity is durable in ShotStore.
    private(set) var lastCompletedIdentity: String?
    var pendingCount: Int { partials.count }

    init(timeToLive: TimeInterval = 20, now: @escaping () -> Date = Date.init) {
        self.timeToLive = max(1, timeToLive)
        self.now = now
    }

    /// Discard incomplete fragments on disconnect; completed IDs still suppress
    /// retransmissions in this process. Persistent deduplication belongs to ShotStore.
    func reset() {
        partials.removeAll(keepingCapacity: true)
        lastRejectionReason = nil
        lastCompletedIdentity = nil
    }

    func ingest(frame: SC4Frame, deviceID: String, deviceName: String) -> ShotRecord? {
        lastRejectionReason = nil
        lastCompletedIdentity = nil
        guard frame.command == 0x73, (1...5).contains(frame.sequence) else { return nil }
        let receivedAt = now()
        partials = partials.filter { receivedAt.timeIntervalSince($0.value.updatedAt) <= timeToLive }
        let key = Key(device: deviceID.lowercased(), index: frame.shotIndex)
        var pending = partials[key] ?? PartialShot(updatedAt: receivedAt, frames: [:])

        // A different metadata frame for the same wrapped index starts a new shot.
        if frame.sequence == 1, let previous = pending.frames[1], previous != frame {
            pending.frames.removeAll(keepingCapacity: true)
        }
        pending.updatedAt = receivedAt
        pending.frames[frame.sequence] = frame
        partials[key] = pending
        if partials.count > maxPending,
           let oldest = partials.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            partials.removeValue(forKey: oldest)
        }

        guard (1...5).allSatisfy({ pending.frames[UInt8($0)] != nil }) else { return nil }
        partials.removeValue(forKey: key)
        guard let record = assemble(pending.frames, deviceID: deviceID,
                                    deviceName: deviceName, receivedAt: receivedAt) else { return nil }
        let identity = record.deduplicationKey
        lastCompletedIdentity = identity
        guard completed.insert(identity).inserted else { return nil }
        completionOrder.append(identity)
        if completionOrder.count > maxCompleted {
            completed.remove(completionOrder.removeFirst())
        }
        return record
    }

    private func assemble(_ frames: [UInt8: SC4Frame], deviceID: String,
                          deviceName: String, receivedAt: Date) -> ShotRecord? {
        guard let first = frames[1], let second = frames[2], let third = frames[3],
              let fourth = frames[4], let fifth = frames[5] else { return nil }
        let header = [UInt8](first.raw)
        let year = 2000 + Int(header[5]), month = Int(header[6]), day = Int(header[7])
        let hour = Int(header[8]), minute = Int(header[9]), secondOfMinute = Int(header[10])
        guard let timestamp = deviceDate(year: year, month: month, day: day,
                                         hour: hour, minute: minute, second: secondOfMinute) else {
            lastRejectionReason = "샷의 기기 시각이 올바르지 않습니다. 원본 패킷을 확인해 주세요."
            return nil
        }
        // The original payload is SI regardless of the device's display-unit flag.
        guard let ball = finiteFloat(second, at: 13, range: 0.0001...150) else {
            lastRejectionReason = "볼 속도가 유효하지 않아 측정값을 생성하지 않았습니다."
            return nil
        }
        let club = finiteFloat(third, at: 5, range: 0.0001...120)
        let launch = finiteFloat(third, at: 9, range: -90...90)
        let carry = finiteFloat(third, at: 13, range: 0...1000)
        let total = finiteFloat(fourth, at: 5, range: 0...1500)
        let apex = finiteFloat(fourth, at: 9, range: 0...500)
        let spin = finiteFloat(fourth, at: 13, range: 0...100000)
        let clubCodes = ["W1", "W3", "W4", "W5", "W6", "W7", "U3", "U4", "U5", "U6", "U7",
                         "I3", "I4", "I5", "I6", "I7", "I8", "I9", "PW", "GW", "SW", "LW"]
        let clubIndex = Int(header[12])
        let clubName = clubIndex < clubCodes.count ? clubCodes[clubIndex] : "클럽 \(clubIndex)"
        let wallClockID = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, secondOfMinute)
        let allBytes = [first, second, third, fourth, fifth].flatMap { [UInt8]($0.raw) }
        return ShotRecord(deviceID: deviceID, deviceName: deviceName, receivedAt: receivedAt,
                          deviceRecordID: "\(first.shotIndex):\(wallClockID)", timestamp: timestamp,
                          club: clubName, carryDistance: carry, totalDistance: total,
                          ballSpeed: ball, clubSpeed: club, launchAngle: launch,
                          launchDirection: finiteFloat(fifth, at: 5, range: -90...90),
                          apex: apex, smashFactor: ShotRecord.calculatedSmash(ball: ball, club: club),
                          smashFactorSource: club == nil ? nil : "calculated_ball_speed_divided_by_club_speed", spinRPM: spin,
                          distanceUnit: "m", speedUnit: "m/s",
                          rawHex: allBytes.map { String(format: "%02x", $0) }.joined(separator: " "),
                          source: "live")
    }

    private func finiteFloat(_ frame: SC4Frame, at offset: Int, range: ClosedRange<Double>) -> Double? {
        let bytes = [UInt8](frame.raw)
        guard offset >= 0, offset + 4 <= 18 else { return nil }
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && range.contains(value) ? value : nil
    }

    private func deviceDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        // SC4 supplies a wall-clock time without a timezone. Interpret it in this
        // Mac's timezone; the literal components are also kept in deviceRecordID.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        return date
    }
}
