import Foundation
import Darwin

/// Raw shot-transport chunks are durable before a fragment ACK is sent. This
/// journal is separate from the shot table: status/settings never become shots.
final class PacketJournal {
    private let descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("shot-transport.jsonl").path
        descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { close(descriptor) }

    func append(_ data: Data, deviceID: String) throws {
        let row: [String: Any] = ["receivedAt": ShotCoding.dateString(Date()), "deviceID": deviceID,
                                  "hex": data.map { String(format: "%02x", $0) }.joined(),
                                  "base64": data.base64EncodedString()]
        var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        // A leading newline also isolates a torn tail left by a prior crash.
        line.insert(10, at: 0)
        line.append(10)
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        try line.withUnsafeBytes { buffer in
            guard let pointer = buffer.baseAddress else { return }
            var offset = 0
            while offset < line.count {
                let n = Darwin.write(descriptor, pointer.advanced(by: offset), line.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
