import SwiftUI

struct FlightSimulationView: View {
    @EnvironmentObject private var model: CollectorModel
    @EnvironmentObject private var display: DisplayPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var isPlaying = true
    @State private var offset: Double = 0
    @State private var startedAt = Date()
    @State private var rate: Double = 0.5
    @State private var camera: FlightCamera = .perspective
    @State private var orbit = FlightOrbit.initial
    @GestureState private var orbitDrag: CGSize = .zero
    @State private var followLatest: Bool
    @AppStorage("virtualRangeFollowBall") private var followBall = false
    @State private var rangeExpanded = false
    @State private var assumedAngle = 35.0
    private let ink = Color(red: 0.07, green: 0.24, blue: 0.24)

    init(shot: ShotRecord?, startsInLiveMode: Bool = false) {
        _selectedID = State(initialValue: shot?.id)
        _followLatest = State(initialValue: startsInLiveMode)
        _rate = State(initialValue: startsInLiveMode ? 1 : 0.5)
    }

    private var orderedShots: [ShotRecord] { model.shots.sorted { $0.receivedAt > $1.receivedAt } }
    private var selectedShot: ShotRecord? { model.shots.first { $0.id == selectedID } ?? orderedShots.first }
    private var visibleOrbit: FlightOrbit {
        orbit.dragging(horizontal: Double(orbitDrag.width), vertical: Double(orbitDrag.height))
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($orbitDrag) { value, translation, _ in
                if camera == .perspective { translation = value.translation }
            }
            .onEnded { value in
                guard camera == .perspective else { return }
                orbit = orbit.dragging(horizontal: Double(value.translation.width), vertical: Double(value.translation.height))
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.text("공 비행 시뮬레이션") + " · Virtual Range").font(.system(size: 24, weight: .semibold, design: .rounded))
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
            HStack {
                Spacer()
                Toggle(display.text("새 샷 자동 재생"), isOn: $followLatest).toggleStyle(.switch).controlSize(.small)
            }
            HStack(alignment: .top, spacing: 16) {
                if !rangeExpanded { rangeHistory }
                ScrollView {
                    if let shot = selectedShot, let replay = FlightReplay(shot: shot, assumedAngle: assumedAngle) {
                        simulation(replay, shot: shot)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            if !rangeExpanded {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(display.text("공 비행 시뮬레이션")).font(.headline)
                                    VStack(spacing: 10) {
                                        Image(systemName: "figure.golf").font(.title)
                                        Text(display.text(selectedShot == nil
                                            ? "샷을 치면 여기에 표시됩니다."
                                            : "이 샷에는 궤적을 계산할 값이 부족합니다."))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 320)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                }
                                .frame(width: 252)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                rangeHeader
                                VirtualRangeCanvas(replay: nil, time: 0, unit: display.distanceUnit)
                                    .frame(height: rangeHeight)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay(alignment: .bottom) {
                                        if rangeExpanded {
                                            Text(display.text(selectedShot == nil
                                                ? "샷을 치면 여기에 표시됩니다."
                                                : "이 샷에는 궤적을 계산할 값이 부족합니다."))
                                                .padding(10)
                                                .background(.regularMaterial, in: Capsule())
                                                .padding(10)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 1080, idealWidth: 1280, minHeight: 730, idealHeight: 820)
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

    private var rangeHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(display.text("샷 기록"), systemImage: "list.bullet")
                .font(.headline)
            List(selection: $selectedID) {
                ForEach(orderedShots) { shot in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shot.club ?? display.text("클럽 미상")).fontWeight(.medium)
                        Text(display.distance(shot.carryDistance, from: shot.distanceUnit))
                            .monospacedDigit()
                        Text((shot.timestamp ?? shot.receivedAt).formatted())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(shot.id)
                }
            }
            .accessibilityLabel(display.text("샷 기록"))
        }
        .frame(width: 172)
    }

    private func simulation(_ replay: FlightReplay, shot: ShotRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !isPlaying)) { timeline in
                let t = playbackTime(at: timeline.date, duration: replay.duration)
                let ball = replay.position(at: t)
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        if !rangeExpanded {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(display.text("공 비행 시뮬레이션")).font(.headline)
                                    .frame(height: 24)
                                FlightCanvas(replay: replay, time: t, camera: camera, pose: camera.pose(orbit: visibleOrbit),
                                             unit: display.distanceUnit, language: display.language)
                                    .frame(height: 320)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .contentShape(Rectangle())
                                    .gesture(orbitGesture, including: camera == .perspective ? .all : .none)
                                    .help(display.text("바닥을 드래그하여 좌우 회전과 높이 각도를 조절하세요."))
                                    .overlay(alignment: .topLeading) { shotHUD(replay, ball: ball, time: t) }
                                    .accessibilityLabel(display.text("{0}, 진행 거리 {1}, 높이 {2}", display.text(ball.phase.rawValue),
                                                                    display.distance(ball.groundDistance), display.distance(ball.height)))
                                HStack {
                                    Picker(display.text("시점"), selection: $camera) {
                                        ForEach(FlightCamera.allCases) { view in Text(display.text(view.labelKey)).tag(view) }
                                    }.labelsHidden().pickerStyle(.segmented)
                                    if camera == .perspective {
                                        Button { orbit = .initial } label: { Image(systemName: "viewfinder") }
                                            .help(display.text("시점 초기화"))
                                            .accessibilityLabel(display.text("시점 초기화"))
                                    }
                                }
                            }
                            .frame(width: 252)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            rangeHeader
                            VirtualRangeCanvas(replay: replay, time: t, unit: display.distanceUnit, followsBall: followBall)
                                .frame(height: rangeHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .accessibilityLabel("Virtual Range")
                                .overlay(alignment: .topLeading) { shotHUD(replay, ball: ball, time: t) }
                                .overlay(alignment: .bottom) { shotDetails(replay, shot: shot) }
                                .overlay(alignment: .topTrailing) {
                                    RangeShotMap(replay: replay, time: t)
                                        .frame(width: 70, height: 86)
                                        .padding(10)
                                        .accessibilityHidden(true)
                                        .allowsHitTesting(false)
                                }
                        }
                    }
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

    private var rangeHeight: CGFloat { rangeExpanded ? 530 : 480 }

    private func shotDetails(_ replay: FlightReplay, shot: ShotRecord) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 5), spacing: 4) {
            valueCard("캐리", value: display.distance(replay.carry), estimated: replay.carryIsEstimated)
            valueCard("최고 높이", value: display.distance(replay.apex), estimated: replay.apexIsEstimated)
            valueCard("발사각", value: String(format: "%.1f°", replay.launchAngle), estimated: replay.launchAngleIsEstimated)
            valueCard("출발 방향", value: shot.resolvedLaunchDirection.map { display.number($0) + "°" } ?? "—", estimated: false)
            valueCard("스매시 팩터", value: display.number(shot.resolvedSmashFactor, digits: 2), estimated: false)
                .help(display.text("스매시 팩터 = 볼 속도 ÷ 클럽 속도"))
            valueCard("볼 스피드", value: shot.ballSpeed.map { display.number($0) + " " + shot.speedUnit } ?? "—", estimated: false)
            valueCard("클럽 스피드", value: shot.clubSpeed.map { display.number($0) + " " + shot.speedUnit } ?? "—", estimated: false)
            valueCard("스핀", value: shot.spinRPM.map { display.number($0, digits: 0) + " rpm" } ?? "—", estimated: false)
            valueCard("비행 시간", value: String(format: "%.2f s", replay.flightDuration), estimated: true)
            valueCard("구른 거리", value: display.distance(replay.rollDistance), estimated: replay.rollDistanceIsEstimated)
        }
        .padding(9)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
        .allowsHitTesting(false)
    }

    private var rangeHeader: some View {
        HStack {
            Text("Virtual Range").font(.headline)
            Spacer()
            Toggle(display.text("카메라로 공 따라가기"), isOn: $followBall)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button {
                rangeExpanded.toggle()
            } label: {
                Image(systemName: rangeExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(display.text(rangeExpanded ? "나란히 보기" : "Virtual Range 확대"))
            .accessibilityLabel(display.text(rangeExpanded ? "나란히 보기" : "Virtual Range 확대"))
        }
        .frame(height: 24)
    }

    private func shotHUD(_ replay: FlightReplay, ball: FlightPosition, time: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                hud(ball.phase.rawValue, value: String(format: "%.2f s", time))
                hud("진행 거리", value: display.distance(ball.groundDistance))
                hud("현재 높이", value: display.distance(ball.height))
            }
            HStack(spacing: 10) {
                hud(replay.carryIsEstimated ? "추정 캐리" : "캐리", value: display.distance(replay.carry))
                hud(replay.rollDistanceIsEstimated ? "추정 총거리" : "총거리", value: display.distance(replay.total))
            }
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
        .allowsHitTesting(false)
    }

    private func playbackTime(at date: Date, duration: Double) -> Double {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(startedAt)) * rate : 0
        return min(duration, max(0, offset + elapsed))
    }

    private func restart() { offset = 0; startedAt = Date(); isPlaying = true }

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
        VStack(alignment: .leading, spacing: 1) {
            Text(estimated ? display.text(title) + " (" + display.text("추정") + ")" : display.text(title))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.83))
                .lineLimit(1).minimumScaleFactor(0.72)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }
}

private struct FlightCanvas: View {
    let replay: FlightReplay
    let time: Double
    let camera: FlightCamera
    let pose: FlightCameraPose
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
            let projection = Projection(pose: pose, size: size, points: ground + path)
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
            if time >= replay.flightDuration && camera != .side {
                let radius = max(0.20, range * 0.025)
                let ring = (0...48).map { index -> CGPoint in
                    let angle = Double(index) / 48 * 2 * Double.pi
                    return projection.point(world(landing.forward + cos(angle) * radius, landing.lateral + sin(angle) * radius, 0))
                }
                context.stroke(polyline(ring), with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }
            context.stroke(polyline(replay.points(until: time).map(projection.point)), with: .color(gold),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            let origin = projection.point(world(0, 0, 0))
            context.fill(Path(ellipseIn: CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8)), with: .color(.white))
            context.draw(Text(AppLocalizer(language: language).text("출발")).font(.system(size: 11, weight: .medium)).foregroundColor(.black.opacity(0.6)),
                         at: CGPoint(x: origin.x, y: origin.y + 17))
            if time >= replay.flightDuration {
                let flagTop = CGPoint(x: landingPoint.x, y: landingPoint.y - 28)
                context.stroke(polyline([landingPoint, flagTop]), with: .color(.white), lineWidth: 2)
                context.fill(polyline([flagTop, CGPoint(x: flagTop.x + 15, y: flagTop.y + 5), CGPoint(x: flagTop.x, y: flagTop.y + 10)], close: true),
                             with: .color(Color(red: 0.88, green: 0.34, blue: 0.26)))
            }
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
        let pose: FlightCameraPose
        let scale: Double
        let translateX: Double
        let translateY: Double

        init(pose: FlightCameraPose, size: CGSize, points: [FlightPosition]) {
            self.pose = pose
            let transformed = points.map(pose.project)
            let minX = transformed.map(\.x).min() ?? 0, maxX = transformed.map(\.x).max() ?? 1
            let minY = transformed.map(\.y).min() ?? 0, maxY = transformed.map(\.y).max() ?? 1
            let spanX = max(0.1, maxX - minX), spanY = max(0.1, maxY - minY)
            let fitted = min((size.width - 100) / spanX, (size.height - 95) / spanY)
            self.scale = max(0.0001, fitted)
            self.translateX = (size.width - spanX * self.scale) / 2 - minX * self.scale
            self.translateY = (size.height - spanY * self.scale) / 2 - minY * self.scale + 18
        }

        func point(_ p: FlightPosition) -> CGPoint {
            let value = pose.project(p)
            return CGPoint(x: value.x * scale + translateX, y: value.y * scale + translateY)
        }
    }
}
