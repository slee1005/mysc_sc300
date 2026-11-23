import SwiftUI
import AppKit

@main
struct SC4ShotCollectorApp: App {
    @StateObject private var model = CollectorModel()
    @StateObject private var display = DisplayPreferences()

    var body: some Scene {
        WindowGroup {
            CollectorView()
                .environmentObject(model)
                .environmentObject(display)
                .environment(\.locale, display.language.locale)
                .preferredColorScheme(.light)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.disconnect()
                }
        }
        .defaultSize(width: 1440, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct CollectorView: View {
    @EnvironmentObject private var model: CollectorModel
    @EnvironmentObject private var display: DisplayPreferences
    @State private var showLogs = false
    @State private var selection: UUID?
    @State private var simulationShot: ShotRecord?
    private let teal = Color(red: 0.06, green: 0.30, blue: 0.29)
    private let muted = Color(red: 0.43, green: 0.48, blue: 0.48)
    private let canvas = Color(red: 0.96, green: 0.97, blue: 0.96)

    private var orderedShots: [ShotRecord] {
        model.shots.sorted { $0.receivedAt > $1.receivedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            connectionPanel
            metrics
            recordsPanel
            detailsPanel
            footer
        }
        .padding(26)
        .frame(minWidth: 1260, minHeight: 720)
        .background(canvas)
        .tint(teal)
        .sheet(item: $simulationShot) { shot in
            FlightSimulationView(shot: shot).environmentObject(model).environmentObject(display)
        }
        .alert(display.text("확인이 필요합니다"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(display.text("확인"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage.map { display.text($0) } ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(teal, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("SC4 Shot Collector")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(teal)
                Text(display.text("샷을 모으고, 기록은 그대로."))
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Picker(display.text("언어"), selection: $display.language) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.frame(width: 175)
                Picker(display.text("거리 단위"), selection: $display.distanceUnit) {
                    Text("m").tag(DistanceUnit.meters)
                    Text("yd").tag(DistanceUnit.yards)
                }.pickerStyle(.segmented).frame(width: 175)
            }
            Label(display.text("Mac 기록 보존"), systemImage: "checkmark.shield")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(teal.opacity(0.07), in: Capsule())
        }
    }

    private var connectionPanel: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SC4 2188")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 7) {
                    Circle().fill(model.isConnected ? teal : Color.gray.opacity(0.55)).frame(width: 7, height: 7)
                    Text(display.text(model.status)).font(.system(size: 12)).foregroundStyle(muted)
                    if model.isBusy { ProgressView().controlSize(.small).scaleEffect(0.8) }
                }
            }
            Spacer(minLength: 12)
            if model.requiresPIN {
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.text("기기에 표시된 PIN")).font(.system(size: 11)).foregroundStyle(muted)
                    HStack(spacing: 7) {
                        TextField(display.text("6자리"), text: $model.pin)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .monospacedDigit()
                            .onChange(of: model.pin) { value in
                                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                                if digits != value { model.pin = digits }
                            }
                            .onSubmit { if model.pin.count == 6 && model.isConnected { model.submitPIN() } }
                        Button(display.text("인증")) { model.submitPIN() }
                            .disabled(model.pin.count != 6 || !model.isConnected)
                    }
                }
                Divider().frame(height: 42).padding(.horizontal, 3)
            }
            Button {
                if model.isConnected || model.isBusy { model.disconnect() } else { model.connect() }
            } label: {
                Label(display.text(model.isConnected ? "연결 끊기" : (model.isBusy ? "중지" : "기기 연결")),
                      systemImage: model.isConnected ? "link" : "antenna.radiowaves.left.and.right")
                    .frame(minWidth: 106)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("k", modifiers: [.command])
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(teal.opacity(0.09), lineWidth: 1))
    }

    private var metrics: some View {
        HStack(spacing: 13) {
            metricCard(title: "저장된 샷", value: String(model.shots.count), unit: "개", icon: "tray.full")
            metricCard(title: "최근 캐리", value: number(display.distanceUnit.convert(orderedShots.first?.carryDistance,
                       from: orderedShots.first?.distanceUnit ?? "m")), unit: display.distanceUnit.rawValue, icon: "arrow.up.right")
            metricCard(title: "최근 볼 스피드", value: number(orderedShots.first?.ballSpeed),
                       unit: orderedShots.first?.speedUnit ?? "mph", icon: "speedometer")
            metricCard(title: "최근 발사각", value: number(orderedShots.first?.launchAngle), unit: "°", icon: "angle")
        }
    }

    private func metricCard(title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(display.text(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(teal.opacity(0.65))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(display.text(unit)).font(.system(size: 12)).foregroundStyle(muted)
            }
            .foregroundStyle(teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recordsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(display.text("샷 기록")).font(.system(size: 16, weight: .semibold))
                Text("\(model.shots.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(teal.opacity(0.07), in: Capsule())
                    .foregroundStyle(teal)
                Spacer()
                Button {
                    simulationShot = orderedShots.first(where: { $0.id == selection }) ?? orderedShots.first
                } label: {
                    Label(display.text("비행 시뮬레이션"), systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.shots.isEmpty)
                Menu {
                    Button(display.text("CSV로 내보내기")) { model.exportCSV(unit: display.distanceUnit) }
                    Button(display.text("JSON으로 내보내기")) { model.exportJSON(unit: display.distanceUnit) }
                } label: { Label(display.text("내보내기"), systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.shots.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            Divider()
            if model.shots.isEmpty {
                VStack(spacing: 11) {
                    Image(systemName: "figure.golf")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(teal.opacity(0.55))
                        .padding(.bottom, 3)
                    Text(display.text("아직 저장된 샷이 없습니다"))
                        .font(.system(size: 16, weight: .medium))
                    Text(display.text("SC4에 연결한 뒤 샷을 측정하면 여기에 기록됩니다."))
                        .font(.system(size: 13)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 190)
            } else {
                recordsTable
                    .frame(minHeight: 190)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(teal.opacity(0.09), lineWidth: 1))
    }

    private var recordsTable: some View {
        Table(orderedShots, selection: $selection) {
            TableColumn(display.text("수신 시각 · 클럽")) { record in
                HStack(spacing: 8) {
                    Text(record.receivedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(record.club ?? "—").foregroundStyle(teal).fontWeight(.medium)
                }
            }.width(min: 175, ideal: 195, max: 215)
            TableColumn(display.text("캐리")) { Text(display.distance($0.carryDistance, from: $0.distanceUnit)) }.width(min: 80, ideal: 92)
            TableColumn(display.text("총 거리")) { Text(display.distance($0.totalDistance, from: $0.distanceUnit)) }.width(min: 80, ideal: 92)
            TableColumn(display.text("볼 스피드")) { Text(metric($0.ballSpeed, unit: $0.speedUnit)) }.width(min: 90, ideal: 105)
            TableColumn(display.text("클럽 스피드")) { Text(metric($0.clubSpeed, unit: $0.speedUnit)) }.width(min: 90, ideal: 105)
            TableColumn(display.text("발사각")) { Text(metric($0.launchAngle, unit: "°")) }.width(min: 65, ideal: 75)
            TableColumn(display.text("출발 방향")) { Text(metric($0.resolvedLaunchDirection, unit: "°")) }.width(min: 105, ideal: 115)
            TableColumn(display.text("최고 높이")) { Text(display.distance($0.apex, from: $0.distanceUnit)) }.width(min: 75, ideal: 85)
            TableColumn(display.text("스매시 팩터")) {
                Text(number($0.resolvedSmashFactor, digits: 2)).help(display.text("스매시 팩터 = 볼 속도 ÷ 클럽 속도"))
            }.width(min: 95, ideal: 105)
            TableColumn(display.text("스핀")) { Text(metric($0.spinRPM, unit: "rpm", digits: 0)) }.width(min: 75, ideal: 95)
        }
        .font(.system(size: 12))
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var detailsPanel: some View {
        DisclosureGroup(isExpanded: $showLogs) {
            ScrollView {
                Text(model.logs.isEmpty ? display.text("연결 상태가 여기에 표시됩니다.") : model.logs.map {
                    $0.date.formatted(.dateTime.hour().minute().second().locale(display.language.locale)) + "  " + display.text($0.message)
                }.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 110)
        } label: {
            HStack {
                Text(display.text("연결 상태 자세히 보기")).font(.system(size: 12))
                Spacer()
                Text(display.text("수신 패킷 {0}", String(model.packetCount)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
            }
        }
        .foregroundStyle(muted)
    }

    private var footer: some View {
        HStack {
            Label(display.text("샷은 이 Mac에 자동으로 누적 저장됩니다."), systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(muted)
            Spacer()
            Button(display.text("저장 폴더 열기")) { model.revealDataFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(teal)
        }
    }

    private func number(_ value: Double?, digits: Int = 1) -> String {
        display.number(value, digits: digits)
    }

    private func metric(_ value: Double?, unit: String, digits: Int = 1) -> String {
        guard value != nil else { return "—" }
        return number(value, digits: digits) + (unit == "°" ? "°" : " \(unit)")
    }
}
