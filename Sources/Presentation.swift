import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case korean = "ko"
    case english = "en"
    var id: String { rawValue }
    var name: String { self == .korean ? "한국어" : "English" }
    var locale: Locale { Locale(identifier: self == .korean ? "ko_KR" : "en_US") }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case meters = "m"
    case yards = "yd"
    var id: String { rawValue }
    var metersPerUnit: Double { self == .meters ? 1 : 0.9144 }
    func fromMeters(_ value: Double) -> Double { value / metersPerUnit }
    func toMeters(_ value: Double) -> Double { value * metersPerUnit }
    func convert(_ value: Double?, from source: String) -> Double? {
        guard let value = value, value.isFinite else { return nil }
        let meters: Double
        switch source.lowercased() {
        case "m", "meter", "meters": meters = value
        case "yd", "yard", "yards": meters = value * 0.9144
        default: return nil
        }
        return fromMeters(meters)
    }
}

struct AppMessage {
    let key: String
    let arguments: [String]
    init(_ key: String, _ arguments: String...) { self.key = key; self.arguments = arguments }
    init(key: String, arguments: [String]) { self.key = key; self.arguments = arguments }
}

struct AppLogEntry {
    let date: Date
    let message: AppMessage
}

struct AppLocalizer {
    let language: AppLanguage
    var resourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL

    func text(_ key: String, arguments: [String] = []) -> String {
        let bundle = Bundle(url: resourceRoot.appendingPathComponent("\(language.rawValue).lproj"))
        var result = bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        // Match only the template; inserted device/file text is never parsed again.
        let pattern = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let digits = Range(match.range(at: 1), in: result),
                  let index = Int(result[digits]), arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
    func text(_ message: AppMessage) -> String { text(message.key, arguments: message.arguments) }
}

extension ShotRecord {
    func exportCopy(distanceUnit unit: DistanceUnit?) -> ShotRecord {
        var copy = enriched
        guard let unit = unit else { return copy }
        copy.carryDistance = unit.convert(carryDistance, from: distanceUnit)
        copy.totalDistance = unit.convert(totalDistance, from: distanceUnit)
        copy.apex = unit.convert(apex, from: distanceUnit)
        copy.distanceUnit = unit.rawValue
        return copy
    }
}
