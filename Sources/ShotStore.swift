import Foundation
import Darwin

/// The on-disk journal is only ever opened with O_APPEND. Existing bytes remain untouched.
final class ShotStore {
    let directory: URL
    let fileURL: URL
    private(set) var records: [ShotRecord] = []
    private(set) var warnings: [AppMessage] = []
    private var keys: Set<String> = []
    private var identifiers: Set<UUID> = []

    init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("shots.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try reload()
    }

    func reload() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            keys = []
            identifiers = []
            warnings = []
            return
        }
        try load(Data(contentsOf: fileURL))
    }

    @discardableResult
    func append(_ record: ShotRecord) throws -> Bool {
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { flock(descriptor, LOCK_UN) }

        // Reload under the file lock so a second app instance cannot add the same record twice.
        let existing = try Data(contentsOf: fileURL)
        try load(existing)
        guard !keys.contains(record.deduplicationKey), !identifiers.contains(record.id) else { return false }
        var payload = Data()
        // Preserve a torn final line verbatim and separate the next valid record with a newline.
        if let last = existing.last, last != 10 { payload.append(10) }
        payload.append(try ShotCoding.encoder().encode(record))
        payload.append(10)
        try writeAll(payload, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw posixError() }
        records.append(record)
        keys.insert(record.deduplicationKey)
        identifiers.insert(record.id)
        return true
    }

    func exportJSON(to destination: URL, distanceUnit: DistanceUnit? = nil) throws {
        try createNewFile(ShotCoding.encoder(pretty: true).encode(records.map { $0.exportCopy(distanceUnit: distanceUnit) }), at: destination)
    }

    func exportCSV(to destination: URL, distanceUnit: DistanceUnit? = nil) throws {
        let columns = ["id", "device_id", "device_name", "received_at", "device_record_id", "shot_time", "club",
                       "carry_distance", "total_distance", "distance_unit", "ball_speed", "club_speed", "speed_unit",
                       "launch_angle_deg", "launch_direction_deg", "apex", "smash_factor", "smash_factor_source", "spin_rpm", "source", "raw_hex"]
        func number(_ value: Double?) -> String { value.map { String($0) } ?? "" }
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [columns.map(quote).joined(separator: ",")]
        for original in records {
            let record = original.exportCopy(distanceUnit: distanceUnit)
            let fields = [record.id.uuidString, record.deviceID, record.deviceName, ShotCoding.dateString(record.receivedAt),
                          record.deviceRecordID ?? "", record.timestamp.map(ShotCoding.dateString) ?? "", record.club ?? "",
                          number(record.carryDistance), number(record.totalDistance), record.distanceUnit,
                          number(record.ballSpeed), number(record.clubSpeed), record.speedUnit, number(record.launchAngle),
                          number(record.launchDirection), number(record.apex), number(record.smashFactor), record.smashFactorSource ?? "",
                          number(record.spinRPM), record.source, record.rawHex]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        try createNewFile(Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8), at: destination)
    }

    private func load(_ data: Data) throws {
        var loaded: [ShotRecord] = []
        var seen: Set<String> = []
        var seenIDs: Set<UUID> = []
        var issues: [AppMessage] = []
        let decoder = ShotCoding.decoder()
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            do {
                let record = try decoder.decode(ShotRecord.self, from: Data(line))
                if seen.insert(record.deduplicationKey).inserted && seenIDs.insert(record.id).inserted {
                    loaded.append(record)
                }
            } catch {
                if issues.count < 50 { issues.append(AppMessage("{0}번째 줄을 읽을 수 없습니다. 원본 바이트는 보존됩니다.", String(index + 1))) }
            }
        }
        records = loaded
        keys = seen
        identifiers = seenIDs
        warnings = issues
    }

    private func createNewFile(_ data: Data, at destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var count = 0
            while count < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: count), data.count - count)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                count += written
            }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
