import Foundation

enum FlightCamera: String, CaseIterable, Identifiable {
    case perspective, side, top
    var id: String { rawValue }
    var labelKey: String {
        switch self { case .perspective: return "3D 시점"; case .side: return "측면"; case .top: return "위에서" }
    }

    func pose(orbit: FlightOrbit) -> FlightCameraPose {
        switch self {
        case .perspective: return FlightCameraPose(yaw: orbit.yaw, elevation: orbit.elevation)
        case .side: return FlightCameraPose(yaw: .pi / 2, elevation: 0)
        case .top: return FlightCameraPose(yaw: 0, elevation: .pi / 2)
        }
    }
}

struct FlightCameraPose: Equatable {
    let yaw: Double
    let elevation: Double

    func project(_ point: FlightPosition) -> CGPoint {
        // From behind the tee, positive lateral displacement is screen-right
        // and forward distance runs toward the top of the target line.
        let x = point.lateral * cos(yaw) + point.forward * sin(yaw)
        let depth = point.forward * cos(yaw) - point.lateral * sin(yaw)
        return CGPoint(x: x, y: -depth * sin(elevation) - point.height * cos(elevation))
    }
}

/// A drag is measured from its start, never accumulated once per animation frame.
/// Elevation stays above the ground and below the pole to avoid upside-down views.
struct FlightOrbit: Equatable {
    static let initial = FlightOrbit()
    static let minimumElevation = 8.0 * Double.pi / 180
    static let maximumElevation = 85.0 * Double.pi / 180
    private(set) var yaw: Double = 0
    private(set) var elevation: Double = 0.60

    func dragging(horizontal: Double, vertical: Double) -> FlightOrbit {
        guard horizontal.isFinite, vertical.isFinite else { return self }
        var next = self
        let fullTurn = 2 * Double.pi
        let rotated = (yaw + horizontal * 0.008).truncatingRemainder(dividingBy: fullTurn)
        next.yaw = rotated > .pi ? rotated - fullTurn : (rotated < -.pi ? rotated + fullTurn : rotated)
        next.elevation = min(Self.maximumElevation, max(Self.minimumElevation, elevation - vertical * 0.006))
        return next
    }
}
