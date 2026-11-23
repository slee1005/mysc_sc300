import Foundation

@main
struct HistoryTests {
    static func main() throws {
        let compact = history(length: 67)
        let padded = history(length: 80)
        let compactShot = SC4History.parse(compact, deviceID: "device", deviceName: "SC4 2188")
        let paddedShot = SC4History.parse(padded, deviceID: "device", deviceName: "SC4 2188")
        try expect(compactShot != nil && paddedShot != nil, "both conservative static-layout envelopes parse")
        try expect(compactShot?.source == "history", "history source is explicit")
        try expect(compactShot?.deviceRecordID == "42:2026-11-22T14:30:15", "record ID uses index plus literal wall clock")
        try expect(compactShot?.ballSpeed == 60 && compactShot?.clubSpeed == 40, "float fields follow native serializer offsets")
        try expect(compactShot?.carryDistance == 200 && compactShot?.spinRPM == 2500, "distance and spin offsets are correct")
        try expect(compactShot?.launchDirection == 1 && compactShot?.smashFactor == 1.5 && compactShot?.apex == 25,
                   "direction, calculated smash and apex follow the saved history layout")
        try expect(compactShot?.rawHex.split(separator: " ").count == 67, "entire compact raw frame remains present")
        try expect(paddedShot?.rawHex.split(separator: " ").count == 80, "padded raw bytes remain present")
        try expect(compactShot?.deduplicationKey == paddedShot?.deduplicationKey, "padding differences do not duplicate a device record")

        for raw in [compact, padded] {
            for split in 1..<raw.count {
                var decoder = SC4StreamDecoder()
                let early = decoder.append(raw.prefix(split))
                let late = decoder.append(raw.dropFirst(split))
                try expect(early.isEmpty, "a fragmented history frame is not emitted prematurely")
                try expect(late == [.history(raw)], "all fragment boundaries reassemble exactly")
                try expect(decoder.bufferedByteCount == 0, "complete frames leave no buffered tail")
            }
            var bytewise = SC4StreamDecoder()
            var messages: [SC4Message] = []
            for byte in raw { messages += bytewise.append(Data([byte])) }
            try expect(messages == [.history(raw)], "single-byte fragments reassemble")
        }

        let ordinary = frame(command: 0x64)
        let status = frame(command: 0x72)
        var interleaved = SC4StreamDecoder()
        try expect(interleaved.append(ordinary + compact + status + padded + ordinary)
                   == [.frame(SC4Frame(raw: ordinary)!), .history(compact), .frame(SC4Frame(raw: status)!),
                       .history(padded), .frame(SC4Frame(raw: ordinary)!)],
                   "interleaved 20-byte and history frames retain ordering")
        try expect(SC4History.parse(status, deviceID: "device", deviceName: "SC4") == nil,
                   "a valid 20-byte history status never fabricates a ShotRecord")

        var brokenChecksum = [UInt8](compact)
        brokenChecksum[25] ^= 0x01
        try expect(SC4History.parse(Data(brokenChecksum), deviceID: "device", deviceName: "SC4") == nil,
                   "corrupt checksum is rejected")
        var invalidDate = [UInt8](compact)
        invalidDate[5] = 2
        invalidDate[6] = 31
        repairChecksum(&invalidDate)
        try expect(SC4History.parse(Data(invalidDate), deviceID: "device", deviceName: "SC4") == nil,
                   "normalized invalid calendar dates are rejected")
        var invalidBall = [UInt8](compact)
        putFloat(.nan, at: 25, in: &invalidBall)
        repairChecksum(&invalidBall)
        try expect(SC4History.parse(Data(invalidBall), deviceID: "device", deviceName: "SC4") == nil,
                   "non-finite ball speed is rejected")
        putFloat(0, at: 25, in: &invalidBall)
        repairChecksum(&invalidBall)
        try expect(SC4History.parse(Data(invalidBall), deviceID: "device", deviceName: "SC4") == nil,
                   "zero ball speed does not fabricate a shot")

        var recovering = SC4StreamDecoder()
        let recovered = recovering.append(Data(brokenChecksum) + ordinary)
        try expect(recovered.last == .frame(SC4Frame(raw: ordinary)!), "a following ordinary frame survives corrupt history")
        var preservingTail = SC4StreamDecoder()
        try expect(preservingTail.append(compact + ordinary.prefix(13)) == [.history(compact)],
                   "history followed by a fragmented ordinary frame emits only history first")
        try expect(preservingTail.append(ordinary.dropFirst(13)) == [.frame(SC4Frame(raw: ordinary)!)],
                   "following ordinary frame's partial bytes remain intact")

        let liveAssembler = SC4ShotAssembler()
        var liveRecord: ShotRecord?
        for sequence in 1...5 {
            let bytes = liveFrame(sequence: UInt8(sequence))
            liveRecord = liveAssembler.ingest(frame: SC4Frame(raw: bytes)!, deviceID: "device", deviceName: "SC4 2188") ?? liveRecord
        }
        try expect(liveRecord?.deviceRecordID == compactShot?.deviceRecordID,
                   "live and history assemblers share the exact record ID convention")
        try expect(liveRecord?.deduplicationKey == compactShot?.deduplicationKey,
                   "live/history retransmission deduplicates in the persistent store")

        var bounded = SC4StreamDecoder()
        let garbage = Data(repeating: 0x53, count: 100_000)
        try expect(bounded.append(garbage).isEmpty && bounded.bufferedByteCount <= 4096,
                   "malformed input cannot grow the retained buffer beyond 4 KiB")
        print("PASS: history field layout, compact/padded fragmentation, status rejection, interleaving, bad date/checksum/float rejection, live/history identity and bounded stream recovery.")
        print("Fixtures are synthesized from static serializer layout; they are not captured device history packets.")
    }

    private static func history(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 0x53; bytes[1] = 0x72; bytes[2] = 42
        bytes[4] = 26; bytes[5] = 11; bytes[6] = 22
        bytes[7] = 14; bytes[8] = 30; bytes[9] = 15
        bytes[10] = 0; bytes[11] = 0; bytes[16] = 1
        putFloat(10.5, at: 12, in: &bytes)
        putFloat(1000, at: 17, in: &bytes)
        putFloat(20, at: 21, in: &bytes)
        putFloat(60, at: 25, in: &bytes)
        putFloat(40, at: 29, in: &bytes)
        putFloat(12.5, at: 33, in: &bytes)
        putFloat(200, at: 37, in: &bytes)
        putFloat(220, at: 41, in: &bytes)
        putFloat(25, at: 45, in: &bytes)
        putFloat(2500, at: 49, in: &bytes)
        putFloat(1, at: 53, in: &bytes)
        putFloat(2, at: 57, in: &bytes)
        bytes[61] = 3; bytes[63] = 4
        bytes[length - 2] = 0x45
        repairChecksum(&bytes)
        return Data(bytes)
    }

    private static func frame(command: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x53; bytes[1] = command; bytes[18] = 0x45
        repairChecksum(&bytes)
        return Data(bytes)
    }

    private static func liveFrame(sequence: UInt8) -> Data {
        var bytes = [UInt8](frame(command: 0x73))
        bytes[2] = 42; bytes[4] = sequence
        switch sequence {
        case 1:
            bytes[5] = 26; bytes[6] = 11; bytes[7] = 22
            bytes[8] = 14; bytes[9] = 30; bytes[10] = 15; bytes[12] = 0
        case 2: putFloat(60, at: 13, in: &bytes)
        case 3:
            putFloat(40, at: 5, in: &bytes); putFloat(12.5, at: 9, in: &bytes); putFloat(200, at: 13, in: &bytes)
        case 4:
            putFloat(220, at: 5, in: &bytes); putFloat(25, at: 9, in: &bytes); putFloat(2500, at: 13, in: &bytes)
        default: break
        }
        repairChecksum(&bytes)
        return Data(bytes)
    }

    private static func putFloat(_ value: Float, at offset: Int, in bytes: inout [UInt8]) {
        let bits = value.bitPattern
        for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: bits >> (byte * 8)) }
    }

    private static func repairChecksum(_ bytes: inout [UInt8]) {
        bytes[bytes.count - 1] = 0
        bytes[bytes.count - 1] = 0 &- bytes.reduce(UInt8(0), { $0 &+ $1 })
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "HistoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
