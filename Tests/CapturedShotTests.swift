import Foundation

@main
enum CapturedShotTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let hex = try String(contentsOf: fixtures.appendingPathComponent("sc4-synthetic-shot.hex"), encoding: .utf8)
        let bytes = hex.split(whereSeparator: { $0.isWhitespace }).compactMap { UInt8($0, radix: 16) }
        precondition(bytes.count == 100)
        var decoder = SC4FrameDecoder()
        let assembler = SC4ShotAssembler()
        var records: [ShotRecord] = []
        // Synthetic vector must survive arbitrary GATT chunk boundaries.
        for byte in bytes {
            for frame in decoder.append(Data([byte])) {
                if let shot = assembler.ingest(frame: frame, deviceID: "TEST-SC4", deviceName: "Synthetic SC4") {
                    records.append(shot)
                }
            }
        }
        precondition(records.count == 1)
        let shot = records[0]
        precondition(abs(shot.carryDistance! - 180) < 0.00001)
        precondition(abs(shot.totalDistance! - 195) < 0.00001)
        precondition(abs(shot.ballSpeed! - 60) < 0.00001)
        precondition(shot.spinRPM == 5000)
        precondition(shot.launchAngle == nil) // Raw136 is invalid, not changed to a guessed13.6.
        precondition(abs(shot.launchDirection! - 12) < 0.00001)
        precondition(abs(shot.smashFactor! - shot.ballSpeed! / shot.clubSpeed!) < 0.000001)
        precondition(shot.smashFactorSource == "calculated_ball_speed_divided_by_club_speed")
        precondition(shot.rawHex == hex.trimmingCharacters(in: .whitespacesAndNewlines))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sc4-real-shot-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var legacy = try ShotCoding.decoder().decode(ShotRecord.self, from: Data(contentsOf: fixtures.appendingPathComponent("sc4-synthetic-shot.json")))
        // Match the device's timezone-free wall clock in any developer timezone.
        legacy.timestamp = shot.timestamp
        let original = try ShotCoding.encoder().encode(legacy)
        let file = directory.appendingPathComponent("shots.jsonl")
        try original.write(to: file)
        let store = try ShotStore(directory: directory)
        precondition(store.records.count == 1)
        let added = try store.append(shot)
        let after = try Data(contentsOf: file)
        precondition(added == false)
        precondition(after == original)
        try store.reload()
        precondition(store.records.count == 1)
        print("PASS: synthetic SC4 packet decoded, raw bytes preserved, invalid angle not fabricated, existing record not overwritten or duplicated.")
    }
}
