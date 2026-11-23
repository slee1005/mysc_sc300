import SwiftUI

struct FlightSimulationView: View {
    @EnvironmentObject private var model: CollectorModel
    @EnvironmentObject private var display: DisplayPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID
    @State private var isPlaying = true
    @State private var offset: Double = 0
    @State private var startedAt = Date()
    @State private var rate: Double = 0.5
    @State private var camera: FlightCamera = .perspective
    @State private var followLatest = false
    @State private var assumedAngle = 35.0
    private let ink = Color(red: 0.07, green: 0.24, blue: 0.24)

    init(shot: ShotRecord) { _selectedID = State(initialValue: shot.id) }

    private var orderedShots: [ShotRecord] { model.shots.sorted { $0.receivedAt > $1.receivedAt } }
    private var selectedShot: ShotRecord? { model.shots.first { $0.id == selectedID } ?? orderedShots.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.text("공 비행 시뮬레이션")).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text(display.text("저장된 샷의 궤적을 다시 재생합니다.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(display.text("언어"), selection: $display.language) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.labelsHidden().frame(width: 115)
                Picker(display.text("거리 단위"), selection: $display.distanceUnit) {
                    Text("m").tag(DistanceUnit.meters)
                    Text("yd").tag(DistanceUnit.yards)
                }.pickerStyle(.segmented).frame(width: 105)
                Button(display.text("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                Picker(display.text("샷 선택"), selection: $selectedID) {
                    ForEach(orderedShots) { shot in
                        Text(shotLabel(shot)).tag(shot.id)
                    }
                }.frame(maxWidth: 490)
                Spacer()
                Toggle(display.text("새 샷 자동 재생"), isOn: $followLatest).toggleStyle(.switch).controlSize(.small)
            }
            ScrollView {
                if let shot = selectedShot, let replay = FlightReplay(shot: shot, assumedAngle: assumedAngle) {
                    simulation(replay, shot: shot)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "figure.golf").font(.system(size: 40))
                        Text(display.text("이 샷에는 궤적을 계산할 값이 부족합니다."))
                        Text(display.text("캐리·최고 높이 또는 유효한 볼 속도가 있는 샷을 선택하세요."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 420)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 960, idealWidth: 1060, minHeight: 730, idealHeight: 820)
        .background(Color(red: 0.96, green: 0.97, blue: 0.96))
        .foregroundStyle(ink)
        .tint(ink)
        .onChange(of: selectedID) { _ in restart() }
        .onChange(of: assumedAngle) { _ in restart() }
        .onChange(of: orderedShots.first?.id) { newest in
            if followLatest, let newest = newest { selectedID = newest }
        }
        .onChange(of: followLatest) { follow in
            if follow, let newest = orderedShots.first { selectedID = newest.id; restart() }
        }
    }

    private func simulation(_ replay: FlightReplay, shot: ShotRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(display.text("기록 기반 재현"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker(display.text("시점"), selection: $camera) {
                    ForEach(FlightCamera.allCases) { view in Text(display.text(view.labelKey)).tag(view) }
                }.pickerStyle(.segmented).frame(width: 270)
            }
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !isPlaying)) { timeline in
                let t = playbackTime(at: timeline.date, duration: replay.duration)
                let ball = replay.position(at: t)
                VStack(spacing: 12) {
                    FlightCanvas(replay: replay, time: t, camera: camera, unit: display.distanceUnit, language: display.language)
                        .frame(height: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 18) {
                                hud(display.text(ball.phase.rawValue), value: String(format: "%.2f s", t))
                                hud("진행 거리", value: display.distance(ball.groundDistance))
                                hud("현재 높이", value: display.distance(ball.height))
                            }
                            .padding(13)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(12)
                        }
                        .accessibilityLabel(display.text("{0}, 진행 거리 {1}, 높이 {2}", display.text(ball.phase.rawValue),
                                                        display.distance(ball.groundDistance), display.distance(ball.height)))
                    HStack(spacing: 12) {
                        Button {
                            if isPlaying {
                                offset = t
                                isPlaying = false
                            } else {
                                if offset >= replay.duration { offset = 0 }
                                startedAt = Date()
                                isPlaying = true
                            }
                        } label: {
                            Label(display.text(isPlaying ? "일시정지" : "재생"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 85)
                        }.buttonStyle(.borderedProminent)
                        Button { restart() } label: { Image(systemName: "arrow.counterclockwise") }
                            .help(display.text("처음부터 다시 재생"))
                            .accessibilityLabel(display.text("처음부터 다시 재생"))
                        Slider(value: Binding(get: { t }, set: { value in
                            offset = value
                            isPlaying = false
                        }), in: 0...replay.duration)
                        .accessibilityLabel(display.text("비행 재생 위치"))
                        Text(String(format: "%.1f / %.1f s", t, replay.duration))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(width: 100)
                        Picker(display.text("재생 속도"), selection: Binding(get: { rate }, set: { newRate in
                            offset = playbackTime(at: Date(), duration: replay.duration)
                            startedAt = Date()
                            rate = newRate
                        })) {
                            Text("0.25×").tag(0.25)
                            Text("0.5×").tag(0.5)
                            Text("1×").tag(1.0)
                            Text("2×").tag(2.0)
                        }.labelsHidden().frame(width: 78).accessibilityLabel(display.text("재생 속도"))
                    }
                }
                .onChange(of: t >= replay.duration) { ended in
                    if ended { offset = replay.duration; isPlaying = false }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                valueCard("캐리", value: display.distance(replay.carry), estimated: replay.carryIsEstimated)
                valueCard("최고 높이", value: display.distance(replay.apex), estimated: replay.apexIsEstimated)
                valueCard("발사각", value: String(format: "%.1f°", replay.launchAngle), estimated: replay.launchAngleIsEstimated)
                valueCard("출발 방향", value: shot.resolvedLaunchDirection.map { display.number($0) + "°" } ?? "—", estimated: false)
                valueCard("스매시 팩터", value: display.number(shot.resolvedSmashFactor, digits: 2), estimated: false)
                    .help(display.text("스매시 팩터 = 볼 속도 ÷ 클럽 속도"))
                valueCard("볼 스피드", value: shot.ballSpeed.map { display.number($0) + " " + shot.speedUnit } ?? "—", estimated: false)
                valueCard("비행 시간", value: String(format: "%.2f s", replay.flightDuration), estimated: true)
                valueCard("구른 거리", value: display.distance(replay.rollDistance), estimated: replay.rollDistanceIsEstimated)
            }
            if replay.usesAssumedAngle {
                HStack {
                    Text(display.text("가정 발사각 {0}°", String(Int(assumedAngle)))).font(.system(size: 12)).frame(width: 160, alignment: .leading)
                    Slider(value: $assumedAngle, in: 5...80, step: 1).accessibilityLabel(display.text("가정 발사각"))
                    Text(display.text("기록에 저장하지 않음")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(display.text(replay.explanation)).font(.system(size: 12, weight: .medium))
                Text(directionDescription(replay) + " · " + display.text("바람·공기저항·스핀의 휨 효과는 반영하지 않습니다. 구름 시간은 시각화용 추정입니다."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func playbackTime(at date: Date, duration: Double) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(startedAt)) * rate : 0
        return min(duration, max(0, offset + elapsed))
    }

    private func restart() { offset = 0; startedAt = Date(); isPlaying = true }

    private func shotLabel(_ shot: ShotRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        formatter.locale = display.language.locale
        let distance = shot.carryDistance == nil ? display.text("캐리 없음") : display.distance(shot.carryDistance, from: shot.distanceUnit)
        return "\(formatter.string(from: shot.timestamp ?? shot.receivedAt)) · \(shot.club ?? display.text("클럽 미상")) · \(distance)"
    }

    private func directionDescription(_ replay: FlightReplay) -> String {
        replay.headingIsEstimated ? display.text("방향 기록 없음: 직진으로 표시") : display.text("기록된 출발 방향 {0}°", display.number(replay.heading))
    }

    private func hud(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(display.text(title)).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private func valueCard(_ title: String, value: String, estimated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(display.text(title)).font(.system(size: 11)).foregroundStyle(.secondary)
                if estimated { Text(display.text("추정")).font(.system(size: 9, weight: .medium)).foregroundStyle(.orange) }
            }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum FlightCamera: String, CaseIterable, Identifiable {
    case perspective, side, top
    var labelKey: String {
        switch self { case .perspective: return "3D 시점"; case .side: return "측면"; case .top: return "위에서" }
    }
    var id: String { rawValue }
    var yaw: Double { self == .perspective ? -0.40 : 0 }
    var elevation: Double {
        switch self { case .perspective: return 0.60; case .side: return 0; case .top: return .pi / 2 }
    }
}

private struct FlightCanvas: View {
    let replay: FlightReplay
    let time: Double
    let camera: FlightCamera
    let unit: DistanceUnit
    let language: AppLanguage

    var body: some View {
        Canvas { context, size in
            let range = max(3, replay.total)
            let width = max(1.5, range * 0.15)
            let ending = replay.position(at: replay.duration)
            let x0 = -range * 0.07, x1 = range * 1.12
            let z0 = min(0, ending.lateral) - width, z1 = max(0, ending.lateral) + width
            let corners = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
            let ground = corners.map { world($0.0, $0.1, 0) }
            let path = replay.points()
            let projection = Projection(camera: camera, size: size, points: ground + path)
            let green = Color(red: 0.30, green: 0.56, blue: 0.43)
            let gold = Color(red: 0.96, green: 0.65, blue: 0.19)
            let full = CGRect(origin: .zero, size: size)
            context.fill(Path(full), with: .linearGradient(Gradient(colors: [Color(red: 0.87, green: 0.94, blue: 0.94), .white]),
                                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            if camera == .side {
                let baseline = projection.point(world(0, 0, 0)).y
                context.fill(Path(CGRect(x: 0, y: baseline, width: size.width, height: max(0, size.height - baseline))),
                             with: .color(green.opacity(0.8)))
            } else {
                context.fill(polyline(ground.map(projection.point), close: true), with: .color(green))
            }
            let displayRange = unit.fromMeters(range)
            let step = tickStep(displayRange)
            for mark in stride(from: 0.0, through: displayRange * 1.10, by: step) {
                let distance = unit.toMeters(mark)
                let a = projection.point(world(distance, z0, 0)), b = projection.point(world(distance, z1, 0))
                context.stroke(polyline([a, b]), with: .color(.white.opacity(0.22)), lineWidth: 1)
                let labelAt = camera == .side ? CGPoint(x: a.x, y: a.y + 15) : CGPoint(x: b.x + 6, y: b.y + 6)
                context.draw(Text(String(format: "%.0f %@", mark, unit.rawValue)).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(red: 0.17, green: 0.33, blue: 0.29)), at: labelAt, anchor: .topLeading)
            }
            // Target line is the instrument's zero direction; recorded heading
            // rotates only the shot. There is no invented sideways spin curve.
            context.stroke(polyline([projection.point(world(0, 0, 0)), projection.point(world(x1, 0, 0))]),
                           with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            let landing = replay.position(at: replay.flightDuration)
            let landingPoint = projection.point(landing)
            if camera != .side {
                let radius = max(0.20, range * 0.025)
                let ring = (0...48).map { index -> CGPoint in
                    let angle = Double(index) / 48 * 2 * Double.pi
                    return projection.point(world(landing.forward + cos(angle) * radius, landing.lateral + sin(angle) * radius, 0))
                }
                context.stroke(polyline(ring), with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }
            context.stroke(polyline(path.map(projection.point)), with: .color(gold.opacity(0.34)),
                           style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            context.stroke(polyline(replay.points(until: time).map(projection.point)), with: .color(gold),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            let origin = projection.point(world(0, 0, 0))
            context.fill(Path(ellipseIn: CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8)), with: .color(.white))
            context.draw(Text(AppLocalizer(language: language).text("출발")).font(.system(size: 11, weight: .medium)).foregroundColor(.black.opacity(0.6)),
                         at: CGPoint(x: origin.x, y: origin.y + 17))
            let flagTop = CGPoint(x: landingPoint.x, y: landingPoint.y - 28)
            context.stroke(polyline([landingPoint, flagTop]), with: .color(.white), lineWidth: 2)
            context.fill(polyline([flagTop, CGPoint(x: flagTop.x + 15, y: flagTop.y + 5), CGPoint(x: flagTop.x, y: flagTop.y + 10)], close: true),
                         with: .color(Color(red: 0.88, green: 0.34, blue: 0.26)))
            let current = replay.position(at: time)
            let ball = projection.point(current)
            let shadow = projection.point(world(current.forward, current.lateral, 0))
            context.fill(Path(ellipseIn: CGRect(x: shadow.x - 7, y: shadow.y - 3, width: 14, height: 6)),
                         with: .color(.black.opacity(0.20)))
            if camera != .top && current.height > 0.03 {
                context.stroke(polyline([ball, shadow]), with: .color(.white.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 9, y: ball.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.2)))
            context.fill(Path(ellipseIn: CGRect(x: ball.x - 5, y: ball.y - 5, width: 10, height: 10)), with: .color(.white))
            context.stroke(Path(ellipseIn: CGRect(x: ball.x - 5, y: ball.y - 5, width: 10, height: 10)), with: .color(.black.opacity(0.15)), lineWidth: 1)
        }
    }

    private func world(_ x: Double, _ z: Double, _ h: Double) -> FlightPosition {
        FlightPosition(forward: x, lateral: z, height: h, groundDistance: x, phase: .landed)
    }

    private func polyline(_ points: [CGPoint], close: Bool = false) -> Path {
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if close { path.closeSubpath() }
        }
        return path
    }

    private func tickStep(_ range: Double) -> Double {
        let raw = range / 5
        let base = pow(10, floor(log10(raw)))
        return [1.0, 2, 5, 10].map { $0 * base }.first(where: { $0 >= raw }) ?? base * 10
    }

    private struct Projection {
        let camera: FlightCamera
        let scale: Double
        let translateX: Double
        let translateY: Double

        init(camera: FlightCamera, size: CGSize, points: [FlightPosition]) {
            self.camera = camera
            let transformed = points.map { Self.project($0, camera: camera) }
            let minX = transformed.map(\.x).min() ?? 0, maxX = transformed.map(\.x).max() ?? 1
            let minY = transformed.map(\.y).min() ?? 0, maxY = transformed.map(\.y).max() ?? 1
            let spanX = max(0.1, maxX - minX), spanY = max(0.1, maxY - minY)
            let fitted = min((size.width - 100) / spanX, (size.height - 95) / spanY)
            self.scale = max(0.0001, fitted)
            self.translateX = (size.width - spanX * self.scale) / 2 - minX * self.scale
            self.translateY = (size.height - spanY * self.scale) / 2 - minY * self.scale + 18
        }

        func point(_ p: FlightPosition) -> CGPoint {
            let value = Self.project(p, camera: camera)
            return CGPoint(x: value.x * scale + translateX, y: value.y * scale + translateY)
        }

        private static func project(_ point: FlightPosition, camera: FlightCamera) -> CGPoint {
            let x = point.forward * cos(camera.yaw) + point.lateral * sin(camera.yaw)
            let depth = point.forward * sin(camera.yaw) - point.lateral * cos(camera.yaw)
            let y = depth * sin(camera.elevation) - point.height * cos(camera.elevation)
            return CGPoint(x: x, y: y)
        }
    }
}
