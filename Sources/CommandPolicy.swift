import Foundation

/// One gate for every application-level GATT write. Only device-info queries and
/// live-shot fragment acknowledgements are permitted. History reads (0x72) can
/// consume the device's stored-shot queue and are therefore forbidden as well.
enum SC4CommandPolicy {
    static func allows(_ data: Data) -> Bool {
        guard let frame = SC4Frame(raw: data) else { return false }
        switch frame.command {
        case 0x64:
            return frame.payload.allSatisfy { $0 == 0 }
        case 0x73:
            return (1...5).contains(frame.sequence) && frame.payload.dropFirst(3).allSatisfy { $0 == 0 }
        default:
            return false
        }
    }
}

struct SC4DeviceInfo {
    let model: UInt16
    let storedShotCount: UInt16
    let batteryBars: UInt8

    init?(frame: SC4Frame) {
        guard frame.command == 0x64, frame.payload[0] == 1, frame.payload[1] == 0 else { return nil }
        let bytes = [UInt8](frame.raw)
        model = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        batteryBars = bytes[12]
        storedShotCount = UInt16(bytes[13]) | UInt16(bytes[14]) << 8
    }
}
