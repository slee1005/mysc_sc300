import Foundation

enum CommandPolicyTestError: Error { case failed(String) }

@main
struct CommandPolicyTests {
    private static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw CommandPolicyTestError.failed(message) }
    }

    /// Test-only packet constructor deliberately bypasses production builders so
    /// forbidden command codes can be exercised without exposing a send surface.
    static func packet(_ command: UInt8, payload: [UInt8] = [UInt8](repeating: 0, count: 16)) -> Data {
        precondition(payload.count == 16)
        var bytes = [UInt8(0x53), command] + payload + [0x45]
        bytes.append(0 &- bytes.reduce(UInt8(0), &+))
        return Data(bytes)
    }

    static func mutate(_ data: Data, offset: Int, value: UInt8, fixChecksum: Bool = true) -> Data {
        var bytes = [UInt8](data)
        bytes[offset] = value
        if fixChecksum { bytes[19] = 0 &- bytes.prefix(19).reduce(UInt8(0), &+) }
        return Data(bytes)
    }

    static func hex(_ text: String) -> Data {
        let chars = Array(text)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }

    static func main() throws {
        try allCommandCodes()
        try payloadRestrictions()
        try framingAndChecksums()
        try capturedDeviceInfo()
        print("Command policy tests passed (\(checks) assertions; all 256 command codes covered)")
    }

    static func allCommandCodes() throws {
        let zero = [UInt8](repeating: 0, count: 16)
        var shot = zero
        shot[0] = 0x34; shot[1] = 0x12; shot[2] = 3
        for raw in UInt16(0)...UInt16(255) {
            let command = UInt8(raw)
            let zeroAllowed = command == 0x64
            try expect(SC4CommandPolicy.allows(packet(command, payload: zero)) == zeroAllowed,
                       "Zero-payload command \(command) violated allowlist")
            try expect(SC4CommandPolicy.allows(packet(command, payload: shot)) == (command == 0x73),
                       "Shot-shaped payload allowed command \(command)")
        }
        // Named regression cases make preservation intent visible on failure.
        for command: UInt8 in [0x44, 0x68, 0x6E, 0x6F, 0x72, 0x74, 0x76, 0x77, 0x78] {
            try expect(!SC4CommandPolicy.allows(packet(command)), "Deletion/control/firmware command allowed: \(command)")
        }
    }

    static func payloadRestrictions() throws {
        let query = SC4Wire.deviceInfoRequest()
        for position in 0..<16 {
            try expect(!SC4CommandPolicy.allows(mutate(query, offset: position + 2, value: 1)),
                       "Device-info request allowed nonzero payload at \(position)")
        }
        for index: UInt16 in [0, 1, 255, 256, 0x1234, 0xFFFF] {
            var payload = [UInt8](repeating: 0, count: 16)
            payload[0] = UInt8(truncatingIfNeeded: index)
            payload[1] = UInt8(truncatingIfNeeded: index >> 8)
            let request = packet(0x72, payload: payload)
            try expect(!SC4CommandPolicy.allows(request), "Consuming history request was allowed")
            for position in 2..<16 {
                try expect(!SC4CommandPolicy.allows(mutate(request, offset: position + 2, value: 1)),
                           "History query allowed nonzero non-index payload at \(position)")
            }
        }
        for sequence: UInt8 in 1...5 {
            guard let ack = SC4Wire.shotSequenceACK(index: 0xA571, sequence: sequence) else {
                throw CommandPolicyTestError.failed("Expected ACK builder rejected sequence \(sequence)")
            }
            try expect(SC4CommandPolicy.allows(ack), "Valid shot ACK rejected")
            for position in 3..<16 {
                try expect(!SC4CommandPolicy.allows(mutate(ack, offset: position + 2, value: 1)),
                           "ACK allowed measurement/control payload at \(position)")
            }
        }
        let base = SC4Wire.shotSequenceACK(index: 1, sequence: 1)!
        for raw in UInt16(0)...UInt16(255) {
            let sequence = UInt8(raw)
            let allowed = (1...5).contains(sequence)
            try expect(SC4CommandPolicy.allows(mutate(base, offset: 4, value: sequence)) == allowed,
                       "Sequence \(sequence) violated ACK allowlist")
        }
    }

    static func framingAndChecksums() throws {
        let packets = [SC4Wire.deviceInfoRequest(), packet(0x72),
                       SC4Wire.shotSequenceACK(index: 47, sequence: 5)!]
        for data in packets {
            var corrupt = [UInt8](data)
            corrupt[19] ^= 0x01
            try expect(!SC4CommandPolicy.allows(Data(corrupt)), "Invalid checksum was allowed")
            try expect(!SC4CommandPolicy.allows(mutate(data, offset: 0, value: 0x54)), "Invalid start marker was allowed")
            try expect(!SC4CommandPolicy.allows(mutate(data, offset: 18, value: 0x46)), "Invalid end marker was allowed")
            try expect(!SC4CommandPolicy.allows(Data(data.dropLast())), "Truncated write was allowed")
            try expect(!SC4CommandPolicy.allows(data + Data([0])), "Oversized write was allowed")
            try expect(!SC4CommandPolicy.allows(data + data), "Coalesced arbitrary write bypassed frame gate")
        }
        try expect(!SC4CommandPolicy.allows(Data()), "Empty write allowed")
    }

    static func capturedDeviceInfo() throws {
        // Actual parent live probe of SC4 2188; not a simulated shot record.
        let capture = hex("536401008603fa000b0000000500006e000c45f6")
        guard let frame = SC4Frame(raw: capture), let info = SC4DeviceInfo(frame: frame) else {
            throw CommandPolicyTestError.failed("Captured SC4 device-info frame did not parse")
        }
        try expect(info.model == 902, "Captured model should be 902")
        try expect(info.storedShotCount == 0, "Captured device had zero stored shots")
        try expect(info.batteryBars == 5, "Captured battery indicator changed")
        try expect(!SC4CommandPolicy.allows(capture), "An incoming device-info response must not be allowed as an outgoing query")
        let count = mutate(mutate(capture, offset: 13, value: 0x34), offset: 14, value: 0x12)
        try expect(SC4Frame(raw: count).flatMap(SC4DeviceInfo.init)?.storedShotCount == 0x1234,
                   "Device shot count is not decoded UInt16 little-endian")
        let badFlag = mutate(capture, offset: 2, value: 0)
        try expect(SC4Frame(raw: badFlag).flatMap(SC4DeviceInfo.init) == nil, "Malformed info response marker accepted")
        try expect(SC4Frame(raw: packet(0x73)).flatMap(SC4DeviceInfo.init) == nil, "Shot packet treated as device info")
    }
}
