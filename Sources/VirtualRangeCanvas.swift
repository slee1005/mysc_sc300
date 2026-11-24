import AppKit
import SwiftUI

struct VirtualRangeCanvas: View {
    let replay: FlightReplay?
    let time: Double
    let unit: DistanceUnit
    var followsBall = false

    private static let rangePhoto = Bundle.main.url(forResource: "VirtualRange", withExtension: "jpg")
        .flatMap { NSImage(contentsOf: $0) }
        .map { Image(nsImage: $0) }

    var body: some View {
        Canvas { context, size in
            let horizon = size.height * 0.38
            let focalLength = size.height * 0.8
            let teeDrop = size.height * 0.39
            let verticalRoom = horizon + teeDrop - 16
            let horizontalRoom = max(1, size.width / 2 - 16)
            var cameraDistance = 1.7 * focalLength / teeDrop
            // Back the camera away for steep or offline shots to keep the trace in frame.
            for point in replay?.points(count: 32) ?? [] {
                let fitHeight = (point.height * focalLength - (horizon - 16) * point.forward) / verticalRoom
                let fitWidth = abs(point.lateral) * focalLength / horizontalRoom - point.forward
                cameraDistance = max(cameraDistance, fitHeight, fitWidth)
            }
            let cameraHeight = teeDrop * cameraDistance / focalLength
            let fieldLength = max(320, (replay?.total ?? 0) * 1.1)
            func project(_ forward: Double, _ lateral: Double, _ height: Double = 0) -> CGPoint {
                let scale = focalLength / (cameraDistance + max(0, forward))
                return CGPoint(x: size.width / 2 + lateral * scale,
                               y: horizon + (cameraHeight - height) * scale)
            }

            let current = replay?.position(at: time)
            let tee = project(0, 0)
            let ball = current.map { project($0.forward, $0.lateral, $0.height) } ?? tee

            var context = context
            var bounds = CGRect(origin: .zero, size: size)
            if let photo = Self.rangePhoto {
                let photoImage = context.resolve(photo)
                let photoSize = photoImage.size
                let scale = max(size.width * 1.30 / photoSize.width,
                                (horizon + 16) / (photoSize.height * Self.grassLine),
                                (size.height - horizon + 16) / (photoSize.height * (1 - Self.grassLine)))
                let width = photoSize.width * scale
                let height = photoSize.height * scale
                let photoBounds = CGRect(x: (size.width - width) / 2, y: horizon - height * Self.grassLine,
                                         width: width, height: height)
                if followsBall, let replay {
                    context.concatenate(cameraTransform(ball: ball, time: time, replay: replay,
                                                        size: size, limits: photoBounds))
                }
                context.draw(photoImage, in: photoBounds)
            } else {
                if followsBall, let replay {
                    let transform = cameraTransform(ball: ball, time: time, replay: replay, size: size)
                    context.concatenate(transform)
                    bounds = bounds.applying(transform.inverted())
                }
                context.fill(Path(bounds), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.08, green: 0.30, blue: 0.48), Color(red: 0.67, green: 0.84, blue: 0.88)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)
                ))
                let ground = CGRect(x: bounds.minX, y: horizon, width: bounds.width, height: max(0, bounds.maxY - horizon))
                context.fill(Path(ground), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.35, green: 0.50, blue: 0.24), Color(red: 0.14, green: 0.32, blue: 0.17)]),
                    startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)
                ))
            }

            // Stagger the signs so distant labels stay readable near the horizon.
            let maxMark = min(300, Int(unit.fromMeters(fieldLength)))
            for mark in stride(from: 50, through: maxMark, by: 50) {
                let distance = unit.toMeters(Double(mark))
                let x = size.width * (0.19 + 0.12 * Double(mark / 50 - 1))
                let base = CGPoint(x: x, y: project(distance, 0).y)
                let top = CGPoint(x: x, y: base.y - 18)
                context.stroke(outline([base, top]), with: .color(.white.opacity(0.8)), lineWidth: 1)
                let badge = CGRect(x: x - 23, y: top.y - 8, width: 46, height: 16)
                context.fill(Path(roundedRect: badge, cornerRadius: 3), with: .color(Color(red: 0.02, green: 0.33, blue: 0.34)))
                context.draw(Text("\(mark) \(unit.rawValue)").font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: top)
            }

            context.stroke(outline([tee, project(fieldLength, 0)]), with: .color(.white.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let replay {
                let trace = replay.points(until: time).map { project($0.forward, $0.lateral, $0.height) }
                context.stroke(outline(trace), with: .color(.orange.opacity(0.24)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                context.stroke(outline(trace), with: .color(Color(red: 1, green: 0.84, blue: 0.49)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if time >= replay.flightDuration {
                    let landing = replay.position(at: replay.flightDuration)
                    let point = project(landing.forward, landing.lateral)
                    context.stroke(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 3, width: 12, height: 6)),
                                   with: .color(.white), lineWidth: 1.5)
                }
            }
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 4, y: ball.y - 4, width: 8, height: 8)), with: .color(.white))
        }
    }

    // Fraction of the source photograph above the far edge of the grass.
    private static let grassLine = 0.43

    private func cameraTransform(ball: CGPoint, time: Double, replay: FlightReplay,
                                 size: CGSize, limits: CGRect? = nil) -> CGAffineTransform {
        let progress = min(1, max(0, time / (replay.flightDuration * 0.45)))
        let blend = progress * progress * (3 - 2 * progress)
        let zoom = 1 + 0.55 * blend
        let target = CGPoint(x: size.width * 0.5, y: size.height * 0.53)
        var x = target.x * blend + ball.x * (1 - blend - zoom)
        var y = target.y * blend + ball.y * (1 - blend - zoom)
        if let limits {
            x = min(-zoom * limits.minX, max(size.width - zoom * limits.maxX, x))
            y = min(-zoom * limits.minY, max(size.height - zoom * limits.maxY, y))
        }
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: x, ty: y)
    }

    private func outline(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        path.addLines(points)
        if closed { path.closeSubpath() }
        return path
    }
}

struct RangeShotMap: View {
    let replay: FlightReplay
    let time: Double

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width / 2, y: size.height - 12)
            let forwardLimit = max(1, replay.total)
            let finish = replay.position(at: replay.duration)
            let lateralLimit = max(forwardLimit * 0.2, abs(finish.lateral))
            func point(_ position: FlightPosition) -> CGPoint {
                CGPoint(x: origin.x + position.lateral / lateralLimit * (origin.x - 9),
                        y: origin.y - position.forward / forwardLimit * (size.height - 24))
            }

            var guides = Path()
            guides.move(to: origin)
            guides.addLine(to: CGPoint(x: origin.x, y: 12))
            for fraction in [0.25, 0.5, 0.75, 1.0] {
                let y = origin.y - fraction * (size.height - 24)
                guides.move(to: CGPoint(x: 12, y: y))
                guides.addLine(to: CGPoint(x: size.width - 12, y: y))
            }
            context.stroke(guides, with: .color(.white.opacity(0.32)), lineWidth: 1)

            var trace = Path()
            trace.addLines(replay.points(until: time).map(point))
            context.stroke(trace, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            let ball = point(replay.position(at: time))
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 2.5, y: ball.y - 2.5, width: 5, height: 5)),
                         with: .color(.white))
        }
        .background(.black.opacity(0.57), in: RoundedRectangle(cornerRadius: 12))
    }
}
