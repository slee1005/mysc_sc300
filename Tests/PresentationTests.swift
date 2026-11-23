import Foundation

@main
enum PresentationTests {
    static func near(_ actual: Double?, _ expected: Double) {
        precondition(actual != nil && abs(actual! - expected) < 0.00001, "\(String(describing: actual)) != \(expected)")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources")
        let english = AppLocalizer(language: .english, resourceRoot: resources)
        let korean = AppLocalizer(language: .korean, resourceRoot: resources)
        var keySets: [Set<String>] = []
        for language in AppLanguage.allCases {
            let file = resources.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
            let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as! [String: String]
            keySets.append(Set(dictionary.keys))
            let localizer = AppLocalizer(language: language, resourceRoot: resources)
            for (key, translation) in dictionary {
                precondition(localizer.text(key) == translation, "Language bundle did not load: \(key)")
                let pattern = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
                func placeholders(_ text: String) -> [String] {
                    pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                        .map { String(text[Range($0.range, in: text)!]) }.sorted()
                }
                precondition(placeholders(key) == placeholders(translation), "Translation changed a placeholder")
            }
        }
        precondition(keySets[0] == keySets[1])
        precondition(english.text("출발 방향") == "Launch Direction")
        precondition(english.text("스매시 팩터") == "Smash Factor")
        precondition(english.text("최고 높이") == "Apex")
        precondition(korean.text("출발 방향") == "출발 방향")
        precondition(english.text("수신 패킷 {0}", arguments: ["76"]) == "Received packets 76")
        precondition(english.text("{0}개 샷을 내보냈습니다: {1}", arguments: ["76", "{0}.csv"]) == "Exported 76 shots: {0}.csv")
        near(DistanceUnit.yards.convert(91.44, from: "m"), 100)
        near(DistanceUnit.meters.convert(100, from: "yd"), 91.44)
        near(DistanceUnit.yards.convert(100, from: "yards"), 100)
        precondition(DistanceUnit.meters.convert(3, from: "unknown") == nil)
        precondition(DistanceUnit.yards.convert(.nan, from: "m") == nil)
        let fixture = root.appendingPathComponent("Tests/Fixtures/sc4-synthetic-shot.json")
        let original = try Data(contentsOf: fixture)
        let legacy = try ShotCoding.decoder().decode(ShotRecord.self, from: original)
        precondition(legacy.launchDirection == nil && legacy.smashFactor == nil)
        near(legacy.resolvedLaunchDirection, 12)
        near(legacy.resolvedSmashFactor, legacy.ballSpeed! / legacy.clubSpeed!)
        let metric = legacy.enriched
        let yards = legacy.exportCopy(distanceUnit: .yards)
        near(yards.apex, legacy.apex! / 0.9144)
        near(yards.carryDistance, legacy.carryDistance! / 0.9144)
        near(yards.totalDistance, legacy.totalDistance! / 0.9144)
        precondition(yards.ballSpeed == legacy.ballSpeed && yards.launchDirection == metric.launchDirection)
        precondition(yards.smashFactor == metric.smashFactor && yards.distanceUnit == "yd")
        precondition(yards.rawHex == legacy.rawHex && yards.id == legacy.id)
        precondition(yards.deduplicationKey == legacy.deduplicationKey)
        let roundTrip = try ShotCoding.decoder().decode(ShotRecord.self, from: ShotCoding.encoder().encode(metric))
        precondition(roundTrip == metric && roundTrip.smashFactorSource != nil)
        let fixtureAfter = try Data(contentsOf: fixture)
        precondition(fixtureAfter == original)
        var malformed = legacy
        var tokens = malformed.rawHex.split(separator: " ").map(String.init)
        tokens[19] = tokens[19] == "00" ? "01" : "00"
        malformed.rawHex = tokens.joined(separator: " ")
        precondition(malformed.resolvedLaunchDirection == nil)
        precondition(ShotRecord.calculatedSmash(ball: 50, club: 0) == nil)
        precondition(ShotRecord.calculatedSmash(ball: .nan, club: 40) == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sc4-unit-export-\(UUID())")
        let store = try ShotStore(directory: directory)
        try store.append(legacy)
        let before = try Data(contentsOf: store.fileURL)
        let json = directory.appendingPathComponent("yards.json")
        let csv = directory.appendingPathComponent("yards.csv")
        try store.exportJSON(to: json, distanceUnit: .yards)
        try store.exportCSV(to: csv, distanceUnit: .yards)
        let exported = try ShotCoding.decoder().decode([ShotRecord].self, from: Data(contentsOf: json))
        precondition(exported == [yards])
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        precondition(csvText.contains("launch_direction_deg") && csvText.contains("smash_factor_source") && csvText.contains("\"yd\""))
        let storeAfter = try Data(contentsOf: store.fileURL)
        precondition(storeAfter == before)
        if CommandLine.arguments.count > 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            let savedBytes = try Data(contentsOf: file)
            let records = try savedBytes.split(separator: 10).map { try ShotCoding.decoder().decode(ShotRecord.self, from: Data($0)) }
            for record in records {
                precondition(record.resolvedLaunchDirection != nil && record.resolvedSmashFactor != nil && record.apex != nil)
                near(record.exportCopy(distanceUnit: .yards).apex, record.apex! / 0.9144)
            }
            let savedAfter = try Data(contentsOf: file)
            precondition(savedAfter == savedBytes)
            print("PASS: all \(records.count) saved shots expose direction, smash and apex without changing original bytes.")
        }
        print("PASS: bilingual resources, placeholders, legacy metrics, exact m/yd conversion, enriched unit exports and source preservation.")
    }
}
