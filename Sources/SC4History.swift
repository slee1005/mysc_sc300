import Foundation

/// Static REA inspection of MySwingCaddie 3.7.0's ZDAShotHistoryAck and its
/// serializer established the field order below. A 67-byte envelope follows
/// from that layout; the class's cached size also suggests an 80-byte variant.
/// Already-received history can be parsed offline. Outgoing history queries are
/// disabled because a later capture showed the stored-shot queue being consumed.
enum SC4History {
    static func parse(_ data: Data, deviceID: String, deviceName: String) -> ShotRecord? {
        let bytes = [UInt8](data)
        guard validEnvelope(bytes), let timestamp = deviceDate(bytes),
              let ball = float(bytes, at: 25, range: 0.0001...150) else { return nil }

        let recordIndex = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        let clubCodes = ["W1", "W3", "W4", "W5", "W6", "W7", "U3", "U4", "U5", "U6", "U7",
                         "I3", "I4", "I5", "I6", "I7", "I8", "I9", "PW", "GW", "SW", "LW"]
        let clubIndex = Int(bytes[11])
        let club = clubIndex < clubCodes.count ? clubCodes[clubIndex] : "클럽 \(clubIndex)"
        let wallClock = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                               2000 + Int(bytes[4]), Int(bytes[5]), Int(bytes[6]),
                               Int(bytes[7]), Int(bytes[8]), Int(bytes[9]))
        return ShotRecord(deviceID: deviceID, deviceName: deviceName,
                          deviceRecordID: "\(recordIndex):\(wallClock)", timestamp: timestamp,
                          club: club,
                          carryDistance: float(bytes, at: 37, range: 0...1000),
                          totalDistance: float(bytes, at: 41, range: 0...1500),
                          ballSpeed: ball,
                          clubSpeed: float(bytes, at: 29, range: 0.0001...120),
                          launchAngle: float(bytes, at: 33, range: -90...90),
                          launchDirection: float(bytes, at: 53, range: -90...90),
                          apex: float(bytes, at: 45, range: 0...500),
                          smashFactor: ShotRecord.calculatedSmash(ball: ball, club: float(bytes, at: 29, range: 0.0001...120)),
                          smashFactorSource: "calculated_ball_speed_divided_by_club_speed",
                          spinRPM: float(bytes, at: 49, range: 0...100000),
                          distanceUnit: "m", speedUnit: "m/s",
                          rawHex: bytes.map { String(format: "%02x", $0) }.joined(separator: " "),
                          source: "history")
    }

    static func validEnvelope(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 67 || bytes.count == 80 else { return false }
        return bytes[0] == 0x53 && bytes[1] == 0x72 && bytes[bytes.count - 2] == 0x45
            && bytes.reduce(UInt8(0), { $0 &+ $1 }) == 0
    }

    /// Helps avoid consuming a short status plus unrelated following bytes as
    /// a long historical measurement merely because an 8-bit checksum collides.
    static func plausibleMeasurement(_ bytes: [UInt8]) -> Bool {
        validEnvelope(bytes) && deviceDate(bytes) != nil && float(bytes, at: 25, range: 0.0001...150) != nil
    }

    static func hasDatePrefix(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 10 else { return false }
        let start = bytes.startIndex
        let month = bytes[start + 5], day = bytes[start + 6]
        return (1...12).contains(month) && (1...31).contains(day)
            && bytes[start + 7] <= 23 && bytes[start + 8] <= 59 && bytes[start + 9] <= 59
    }

    private static func float(_ bytes: [UInt8], at offset: Int, range: ClosedRange<Double>) -> Double? {
        guard offset >= 0, offset + 4 <= bytes.count - 2 else { return nil }
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && range.contains(value) ? value : nil
    }

    private static func deviceDate(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 10, hasDatePrefix(bytes[...]) else { return nil }
        let year = 2000 + Int(bytes[4]), month = Int(bytes[5]), day = Int(bytes[6])
        let hour = Int(bytes[7]), minute = Int(bytes[8]), second = Int(bytes[9])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts) else { return nil }
        let readBack = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard readBack.year == year, readBack.month == month, readBack.day == day,
              readBack.hour == hour, readBack.minute == minute, readBack.second == second else { return nil }
        return date
    }
}

enum SC4Message: Equatable {
    case frame(SC4Frame)
    case history(Data)
}

/// Incrementally separates 20-byte ordinary frames from conservative 67/80-byte
/// history candidates. An ordinary 0x72 status is never converted into a shot.
/// The retained input buffer never exceeds 4 KiB, including for malformed input.
struct SC4StreamDecoder {
    private var buffer: [UInt8] = []
    private let maximumBufferSize = 4096
    private(set) var rejectedCandidateCount = 0
    private(set) var discardedByteCount = 0
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) -> [SC4Message] {
        var messages: [SC4Message] = []
        for byte in data {
            buffer.append(byte)
            if buffer.count >= maximumBufferSize { drain(into: &messages) }
        }
        drain(into: &messages)
        return messages
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    private mutating func drain(into messages: inout [SC4Message]) {
        var offset = 0
        while buffer.count - offset >= 20 {
            guard buffer[offset] == 0x53 else {
                discardOne(at: &offset, rejected: false)
                continue
            }
            let remaining = buffer.count - offset
            if buffer[offset + 1] == 0x72 {
                // Prefer a complete long record over a coincidental 20-byte
                // prefix. The longer padded variant is checked first.
                if remaining >= 80 {
                    let candidate = Array(buffer[offset..<(offset + 80)])
                    if SC4History.plausibleMeasurement(candidate) {
                        messages.append(.history(Data(candidate)))
                        offset += 80
                        continue
                    }
                }
                if remaining >= 67 {
                    let candidate = Array(buffer[offset..<(offset + 67)])
                    if SC4History.plausibleMeasurement(candidate) {
                        messages.append(.history(Data(candidate)))
                        offset += 67
                        continue
                    }
                }
                if let status = SC4Frame(raw: Data(buffer[offset..<(offset + 20)])) {
                    messages.append(.frame(status))
                    offset += 20
                    continue
                }
                if remaining < 80 && SC4History.hasDatePrefix(buffer[offset...]) {
                    break // More fragments may complete a 67/80-byte history candidate.
                }
                discardOne(at: &offset, rejected: true)
                continue
            }
            if let frame = SC4Frame(raw: Data(buffer[offset..<(offset + 20)])) {
                messages.append(.frame(frame))
                offset += 20
            } else {
                discardOne(at: &offset, rejected: true)
            }
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    private mutating func discardOne(at offset: inout Int, rejected: Bool) {
        if rejected { rejectedCandidateCount &+= 1 }
        discardedByteCount &+= 1
        offset += 1
    }
}
