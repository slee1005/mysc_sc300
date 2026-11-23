import Foundation
import Combine
import CoreBluetooth
import AppKit
import UniformTypeIdentifiers

/// CBCentralManager uses the main queue; UI and transport state stay on that queue.
final class CollectorModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = AppMessage("연결 준비")
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var shots: [ShotRecord] = []
    @Published var packetCount = 0
    @Published var logs: [AppLogEntry] = []
    @Published var errorMessage: AppMessage?
    @Published var pin = ""
    @Published var requiresPIN = false
    let dataDirectory: URL

    private let serviceID = CBUUID(string: "30300001-5365-6964-6461-63676E697773")
    private let writeID = CBUUID(string: "30300002-5365-6964-6461-63676E697773")
    private let notifyID = CBUUID(string: "30300003-5365-6964-6461-63676E697773")
    private let deviceID = "D3:71:43:B6:CC:0C"
    private let deviceName = "SC4 2188"
    private let knownIdentifier = UUID(uuidString: "11A90530-AA10-1BE3-9923-27C0A3925E91")!
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var store: ShotStore?
    private var journal: PacketJournal?
    private var decoder = SC4StreamDecoder()
    private var assembler = SC4ShotAssembler()
    private var wantsConnection = false
    private var triedCachedConnection = false
    private var retryTimer: Timer?
    private var connectionTimer: Timer?
    private var deviceInfo: SC4DeviceInfo?
    private var outgoing: [Data] = []
    private var writeInFlight = false
    private var ready = false
    private var terminalACKs: [UInt16: Data] = [:]
    private var terminalFrames: [UInt16: SC4Frame] = [:]
    private var durableTerminalReplies: [Data: (identity: String, savedAt: Date)] = [:]

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SC4 Shot Collector", isDirectory: true)
        }
        super.init()
        do {
            let store = try ShotStore(directory: dataDirectory)
            self.store = store
            journal = try PacketJournal(directory: dataDirectory)
            shots = store.records.map { $0.enriched }
            for warning in store.warnings { log(warning) }
            log("기존 {0}개 샷을 불러왔습니다. 새 기록은 파일 끝에 추가합니다.", String(shots.count))
        } catch {
            status = AppMessage("저장 폴더를 열 수 없습니다")
            errorMessage = AppMessage(error.localizedDescription)
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        if !arguments.contains("--no-auto-connect") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connect() }
        }
    }

    func connect() {
        guard store != nil, journal != nil else { errorMessage = AppMessage("저장 폴더를 먼저 확인해 주세요."); return }
        guard !isConnected, !isBusy else { return }
        wantsConnection = true
        triedCachedConnection = false
        isBusy = true
        beginConnection()
    }

    func disconnect() {
        wantsConnection = false
        retryTimer?.invalidate()
        connectionTimer?.invalidate()
        central.stopScan()
        if let peripheral = peripheral { central.cancelPeripheralConnection(peripheral) }
        resetTransport()
        isConnected = false
        isBusy = false
        status = AppMessage("연결 해제 · 저장된 기록 유지")
    }

    func submitPIN() {
        // This SC4 has allowed queries without application-level PIN exchange.
        // Do not repurpose the device-ID-setting command as a guessed PIN write.
        errorMessage = AppMessage("현재 SC4가 PIN 교환을 요청하지 않았습니다. 기기 ID를 변경하는 명령은 전송하지 않습니다.")
    }

    func exportCSV(unit: DistanceUnit) { export(asJSON: false, unit: unit) }
    func exportJSON(unit: DistanceUnit) { export(asJSON: true, unit: unit) }
    func revealDataFolder() { NSWorkspace.shared.open(dataDirectory) }

    private func export(asJSON: Bool, unit: DistanceUnit) {
        guard let store = store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = asJSON ? [.json] : [.commaSeparatedText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SC4-shots-\(formatter.string(from: Date())).\(asJSON ? "json" : "csv")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try store.reload()
            if asJSON { try store.exportJSON(to: destination, distanceUnit: unit) } else { try store.exportCSV(to: destination, distanceUnit: unit) }
            log("{0}개 샷을 내보냈습니다: {1}", String(store.records.count), destination.lastPathComponent)
        } catch {
            errorMessage = AppMessage("내보내기에 실패했습니다. 같은 이름의 파일이 있으면 새 이름을 사용해 주세요.\n{0}", error.localizedDescription)
        }
    }

    private func beginConnection() {
        guard wantsConnection else { return }
        switch central.state {
        case .poweredOn:
            isBusy = true
            if !triedCachedConnection {
                triedCachedConnection = true
                if let cached = central.retrievePeripherals(withIdentifiers: [knownIdentifier]).first {
                    attach(cached)
                    return
                }
            }
            status = AppMessage("SC4 2188 검색 중")
            central.scanForPeripherals(withServices: [serviceID], options: nil)
            log("SC4 2188의 광고를 기다립니다.")
        case .unauthorized:
            isBusy = false
            status = AppMessage("Bluetooth 접근 권한 필요")
            errorMessage = AppMessage("시스템 설정 → 개인정보 보호 및 보안 → Bluetooth에서 SC4 Shot Collector를 허용해 주세요.")
        case .poweredOff:
            status = AppMessage("Mac의 Bluetooth를 켜 주세요")
        case .unsupported:
            isBusy = false
            status = AppMessage("이 Mac에서 Bluetooth LE를 사용할 수 없습니다")
        default:
            status = AppMessage("Bluetooth 준비 중")
        }
    }

    private func attach(_ target: CBPeripheral) {
        guard wantsConnection else { return }
        central.stopScan()
        peripheral = target
        target.delegate = self
        status = AppMessage("SC4 2188 연결 중")
        log("기기 연결을 시작합니다.")
        central.connect(target, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected else { return }
            if let target = self.peripheral { self.central.cancelPeripheralConnection(target) }
            self.scheduleReconnect()
        }
    }

    private func resetTransport() {
        connectionTimer?.invalidate()
        ready = false
        writeCharacteristic = nil
        outgoing.removeAll()
        writeInFlight = false
        decoder.reset()
        // Persistent deduplication belongs to ShotStore. A new parser also lets
        // a complete retransmission retry a previously failed disk commit.
        assembler = SC4ShotAssembler()
        terminalACKs.removeAll()
        terminalFrames.removeAll()
        durableTerminalReplies.removeAll()
        deviceInfo = nil
    }

    private func scheduleReconnect() {
        resetTransport()
        isConnected = false
        isBusy = wantsConnection
        status = AppMessage(wantsConnection ? "연결이 끊겼습니다 · 다시 검색 중" : "연결 해제")
        guard wantsConnection else { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.beginConnection() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if wantsConnection { beginConnection() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover target: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? target.name ?? ""
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard normalized == "sc42188" else { return }
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let hex = manufacturer.map { String(format: "%02x", $0) }.joined()
            guard hex.contains("d37143b6cc0c") else { return }
        } else if target.identifier != knownIdentifier { return }
        attach(target)
    }

    func centralManager(_ central: CBCentralManager, didConnect target: CBPeripheral) {
        connectionTimer?.invalidate()
        isConnected = true
        isBusy = false
        status = AppMessage("연결됨 · 샷 수신 준비 중")
        target.discoverServices([serviceID])
        log("SC4 2188에 연결했습니다.")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect target: CBPeripheral, error: Error?) {
        log("연결 실패: {0}", error?.localizedDescription ?? "No response")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral target: CBPeripheral, error: Error?) {
        log("연결 해제: {0}", error?.localizedDescription ?? "Normal disconnect")
        scheduleReconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { fail(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            errorMessage = AppMessage("이 기기에서 SC4 샷 수신 서비스를 찾지 못했습니다.")
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([writeID, notifyID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { fail(error); return }
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == writeID })
        guard writeCharacteristic != nil,
              let notify = service.characteristics?.first(where: { $0.uuid == notifyID }),
              notify.properties.contains(.notify) else {
            errorMessage = AppMessage("샷 수신용 Bluetooth 채널을 찾지 못했습니다.")
            disconnect()
            return
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { fail(error); return }
        guard characteristic.uuid == notifyID, characteristic.isNotifying else { return }
        ready = true
        status = AppMessage("연결됨 · 새 샷 수신 대기")
        log("샷 알림을 구독했습니다. 삭제 명령은 차단됩니다.")
        send(SC4Wire.deviceInfoRequest())
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { fail(error); return }
        guard characteristic.uuid == notifyID, let data = characteristic.value, let journal = journal else { return }
        do { try journal.append(data, deviceID: deviceID) } catch { fail(error); disconnect(); return }
        for message in decoder.append(data) {
            switch message {
            case .frame(let frame): handle(frame)
            case .history(let raw):
                packetCount += 1
                if let record = SC4History.parse(raw, deviceID: deviceID, deviceName: deviceName) {
                    save(record)
                } else { log("이력 응답의 형식을 확인할 수 없어 원본만 보존했습니다.") }
            }
        }
    }

    private func handle(_ frame: SC4Frame) {
        packetCount += 1
        if let info = SC4DeviceInfo(frame: frame) {
            deviceInfo = info
            log("기기 저장 샷: {0}개", String(info.storedShotCount))
            status = AppMessage("연결됨 · 기기 기록 {0}개 · 새 샷 수신 대기", String(info.storedShotCount))
            return
        }
        guard frame.command == 0x73, (1...5).contains(frame.sequence) else { return }
        durableTerminalReplies = durableTerminalReplies.filter { Date().timeIntervalSince($0.value.savedAt) < 20 }
        if frame.sequence == 1 {
            durableTerminalReplies = durableTerminalReplies.filter {
                SC4Frame(raw: $0.key)?.shotIndex != frame.shotIndex
            }
        }
        if frame.sequence == 5, let saved = durableTerminalReplies[frame.raw],
           store?.records.contains(where: { $0.deduplicationKey == saved.identity }) == true {
            if let ack = SC4Wire.shotSequenceACK(for: frame) { send(ack) }
            return
        }
        if frame.sequence == 5, let ack = SC4Wire.shotSequenceACK(for: frame) {
            terminalACKs[frame.shotIndex] = ack
            terminalFrames[frame.shotIndex] = frame
            if terminalACKs.count > 128, let oldest = terminalACKs.keys.first {
                terminalACKs.removeValue(forKey: oldest)
                terminalFrames.removeValue(forKey: oldest)
            }
        }
        let record = assembler.ingest(frame: frame, deviceID: deviceID, deviceName: deviceName)
        if let record = record {
            guard save(record) else { return }
            if frame.sequence != 5, let ack = SC4Wire.shotSequenceACK(for: frame) { send(ack) }
            finishTerminalACK(index: frame.shotIndex, identity: record.deduplicationKey)
        } else if let identity = assembler.lastCompletedIdentity,
                  store?.records.contains(where: { $0.deduplicationKey == identity }) == true {
            // Only a full record already durable in the shot store can receive a
            // terminal ACK; an incomplete/invalid sequence 5 is deliberately held.
            if frame.sequence < 5, let ack = SC4Wire.shotSequenceACK(for: frame) { send(ack) }
            finishTerminalACK(index: frame.shotIndex, identity: identity)
        } else if frame.sequence < 5 {
            // Partial-shot bytes have already been durably appended to the journal.
            if let ack = SC4Wire.shotSequenceACK(for: frame) { send(ack) }
        } else {
            log(assembler.lastRejectionReason ?? "불완전한 샷 원본을 보존했습니다.")
        }
    }

    private func finishTerminalACK(index: UInt16, identity: String) {
        if let frame = terminalFrames.removeValue(forKey: index) {
            durableTerminalReplies[frame.raw] = (identity, Date())
            if durableTerminalReplies.count > 128 { durableTerminalReplies.removeValue(forKey: durableTerminalReplies.keys.first!) }
        }
        if let ack = terminalACKs.removeValue(forKey: index) { send(ack) }
    }

    @discardableResult
    private func save(_ record: ShotRecord) -> Bool {
        guard let store = store else { return false }
        do {
            let added = try store.append(record)
            shots = store.records.map { $0.enriched }
            if added {
                log("샷 {0} 저장 완료", record.deviceRecordID ?? "")
                status = AppMessage("연결됨 · 샷 저장 완료")
            } else { log("이미 저장된 샷입니다. 기존 기록을 유지했습니다.") }
            return true
        } catch { fail(error); disconnect(); return false }
    }

    private func send(_ data: Data) {
        guard ready, SC4CommandPolicy.allows(data) else { log("허용되지 않은 기기 명령을 차단했습니다."); return }
        guard outgoing.count < 64 else { log("송신 대기열이 가득 차 추가 요청을 멈췄습니다."); return }
        outgoing.append(data)
        flushWrites()
    }

    private func flushWrites() {
        guard !writeInFlight, !outgoing.isEmpty, let peripheral = peripheral,
              let characteristic = writeCharacteristic, ready else { return }
        if characteristic.properties.contains(.write) {
            writeInFlight = true
            peripheral.writeValue(outgoing.removeFirst(), for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse), peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(outgoing.removeFirst(), for: characteristic, type: .withoutResponse)
            DispatchQueue.main.async { [weak self] in self?.flushWrites() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight = false
        if let error = error { fail(error); return }
        flushWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { flushWrites() }

    private func log(_ key: String, _ arguments: String...) {
        log(AppMessage(key: key, arguments: arguments))
    }

    private func log(_ message: AppMessage) {
        logs.append(AppLogEntry(date: Date(), message: message))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    private func fail(_ error: Error) {
        log(error.localizedDescription)
        errorMessage = AppMessage(error.localizedDescription)
    }
}
