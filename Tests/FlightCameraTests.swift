import Foundation

@main
enum FlightCameraTests {
    static func close(_ a: Double, _ b: Double, tolerance: Double = 0.000001) {
        precondition(abs(a - b) < tolerance, "\(a) != \(b)")
    }

    static func main() {
        let start = FlightOrbit.initial
        precondition(start.dragging(horizontal: 0, vertical: 0) == start)
        let rotated = start.dragging(horizontal: 100, vertical: -50)
        close(rotated.yaw, 0.4)
        close(rotated.elevation, 0.9)
        // A completed drag followed by a second drag continues from the current view.
        let second = rotated.dragging(horizontal: -25, vertical: 10)
        close(second.yaw, 0.2)
        close(second.elevation, 0.84)
        let turn = start.dragging(horizontal: 2 * .pi / 0.008, vertical: 0)
        close(turn.yaw, start.yaw)
        let high = start.dragging(horizontal: -10000, vertical: -10000)
        let low = start.dragging(horizontal: 10000, vertical: 10000)
        close(high.elevation, FlightOrbit.maximumElevation)
        close(low.elevation, FlightOrbit.minimumElevation)
        precondition(start.dragging(horizontal: .nan, vertical: 0) == start)
        precondition(start.dragging(horizontal: 0, vertical: .infinity) == start)

        let sample = FlightPosition(forward: 200, lateral: -15, height: 30, groundDistance: 200, phase: .flying)
        let before = sample
        let side = FlightCamera.side.pose(orbit: rotated)
        let top = FlightCamera.top.pose(orbit: rotated)
        close(side.project(sample).x, 200)
        close(side.project(sample).y, -30)
        close(top.project(sample).x, 200)
        close(top.project(sample).y, 15)
        precondition(FlightCamera.side.pose(orbit: start) == side)
        precondition(FlightCamera.top.pose(orbit: start) == top)
        let originalView = FlightCamera.perspective.pose(orbit: start).project(sample)
        let changedView = FlightCamera.perspective.pose(orbit: rotated).project(sample)
        precondition(abs(originalView.x - changedView.x) > 0.001 || abs(originalView.y - changedView.y) > 0.001)
        for x in stride(from: -4000.0, through: 4000.0, by: 40) {
            for y in [-10000.0, -100, 0, 100, 10000] {
                let orbit = start.dragging(horizontal: x, vertical: y)
                precondition(abs(orbit.yaw) <= .pi)
                precondition(orbit.elevation >= FlightOrbit.minimumElevation && orbit.elevation <= FlightOrbit.maximumElevation)
                let pose = FlightCamera.perspective.pose(orbit: orbit)
                let position = pose.project(sample)
                let ground = FlightPosition(forward: sample.forward, lateral: sample.lateral, height: 0,
                                            groundDistance: sample.groundDistance, phase: .landed)
                precondition(position.x.isFinite && position.y.isFinite)
                // Positive altitude always appears above its ground point; no inverted views.
                precondition(position.y < pose.project(ground).y)
            }
        }
        precondition(sample == before)
        print("PASS: continuous orbit gestures, full-turn wrapping, elevation limits, fixed side/top views, finite projections and unchanged shot coordinates.")
    }
}
