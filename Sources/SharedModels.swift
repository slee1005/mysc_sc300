import Foundation

struct ShotRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var deviceID: String
    var deviceName: String
    var receivedAt: Date
    var deviceRecordID: String?
    var timestamp: Date?
    var club: String?
    var carryDistance: Double?
    var totalDistance: Double?
    var ballSpeed: Double?
    var clubSpeed: Double?
    var launchAngle: Double?
    var launchDirection: Double?
    var apex: Double?
    var smashFactor: Double?
    var smashFactorSource: String?
    var spinRPM: Double?
    var distanceUnit: String
    var speedUnit: String
    var rawHex: String
    var source: String

    init(id: UUID = UUID(), deviceID: String, deviceName: String = "SC4 2188",
         receivedAt: Date = Date(), deviceRecordID: String? = nil, timestamp: Date? = nil,
         club: String? = nil, carryDistance: Double? = nil, totalDistance: Double? = nil,
         ballSpeed: Double? = nil, clubSpeed: Double? = nil, launchAngle: Double? = nil,
         launchDirection: Double? = nil, apex: Double? = nil, smashFactor: Double? = nil,
         smashFactorSource: String? = nil, spinRPM: Double? = nil,
         distanceUnit: String = "yd", speedUnit: String = "mph", rawHex: String = "",
         source: String = "live") {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.receivedAt = receivedAt
        self.deviceRecordID = deviceRecordID
        self.timestamp = timestamp
        self.club = club
        self.carryDistance = carryDistance
        self.totalDistance = totalDistance
        self.ballSpeed = ballSpeed
        self.clubSpeed = clubSpeed
        self.launchAngle = launchAngle
        self.launchDirection = launchDirection
        self.apex = apex
        self.smashFactor = smashFactor
        self.smashFactorSource = smashFactorSource
        self.spinRPM = spinRPM
        self.distanceUnit = distanceUnit
        self.speedUnit = speedUnit
        self.rawHex = rawHex
        self.source = source
    }

    static func calculatedSmash(ball: Double?, club: Double?) -> Double? {
        guard let ball = ball, let club = club, ball.isFinite, club.isFinite,
              ball > 0, club > 0, (ball / club).isFinite else { return nil }
        return ball / club
    }

    var resolvedSmashFactor: Double? {
        if let value = smashFactor, value.isFinite, value > 0 { return value }
        return Self.calculatedSmash(ball: ballSpeed, club: clubSpeed)
    }

    var resolvedLaunchDirection: Double? {
        if let value = launchDirection, value.isFinite, abs(value) <= 90 { return value }
        let tokens = rawHex.split(whereSeparator: { $0.isWhitespace })
        let bytes = tokens.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == tokens.count else { return nil }
        func valid(_ frame: [UInt8], command: UInt8) -> Bool {
            frame.count >= 20 && frame[0] == 0x53 && frame[1] == command
                && frame[frame.count - 2] == 0x45 && frame.reduce(UInt8(0), &+) == 0
        }
        let offset: Int
        if bytes.count == 100 {
            let frames = stride(from: 0, to: 100, by: 20).map { Array(bytes[$0..<($0 + 20)]) }
            guard frames.allSatisfy({ valid($0, command: 0x73) }),
                  Set(frames.map { $0[4] }) == Set(UInt8(1)...UInt8(5)),
                  Set(frames.map { UInt16($0[2]) | UInt16($0[3]) << 8 }).count == 1,
                  let fifth = frames.firstIndex(where: { $0[4] == 5 }) else { return nil }
            offset = fifth * 20 + 5
        } else if (bytes.count == 67 || bytes.count == 80) && valid(bytes, command: 0x72) {
            offset = 53
        } else { return nil }
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && abs(value) <= 90 ? value : nil
    }

    /// Enrich a copy for display/export; the append-only source file is not migrated.
    var enriched: ShotRecord {
        var copy = self
        copy.launchDirection = resolvedLaunchDirection
        copy.smashFactor = resolvedSmashFactor
        if smashFactor == nil || !(smashFactor!.isFinite && smashFactor! > 0), copy.smashFactor != nil {
            copy.smashFactorSource = "calculated_ball_speed_divided_by_club_speed"
        }
        return copy
    }

    var deduplicationKey: String {
        let device = deviceID.lowercased()
        let time = timestamp.map { String(format: "%.3f", $0.timeIntervalSince1970) }
        if let recordID = deviceRecordID, !recordID.isEmpty {
            return "device:\(device)|record:\(recordID)|time:\(time ?? "unknown")"
        }
        if let time = time, !rawHex.isEmpty {
            return "device:\(device)|time:\(time)|packet:\(rawHex.lowercased())"
        }
        return "uuid:\(id.uuidString.lowercased())"
    }
}

enum ShotCoding {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(dateString(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO 8601 date")
        }
        return decoder
    }

    static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
