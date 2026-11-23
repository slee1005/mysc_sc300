import Foundation

@main
enum FlightReplayTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let shot = try ShotCoding.decoder().decode(ShotRecord.self, from: Data(contentsOf: fixtures.appendingPathComponent("sc4-synthetic-shot.json")))
        let before = shot
        let replay = FlightReplay(shot: shot)!
        near(replay.carry, 180)
        near(replay.apex, 28)
        near(replay.total, 195)
        near(replay.heading, 12)
        precondition(!replay.carryIsEstimated && !replay.apexIsEstimated && !replay.headingIsEstimated)
        precondition(!replay.usesAssumedAngle && !replay.rollDistanceIsEstimated)
        precondition(replay.launchAngleIsEstimated)
        let start = replay.position(at: 0)
        near(start.height, 0); near(start.groundDistance, 0)
        near(replay.position(at: replay.flightDuration / 2).height, replay.apex)
        let landing = replay.position(at: replay.flightDuration)
        near(landing.groundDistance, replay.carry); near(landing.height, 0)
        let end = replay.position(at: replay.duration)
        near(end.groundDistance, replay.total); near(end.height, 0)
        precondition(end.phase == .landed)
        near(hypot(end.forward, end.lateral), replay.total)
        var previous = 0.0
        for point in replay.points(count: 500) {
            precondition(point.height >= 0 && point.height <= replay.apex + 0.000001)
            precondition(point.groundDistance >= previous)
            previous = point.groundDistance
        }
        near(replay.position(at: -100).groundDistance, 0)
        near(replay.position(at: .infinity).groundDistance, 0)
        near(replay.position(at: replay.duration + 100).groundDistance, replay.total)
        precondition(shot == before && shot.launchAngle == nil)

        let yards = ShotRecord(deviceID: "unit-test", carryDistance: 200, totalDistance: 210,
                               ballSpeed: 100, apex: 20, distanceUnit: "yd", speedUnit: "mph")
        let metric = FlightReplay(shot: yards)!
        near(metric.carry, 182.88); near(metric.apex, 18.288); near(metric.recordedBallSpeed!, 44.704)
        precondition(metric.headingIsEstimated)

        let launchOnly = ShotRecord(deviceID: "launch-test", ballSpeed: 20, launchAngle: 45, distanceUnit: "m", speedUnit: "m/s")
        let derived = FlightReplay(shot: launchOnly)!
        near(derived.carry, 400 / FlightReplay.gravity)
        near(derived.apex, 100 / FlightReplay.gravity)
        precondition(derived.carryIsEstimated && derived.apexIsEstimated && !derived.usesAssumedAngle)
        let assumed = FlightReplay(shot: ShotRecord(deviceID: "angle-test", ballSpeed: 20, distanceUnit: "m", speedUnit: "m/s"), assumedAngle: 40)!
        near(assumed.launchAngle, 40)
        precondition(assumed.usesAssumedAngle)

        var impossibleTotal = shot
        impossibleTotal.totalDistance = 1
        let withoutBackwardsRoll = FlightReplay(shot: impossibleTotal)!
        near(withoutBackwardsRoll.rollDistance, 0)
        precondition(withoutBackwardsRoll.rollDistanceIsEstimated)
        precondition(impossibleTotal.totalDistance == 1)
        let driver = ShotRecord(deviceID: "measured-angle", carryDistance: 234.6, totalDistance: 257.3,
                                ballSpeed: 66.96, launchAngle: 12.85, apex: 26.52, distanceUnit: "m", speedUnit: "m/s")
        let driverReplay = FlightReplay(shot: driver)!
        near(driverReplay.launchAngle, 12.85)
        precondition(!driverReplay.launchAngleIsEstimated)
        near(driverReplay.position(at: driverReplay.flightDuration * driverReplay.apexFraction).height, 26.52)
        let initial = driverReplay.position(at: driverReplay.flightDuration * 0.000001)
        near(initial.height / initial.groundDistance, tan(12.85 * .pi / 180), tolerance: 0.00001)
        for point in driverReplay.points(count: 1000) { precondition(point.height <= 26.520001 && point.height >= 0) }
        precondition(FlightReplay(shot: ShotRecord(deviceID: "empty")) == nil)
        precondition(FlightReplay(shot: ShotRecord(deviceID: "invalid", carryDistance: .nan, apex: -.infinity, distanceUnit: "m")) == nil)
        precondition(FlightReplay(shot: ShotRecord(deviceID: "unknown-units", carryDistance: 10, apex: 2, distanceUnit: "unknown")) == nil)
        if CommandLine.arguments.count > 1 {
            let file = URL(fileURLWithPath: CommandLine.arguments[1])
            let original = try Data(contentsOf: file)
            var count = 0
            for line in original.split(separator: 10) where !line.isEmpty {
                let recorded = try ShotCoding.decoder().decode(ShotRecord.self, from: Data(line))
                guard let model = FlightReplay(shot: recorded) else { preconditionFailure("Unplayable recorded shot: \(recorded.id)") }
                if recorded.distanceUnit == "m", let distance = recorded.carryDistance { near(model.carry, distance) }
                near(model.position(at: model.flightDuration * model.apexFraction).height, model.apex)
                near(model.position(at: model.duration).groundDistance, model.total)
                if let angle = recorded.launchAngle { near(model.launchAngle, angle) }
                for point in model.points() { precondition(point.height.isFinite && point.height >= 0) }
                count += 1
            }
            let after = try Data(contentsOf: file)
            precondition(after.starts(with: original))
            print("PASS: all \(count) live saved records replayed; original file byte prefix preserved.")
        }
        print("PASS: synthetic-record trajectory anchors, measured heading, monotonic flight/roll, unit conversion, estimated fallbacks, invalid inputs and unchanged source records.")
    }

    static func near(_ actual: Double, _ expected: Double, tolerance: Double = 0.00001) {
        precondition(abs(actual - expected) <= tolerance, "\(actual) differs from \(expected)")
    }
}
