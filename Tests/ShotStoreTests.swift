import Foundation

@main
struct ShotStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc4-store-tests-\(UUID().uuidString)")
        let store = try ShotStore(directory: root)
        let moment = Date(timeIntervalSince1970: 1_790_000_000.125)
        let first = ShotRecord(deviceID: "test-device", receivedAt: moment,
                               deviceRecordID: "42", timestamp: moment,
                               carryDistance: 123.4, ballSpeed: 110.2, rawHex: "aabb")
        try expect(store.append(first), "first record appends")
        let original = try Data(contentsOf: store.fileURL)
        var sameShot = first
        sameShot.id = UUID()
        sameShot.receivedAt = moment.addingTimeInterval(5)
        try expect(!store.append(sameShot), "device record identity deduplicates repeat delivery")
        try expect(try Data(contentsOf: store.fileURL) == original, "duplicate does not touch journal bytes")

        let equalMetricsNewShot = ShotRecord(deviceID: "test-device", receivedAt: moment.addingTimeInterval(10),
                                             deviceRecordID: "43", timestamp: moment.addingTimeInterval(10),
                                             carryDistance: 123.4, ballSpeed: 110.2, rawHex: "aabb")
        try expect(store.append(equalMetricsNewShot), "equal metrics from a different shot remain distinct")
        let afterSecond = try Data(contentsOf: store.fileURL)
        try expect(afterSecond.starts(with: original), "append preserves every existing byte")
        let reopened = try ShotStore(directory: root)
        try expect(reopened.records.count == 2, "records survive reload")
        try expect(reopened.records.first?.timestamp == moment, "fractional shot timestamp survives storage")

        let tail = Data("{\"unfinished\":".utf8)
        let writer = try FileHandle(forWritingTo: store.fileURL)
        try writer.seekToEnd()
        try writer.write(contentsOf: tail)
        try writer.close()
        let tornBytes = try Data(contentsOf: store.fileURL)
        let recovered = try ShotStore(directory: root)
        try expect(recovered.records.count == 2 && recovered.warnings.count == 1, "torn last line preserves older records")
        let third = ShotRecord(deviceID: "test-device", deviceRecordID: "44", rawHex: "ccdd")
        try expect(recovered.append(third), "new record appends after torn line")
        try expect(try Data(contentsOf: store.fileURL).starts(with: tornBytes), "torn bytes are never rewritten or deleted")
        try expect(try ShotStore(directory: root).records.count == 3, "valid appended record remains reloadable after torn line")

        let secondInstance = try ShotStore(directory: root)
        let fourth = ShotRecord(deviceID: "test-device", deviceRecordID: "45", rawHex: "eeff")
        try expect(recovered.append(fourth), "first store adds fourth record")
        try expect(!secondInstance.append(fourth), "a second instance reloads and detects duplicates under its lock")
        try expect(secondInstance.records.count == 4, "second instance sees the latest records")

        let export = root.appendingPathComponent("export.json")
        try secondInstance.exportJSON(to: export)
        let exportBytes = try Data(contentsOf: export)
        var refused = false
        do { try secondInstance.exportJSON(to: export) } catch { refused = true }
        try expect(refused, "export refuses to overwrite an existing file")
        try expect(try Data(contentsOf: export) == exportBytes, "existing export content stays intact")
        let csv = root.appendingPathComponent("export.csv")
        try secondInstance.exportCSV(to: csv)
        try expect(try String(contentsOf: csv, encoding: .utf8).contains("carry_distance"), "CSV has metric columns")
        print("PASS: append preservation, device identity deduplication, distinct equal shots, reload, torn-tail recovery, multiple instances, non-overwriting exports.")
        print("Test artifacts: \(root.path)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw NSError(domain: "ShotStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
