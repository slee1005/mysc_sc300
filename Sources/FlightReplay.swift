import Foundation

struct FlightPosition: Equatable {
    let forward: Double
    let lateral: Double
    let height: Double
    let groundDistance: Double
    let phase: FlightPhase
}

enum FlightPhase: String {
    case flying = "비행 중"
    case rolling = "구르는 중"
    case landed = "재생 완료"
}

/// A reconstruction of the shot record, not an aerodynamic launch-monitor solver.
/// Carry/apex anchor the trajectory; a valid recorded launch angle also fixes its
/// initial tangent. Gravity supplies estimated timing. This is not a drag/lift solver.
/// This type is pure: replay and user assumptions cannot modify any ShotRecord.
struct FlightReplay {
    static let gravity = 9.80665
    let carry: Double
    let total: Double
    let apex: Double
    let launchAngle: Double
    let launchAngleIsEstimated: Bool
    let apexFraction: Double
    let heading: Double
    let flightDuration: Double
    let rollDuration: Double
    let recordedBallSpeed: Double?
    let recordedSpin: Double?
    let carryIsEstimated: Bool
    let apexIsEstimated: Bool
    let headingIsEstimated: Bool
    let usesAssumedAngle: Bool
    let rollDistanceIsEstimated: Bool
    let explanation: String
    var duration: Double { flightDuration + rollDuration }
    var rollDistance: Double { total - carry }

    init?(shot: ShotRecord, assumedAngle: Double = 35) {
        let distanceScale: Double
        switch shot.distanceUnit.lowercased() {
        case "m", "meter", "meters": distanceScale = 1
        case "yd", "yard", "yards": distanceScale = 0.9144
        default: return nil
        }
        let speedScale: Double?
        switch shot.speedUnit.lowercased() {
        case "m/s": speedScale = 1
        case "mph": speedScale = 0.44704
        case "km/h", "kph": speedScale = 1 / 3.6
        default: speedScale = nil
        }
        func positive(_ value: Double?, scale: Double = 1, max: Double) -> Double? {
            guard let value = value, value.isFinite, value > 0 else { return nil }
            let converted = value * scale
            return converted.isFinite && converted <= max ? converted : nil
        }
        let recordedCarry = positive(shot.carryDistance, scale: distanceScale, max: 1500)
        let recordedApex = positive(shot.apex, scale: distanceScale, max: 500)
        let speed = speedScale.flatMap { positive(shot.ballSpeed, scale: $0, max: 150) }
        let recordedAngle = shot.launchAngle.flatMap { value -> Double? in
            value.isFinite && value > 0 && value < 85 ? value : nil
        }
        let defaultAngle = assumedAngle.isFinite ? min(80, max(5, assumedAngle)) : 35
        let range: Double
        let peak: Double
        let explanation: String
        let carryEstimated: Bool
        let apexEstimated: Bool
        let assumed: Bool

        if let r = recordedCarry, let h = recordedApex {
            range = r
            peak = h
            carryEstimated = false
            apexEstimated = false
            assumed = false
            explanation = recordedAngle == nil
                ? "기록된 캐리·최고 높이에 맞춘 궤적입니다. 발사각과 시간은 추정값입니다."
                : "기록된 캐리·최고 높이·발사각에 맞춘 궤적입니다. 시간은 추정값입니다."
        } else if let r = recordedCarry {
            let angle: Double
            if let measured = recordedAngle {
                angle = measured
                assumed = false
                explanation = "기록된 캐리·발사각으로 최고 높이와 비행 시간을 추정합니다."
            } else if let v = speed, Self.gravity * r / (v * v) <= 1 {
                angle = asin(Self.gravity * r / (v * v)) * 90 / .pi
                assumed = false
                explanation = "캐리·볼 속도로 가능한 두 궤적 중 낮은 궤적을 사용합니다. 높이·시간은 추정값입니다."
            } else {
                angle = defaultAngle
                assumed = true
                explanation = "높이·유효 발사각이 없어 가정 각도로 궤적을 그립니다. 원본 기록에는 저장하지 않습니다."
            }
            range = r
            peak = r * tan(angle * .pi / 180) / 4
            carryEstimated = false
            apexEstimated = true
        } else if let v = speed {
            let angle = (recordedAngle ?? defaultAngle) * .pi / 180
            range = v * v * sin(2 * angle) / Self.gravity
            peak = v * v * pow(sin(angle), 2) / (2 * Self.gravity)
            carryEstimated = true
            apexEstimated = true
            assumed = recordedAngle == nil
            explanation = recordedAngle == nil
                ? "캐리 기록이 없어 볼 속도·가정 각도로 비행을 계산합니다. 계산 거리는 추정값입니다."
                : "볼 속도·발사각으로 캐리와 높이를 계산합니다. 계산 거리는 추정값입니다."
        } else {
            return nil
        }
        guard range.isFinite, peak.isFinite, range > 0.001, range <= 1500,
              peak > 0.00001, peak <= 500 else { return nil }

        self.carry = range
        self.apex = peak
        let recordedTotal = positive(shot.totalDistance, scale: distanceScale, max: 2000)
        self.total = max(range, recordedTotal ?? range)
        self.rollDistanceIsEstimated = recordedTotal == nil || (recordedTotal ?? 0) < range || carryEstimated
        self.launchAngle = recordedAngle ?? atan(4 * peak / range) * 180 / .pi
        self.launchAngleIsEstimated = recordedAngle == nil
        // Monotone cubic ascent: its initial tangent matches the measured angle,
        // its peak matches the recorded height, and it cannot overshoot that peak.
        let slope = tan(self.launchAngle * .pi / 180)
        self.apexFraction = max(0.000000000001, min(0.5, 2.5 * peak / (range * slope)))
        self.flightDuration = sqrt(8 * peak / Self.gravity)
        // Roll matches only the recorded remaining distance. Its deceleration and
        // duration are illustrative; ground firmness and landing speed were not measured.
        let remaining = self.total - range
        self.rollDuration = remaining > 0.001 ? max(0.25, sqrt(2 * remaining / 1.2)) : 0
        let direction = shot.resolvedLaunchDirection
        self.heading = direction ?? 0
        self.headingIsEstimated = direction == nil
        self.recordedBallSpeed = speed
        self.recordedSpin = positive(shot.spinRPM, max: 100000)
        self.carryIsEstimated = carryEstimated
        self.apexIsEstimated = apexEstimated
        self.usesAssumedAngle = assumed
        self.explanation = explanation
    }

    func position(at time: Double) -> FlightPosition {
        let t = time.isFinite ? min(duration, max(0, time)) : 0
        let distance: Double
        let height: Double
        let phase: FlightPhase
        if t < flightDuration {
            let u = t / flightDuration
            distance = carry * u
            if u <= apexFraction {
                let s = u / apexFraction
                let tangent = tan(launchAngle * .pi / 180) * carry * apexFraction / apex
                height = max(0, min(apex, apex * ((3 * s * s - 2 * s * s * s)
                    + tangent * (s * s * s - 2 * s * s + s))))
            } else {
                let s = (u - apexFraction) / (1 - apexFraction)
                height = max(0, apex * (1 - s * s))
            }
            phase = .flying
        } else if rollDuration > 0 && t < duration {
            let u = (t - flightDuration) / rollDuration
            distance = carry + rollDistance * (2 * u - u * u)
            height = 0
            phase = .rolling
        } else {
            distance = total
            height = 0
            phase = .landed
        }
        let radians = heading * .pi / 180
        return FlightPosition(forward: distance * cos(radians), lateral: distance * sin(radians),
                              height: height, groundDistance: distance, phase: phase)
    }

    func points(until time: Double? = nil, count: Int = 160) -> [FlightPosition] {
        let end = min(duration, max(0, time ?? duration))
        let intervals = min(2000, max(2, count))
        var times = (0...intervals).map { end * Double($0) / Double(intervals) }
        // Include measured anchors even when animation sampling does not land on them.
        times += [flightDuration * apexFraction, flightDuration].filter { $0 <= end }
        return Set(times).sorted().map { position(at: $0) }
    }

}
