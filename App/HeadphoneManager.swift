import Foundation
import CoreBluetooth
import Combine

struct HeadphoneCandidate: Identifiable {
    let id: UUID
    let name: String
    let identity: String
    var rssi: Int
}

final class HeadphoneManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var candidates: [HeadphoneCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var mode: ListeningMode?
    @Published private(set) var eqReadback: [Int]?
    @Published private(set) var leftBattery: Int?
    @Published private(set) var rightBattery: Int?
    @Published private(set) var identity = ""
    @Published var status = "请允许蓝牙权限，然后扫描耳机"
    @Published var draft = Array(repeating: 0, count: 10)

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var stream = PacketStream()
    private var pending: (id: UUID, command: UInt8, continuation: CheckedContinuation<[UInt8], Error>)?
    private var timeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var foreground = true

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self, self.foreground, self.isReady, !self.isBusy else { return }
            self.perform {
                self.mode = try await self.readMode()
                try await self.readBatteries()
            }
        }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            stopScan()
            operation?.cancel()
            finishPending(.failure(CancellationError()))
        } else if isReady && !isBusy {
            refresh()
        }
    }

    func scan() {
        guard central.state == .poweredOn else { status = "请在设置中开启蓝牙并允许本 App 使用"; return }
        guard !isReady, !isConnecting else { return }
        candidates.removeAll()
        discovered.removeAll()
        isScanning = true
        status = "正在扫描，请从列表选择你的耳机"
        // The verified firmware does not advertise service UUIDs; do not filter by ff77.
        central.scanForPeripherals(withServices: nil,
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopScan()
            if self?.candidates.isEmpty == true { self?.status = "未发现耳机，请唤醒双耳并关闭电脑控制面板后重试" }
        }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        scanTimeout?.cancel()
        scanTimeout = nil
    }

    func connect(_ candidate: HeadphoneCandidate) {
        guard let device = discovered[candidate.id], !isConnecting, !isReady else { return }
        stopScan()
        identity = candidate.identity
        mode = nil; eqReadback = nil; leftBattery = nil; rightBattery = nil
        peripheral = device
        device.delegate = self
        isConnecting = true
        status = "正在连接并订阅控制通知…"
        central.connect(device)
        connectTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isConnecting else { return }
            self.central.cancelPeripheralConnection(device)
            self.reset("连接超时，请关闭其他设备上的控制 App 后重试")
        }
        connectTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func disconnect() {
        stopScan()
        if let device = peripheral { central.cancelPeripheralConnection(device) }
        reset("已断开控制连接；耳机的音频连接由 iOS 管理")
    }

    private func reset(_ message: String) {
        connectTimeout?.cancel(); connectTimeout = nil
        operation?.cancel(); operation = nil
        finishPending(.failure(HeadphoneError.message(message)))
        peripheral = nil; writeCharacteristic = nil; receiveCharacteristic = nil
        stream.clear()
        isReady = false; isConnecting = false; isBusy = false
        mode = nil; eqReadback = nil; leftBattery = nil; rightBattery = nil
        status = message
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        guard isReady, !isBusy else { return }
        isBusy = true
        operation = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            do { try Task.checkCancellation(); try await work() }
            catch is CancellationError { }
            catch { self.status = "操作未完成：\(error.localizedDescription)" }
        }
    }

    func refresh() {
        perform {
            self.mode = try await self.readMode()
            self.eqReadback = try await self.readEQ()
            if let values = self.eqReadback { self.draft = values }
            try await self.readBatteries()
            self.status = "已读取耳机模式、EQ 与电量"
        }
    }

    func changeMode(_ target: ListeningMode) {
        perform {
            self.status = "正在切换到\(target.name)，等待耳机确认…"
            for attempt in 0..<2 {
                _ = try await self.request(6, [target.rawValue, 0])
                for _ in 0..<4 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    let actual = try await self.readMode()
                    self.mode = actual
                    if actual == target { self.status = "耳机已确认：\(target.name)"; return }
                }
                if attempt == 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            throw HeadphoneError.message("模式回读未匹配，请双耳佩戴后重试")
        }
    }

    func applyEQ() {
        let values = draft
        perform {
            self.status = "正在写入硬件 EQ…"
            let payload = try HeadphoneProtocol.eqPayload(values)
            _ = try await self.request(8, payload)
            try await Task.sleep(nanoseconds: 500_000_000)
            let actual = try await self.readEQ()
            self.eqReadback = actual
            guard actual == values else { throw HeadphoneError.message("EQ 回读不一致，请重新读取") }
            self.status = "10 段 EQ 已写入耳机，回读一致"
        }
    }

    func saveDraft() {
        guard (try? HeadphoneProtocol.eqPayload(draft)) != nil else { return }
        UserDefaults.standard.set(draft, forKey: "customEQ")
        status = "自定义 EQ 已保存到 iPhone，未自动写入耳机"
    }

    func loadDraft() {
        guard let values = UserDefaults.standard.array(forKey: "customEQ") as? [Int],
              (try? HeadphoneProtocol.eqPayload(values)) != nil else {
            status = "尚未保存自定义 EQ"; return
        }
        draft = values
        status = "已载入 EQ 草稿，点击应用后才写入耳机"
    }

    private func readMode() async throws -> ListeningMode {
        let bytes = try await request(6)
        guard bytes.count == 2, let result = ListeningMode(rawValue: bytes[0]) else {
            throw HeadphoneError.message("耳机模式响应无效")
        }
        return result
    }

    private func readEQ() async throws -> [Int] {
        let payload = try await request(8)
        return try HeadphoneProtocol.decodeEQ(payload)
    }

    private func readBatteries() async throws {
        let bytes = try await request(3)
        leftBattery = bytes.count >= 1 && bytes[0] & 127 <= 100 ? Int(bytes[0] & 127) : nil
        rightBattery = bytes.count >= 2 && bytes[1] & 127 <= 100 ? Int(bytes[1] & 127) : nil
        // Do not label the unverified third byte as the case battery.
    }

    private func request(_ command: UInt8, _ payload: [UInt8] = []) async throws -> [UInt8] {
        try Task.checkCancellation()
        guard isReady, let device = peripheral, let characteristic = writeCharacteristic else {
            throw HeadphoneError.message("耳机控制接口未连接")
        }
        guard pending == nil else { throw HeadphoneError.message("耳机指令正在处理中") }
        let data = HeadphoneProtocol.encode(command, payload)
        guard data.count <= device.maximumWriteValueLength(for: .withResponse) else {
            throw HeadphoneError.message("蓝牙数据包超过设备支持长度")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pending = (id, command, continuation)
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.pending?.id == id else { return }
                // No sequence number exists in this protocol. Disconnect on timeout
                // so a late response cannot be mistaken for a later transaction.
                if let device = self.peripheral { self.central.cancelPeripheralConnection(device) }
                self.reset("耳机响应超时，请重新连接")
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            device.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func finishPending(_ result: Result<[UInt8], Error>) {
        guard let request = pending else { return }
        pending = nil
        timeout?.cancel(); timeout = nil
        request.continuation.resume(with: result)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "蓝牙已就绪，点击扫描耳机"
        case .unauthorized: reset("蓝牙权限未开启，请前往 iOS 设置授权")
        case .poweredOff: reset("蓝牙已关闭")
        case .unsupported: reset("此设备不支持蓝牙低功耗")
        default: reset("蓝牙正在初始化")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let classic = HeadphoneProtocol.classicIdentity(data) else { return }
        discovered[device.identifier] = device
        let entry = HeadphoneCandidate(id: device.identifier,
                                      name: device.name ?? "HIFIMAN SVANAR WIRELESS",
                                      identity: classic, rssi: RSSI.intValue)
        if let index = candidates.firstIndex(where: { $0.id == entry.id }) { candidates[index] = entry }
        else { candidates.append(entry) }
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard device == peripheral else { return }
        device.discoverServices([CBUUID(string: HeadphoneProtocol.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard device == peripheral else { return }
        reset("连接失败：\(error?.localizedDescription ?? "请唤醒耳机后重试")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard device == peripheral else { return }
        reset("耳机控制连接已断开，请重新扫描连接")
    }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard device == peripheral else { return }
        guard error == nil, let service = device.services?.first(where: {
            $0.uuid == CBUUID(string: HeadphoneProtocol.service)
        }) else { disconnect(); status = "耳机没有已验证的控制服务"; return }
        device.discoverCharacteristics([CBUUID(string: HeadphoneProtocol.tx), CBUUID(string: HeadphoneProtocol.rx)], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard device == peripheral else { return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: HeadphoneProtocol.tx) }
        receiveCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: HeadphoneProtocol.rx) }
        guard error == nil, let tx = writeCharacteristic, tx.properties.contains(.write),
              let rx = receiveCharacteristic, rx.properties.contains(.notify) else {
            disconnect(); status = "耳机控制特征不匹配"; return
        }
        device.setNotifyValue(true, for: rx)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard device == peripheral, characteristic.uuid == CBUUID(string: HeadphoneProtocol.rx) else { return }
        guard error == nil, characteristic.isNotifying else {
            disconnect(); status = "订阅耳机通知失败"; return
        }
        connectTimeout?.cancel(); connectTimeout = nil
        stream.clear(); isConnecting = false; isReady = true
        status = "硬件接口已连接，正在读取状态"
        refresh()
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device == peripheral, characteristic.uuid == CBUUID(string: HeadphoneProtocol.tx) else { return }
        if let error = error { finishPending(.failure(error)) }
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device == peripheral, characteristic.uuid == CBUUID(string: HeadphoneProtocol.rx),
              error == nil, let data = characteristic.value else { return }
        for packet in stream.feed(data) {
            if pending?.command == packet.command { finishPending(.success(packet.payload)) }
        }
    }
}
