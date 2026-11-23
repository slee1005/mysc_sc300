import Foundation
import Combine

final class DisplayPreferences: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "displayLanguage") }
    }
    @Published var distanceUnit: DistanceUnit {
        didSet { defaults.set(distanceUnit.rawValue, forKey: "displayDistanceUnit") }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "displayLanguage") ?? "ko") ?? .korean
        distanceUnit = DistanceUnit(rawValue: defaults.string(forKey: "displayDistanceUnit") ?? "m") ?? .meters
    }
    func text(_ key: String, _ arguments: String...) -> String {
        AppLocalizer(language: language).text(key, arguments: arguments)
    }
    func text(_ message: AppMessage) -> String { AppLocalizer(language: language).text(message) }
    func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value = value, value.isFinite else { return "—" }
        return String(format: "%.*f", locale: language.locale, digits, value)
    }
    func distance(_ value: Double?, from source: String = "m", digits: Int = 1) -> String {
        guard let converted = distanceUnit.convert(value, from: source) else { return "—" }
        return "\(number(converted, digits: digits)) \(distanceUnit.rawValue)"
    }
}
