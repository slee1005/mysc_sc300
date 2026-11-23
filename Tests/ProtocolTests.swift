import Foundation

enum ProtocolTestError: Error { case failed(String) }

@main
struct ProtocolTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw ProtocolTestError.failed(message) }
    }

    static func fixture(index: UInt16 = 1, seq: UInt8, ball: Float = 60,
                        launch: Float = 14, month: UInt8 = 11) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = 0x53; bytes[1] = 0x73
        bytes[2] = UInt8(truncatingIfNeeded: index)
        bytes[3] = UInt8(truncatingIfNeeded: index >> 8)
        bytes[4] = seq
        func putFloat(_ value: Float, at offset: Int) {
            let bits = value.bitPattern
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: bits >> (i * 8)) }
        }
        switch seq {
        case 1:
            bytes[5] = 26; bytes[6] = month; bytes[7] = 22
            bytes[8] = 14; bytes[9] = 30; bytes[10] = 12; bytes[12] = 15
            putFloat(34, at: 13)
        case 2: putFloat(1010, at: 5); putFloat(20, at: 9); putFloat(ball, at: 13)
        case 3: putFloat(40, at: 5); putFloat(launch, at: 9); putFloat(180, at: 13)
        case 4: putFloat(195, at: 5); putFloat(28, at: 9); putFloat(5000, at: 13)
        case 5: putFloat(-2, at: 5); putFloat(0, at: 9)
        default: break
        }
        bytes[18] = 0x45
        bytes[19] = 0 &- bytes.prefix(19).reduce(UInt8(0), { $0 &+ $1 })
        return Data(bytes)
    }

    static func parse(_ bytes: Data) throws -> SC4Frame {
        guard let frame = SC4Frame(raw: bytes) else { throw ProtocolTestError.failed("Invalid fixture") }
        return frame
    }

    static func completed(_ assembler: SC4ShotAssembler, index: UInt16 = 1,
                          ball: Float = 60, launch: Float = 14, month: UInt8 = 11) throws -> ShotRecord? {
        var result: ShotRecord?
        for sequence: UInt8 in 1...5 {
            result = assembler.ingest(frame: try parse(fixture(index: index, seq: sequence,
                                                               ball: ball, launch: launch, month: month)),
                                      deviceID: "SC4-device", deviceName: "SC4 2188") ?? result
        }
        return result
    }

    static func main() throws {
        try wireSurface()
        try fragmentedAndCoalesced()
        try completeOutOfOrderAndDuplicates()
        try sameMetricsDifferentRecords()
        try invalidMeasurements()
        try staleFragments()
        print("Protocol tests passed (6 groups)")
    }

    static func wireSurface() throws {
        let request = try parse(SC4Wire.deviceInfoRequest())
        try expect(request.command == 0x64, "Device-info command must be 0x64")
        try expect(request.payload == [UInt8](repeating: 0, count: 16), "Info request payload must be empty")
        let ackData = SC4Wire.shotSequenceACK(index: 0x1234, sequence: 3)
        try expect(ackData != nil, "Valid shot ACK missing")
        let ack = try parse(ackData!)
        try expect(ack.command == 0x73 && ack.shotIndex == 0x1234 && ack.sequence == 3, "ACK identity changed")
        try expect(ack.payload.dropFirst(3).allSatisfy { $0 == 0 }, "ACK must not copy measurement/control payload")
        try expect(SC4Wire.shotSequenceACK(index: 1, sequence: 0) == nil, "Unsupported sequence emitted")
        try expect(SC4Wire.shotSequenceACK(index: 1, sequence: 6) == nil, "Unverified sequence emitted")
        try expect(SC4Wire.shotSequenceACK(for: request) == nil, "Non-shot ACK emitted")
        try expect(SC4Frame(raw: request.raw.dropLast()) == nil, "Truncated frame accepted")
    }

    static func fragmentedAndCoalesced() throws {
        let first = fixture(index: 500, seq: 1)
        let second = fixture(index: 500, seq: 2)
        var corrupt = [UInt8](fixture(index: 900, seq: 2))
        corrupt[13] ^= 0x01
        var decoder = SC4FrameDecoder()
        let stream = Data([0, 1, 2]) + first + Data(corrupt) + second
        var result: [SC4Frame] = []
        for byte in stream { result.append(contentsOf: decoder.append(Data([byte]))) }
        try expect(result.count == 2, "Fragmented valid frames lost or corruption accepted")
        try expect(result[0].raw == first && result[1].raw == second, "Reassembly changed bytes")
        try expect(decoder.rejectedCandidateCount > 0, "Checksum corruption was not detected")
        let coalesced = decoder.append(first + second + first)
        try expect(coalesced.count == 3, "Coalesced frames not decoded")
        let afterNoise = decoder.append(Data(repeating: 0x53, count: 100_000) + second)
        try expect(afterNoise.count == 1 && afterNoise[0].raw == second, "Bounded noise recovery failed")
        try expect(decoder.bufferedByteCount < 20, "Decoder retains unbounded input")
    }

    static func completeOutOfOrderAndDuplicates() throws {
        let assembler = SC4ShotAssembler()
        var records: [ShotRecord] = []
        for sequence: UInt8 in [5, 2, 1, 4, 3] {
            if let record = assembler.ingest(frame: try parse(fixture(index: 4, seq: sequence)),
                                             deviceID: "SC4-device", deviceName: "SC4 2188") { records.append(record) }
            if sequence != 3 { try expect(records.isEmpty, "Incomplete shot emitted") }
        }
        try expect(records.count == 1, "Complete out-of-order shot missing")
        let record = records[0]
        try expect(record.ballSpeed == 60 && record.clubSpeed == 40 && record.carryDistance == 180,
                   "Measurements decoded at wrong offsets")
        try expect(record.totalDistance == 195 && record.apex == 28 && record.spinRPM == 5000,
                   "Sequence four fields incorrect")
        try expect(record.distanceUnit == "m" && record.speedUnit == "m/s" && record.source == "live", "Units/source fabricated")
        try expect(record.smashFactor == 1.5 && record.smashFactorSource == "calculated_ball_speed_divided_by_club_speed",
                   "Smash factor must be the ball/club speed ratio with an explicit calculated source")
        try expect(record.rawHex.split(separator: " ").count == 100, "Full five-part raw shot was not preserved")
        try expect(assembler.lastCompletedIdentity == record.deduplicationKey, "Completed identity not exposed for persistence/ACK gate")
        try expect(try completed(assembler, index: 4) == nil, "A retransmitted complete shot emitted twice")
        try expect(assembler.lastCompletedIdentity == record.deduplicationKey, "Duplicate completion lost durable-record lookup identity")
        let info = try parse(SC4Wire.deviceInfoRequest())
        try expect(assembler.ingest(frame: info, deviceID: "SC4-device", deviceName: "SC4 2188") == nil,
                   "Device information became a shot record")
        try expect(assembler.lastCompletedIdentity == nil, "Unrelated input leaked a prior completed identity")
    }

    static func sameMetricsDifferentRecords() throws {
        let assembler = SC4ShotAssembler()
        let first = try completed(assembler, index: 10)
        let second = try completed(assembler, index: 11)
        try expect(first != nil && second != nil, "Equal measurements caused loss of a distinct shot")
        try expect(first?.deduplicationKey != second?.deduplicationKey, "Different device indices share identity")
        try expect(first?.ballSpeed == second?.ballSpeed, "Fixture should have identical metrics")
    }

    static func invalidMeasurements() throws {
        let invalidBall = SC4ShotAssembler()
        try expect(try completed(invalidBall, ball: .nan) == nil, "NaN ball speed created a measured shot")
        try expect(invalidBall.lastRejectionReason != nil, "Rejected measurement has no diagnostic")
        let invalidAngle = try completed(SC4ShotAssembler(), launch: .infinity)
        try expect(invalidAngle != nil && invalidAngle?.launchAngle == nil, "Invalid angle was replaced with an invented measurement")
        try expect(invalidAngle?.ballSpeed == 60, "Valid raw shot data was unnecessarily dropped")
        try expect(try completed(SC4ShotAssembler(), month: 13) == nil, "Invalid calendar timestamp was normalized into a fake date")
        let assembler = SC4ShotAssembler()
        for sequence: UInt8 in [1, 2, 2, 3, 4] {
            _ = assembler.ingest(frame: try parse(fixture(index: 20, seq: sequence, ball: sequence == 2 ? 55 : 60)),
                                 deviceID: "SC4-device", deviceName: "SC4 2188")
        }
        let final = assembler.ingest(frame: try parse(fixture(index: 20, seq: 5)),
                                     deviceID: "SC4-device", deviceName: "SC4 2188")
        try expect(final?.ballSpeed == 55, "Duplicate sequence replacement changed received measurement")
    }

    static func staleFragments() throws {
        var clock = Date(timeIntervalSince1970: 10_000)
        let assembler = SC4ShotAssembler(timeToLive: 5, now: { clock })
        _ = assembler.ingest(frame: try parse(fixture(index: 25, seq: 1)), deviceID: "d", deviceName: "SC4 2188")
        clock.addTimeInterval(6)
        for sequence: UInt8 in 2...5 {
            let result = assembler.ingest(frame: try parse(fixture(index: 25, seq: sequence)), deviceID: "d", deviceName: "SC4 2188")
            try expect(result == nil, "Expired metadata mixed into a newer assembly")
        }
        assembler.reset()
        try expect(assembler.pendingCount == 0, "Disconnect retained partial shot fragments")
        try expect(assembler.lastCompletedIdentity == nil, "Disconnect retained the last-completion signal")
    }
}
