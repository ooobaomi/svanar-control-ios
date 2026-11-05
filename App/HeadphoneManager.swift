import Foundation
import CoreBluetooth
import Combine

struct HeadphoneCandidate: Identifiable {
    let id: UUID
    let name: String
    let identity: String
    var rssi: Int
}

@MainActor
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

    @Published private(set) var library = EQLibrary.initial()
    @Published private(set) var linksEnabled = false
    @Published private(set) var features = DeviceFeatures()
    @Published private(set) var touches: [TouchBinding] = []
    @Published private(set) var touchMessage = "先读取触控映射；只开放耳机实际返回的手势。"
    private var generation = 0
    private var lastObservedMode: ListeningMode?
    private struct PendingRequest {
        let id: UUID
        let command: UInt8
        let continuation: CheckedContinuation<[UInt8], Error>
        var acknowledged = false
        var response: [UInt8]?
    }
    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var stream = PacketStream()
    private var pending: PendingRequest?
    private var timeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var foreground = true

    override init() {
        super.init()
        do {
            let url = try storageURL("eq-preferences.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(EQPreferences.self, from: Data(contentsOf: url))
                try saved.library.validate(); library = saved.library; linksEnabled = saved.enabled
            } else { try persist(library, enabled: false) }
        } catch { status = "本机收藏读取未完成，原文件保留：\(error.localizedDescription)" }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
            guard let self = self, self.foreground, self.isReady, !self.isBusy else { return }
            self.perform {
                let actual = try await self.readMode()
                let changed = self.lastObservedMode != nil && self.lastObservedMode != actual
                self.mode = actual; self.lastObservedMode = actual
                if changed { try await self.applyLinkedEQ(actual) }
                try await self.readBatteries()
            }
        }
            }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            stopScan()
            if peripheral != nil { disconnect(); status = "已暂停前台控制；耳机音频由 iOS 管理" }
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
        guard device.state == .disconnected else { status = "等待旧控制连接断开后重试"; return }
        stopScan()
        generation += 1; lastObservedMode = nil; features = DeviceFeatures(); touches = []
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
        generation += 1; lastObservedMode = nil; features = DeviceFeatures(); touches = []
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
        let session = generation
        operation = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { if self.generation == session { self.isBusy = false } }
            do { try Task.checkCancellation(); try await work() }
            catch is CancellationError { }
            catch { if self.generation == session { self.status = "操作未完成：\(error.localizedDescription)" } }
        }
    }

    func refresh() {
        perform {
            self.mode = try await self.readMode()
            self.lastObservedMode = self.mode
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
                    if actual == target { self.lastObservedMode = actual; self.status = "耳机已确认：\(target.name)"; try await self.applyLinkedEQ(actual); return }
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


    private func storageURL(_ name: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SvanarControl", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
    private func persist(_ value: EQLibrary, enabled: Bool) throws {
        _ = try value.encoded()
        let data = try JSONEncoder().encode(EQPreferences(library: value, enabled: enabled))
        try data.write(to: storageURL("eq-preferences.json"), options: .atomic)
    }
    private func storeLibrary(_ value: EQLibrary, enabled: Bool? = nil) throws {
        let active = enabled ?? linksEnabled; try persist(value, enabled: active)
        library = value; linksEnabled = active
    }
    func saveProfile(name: String, replacing id: String? = nil, renameOnly: Bool = false) {
        do {
            let old = library.profiles.first { $0.id == id }
            let p = EQProfile(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), gains: renameOnly ? old?.gains ?? draft : draft)
            var next = library; try next.add(p); try storeLibrary(next); status = "收藏已保存，耳机 EQ 未改动"
        } catch { status = "收藏未保存：\(error.localizedDescription)" }
    }
    func loadProfile(_ id: String) { if let p = library.profiles.first(where: { $0.id == id }) { draft = p.gains; status = "收藏已载入草稿，应用后才写入耳机" } }
    func deleteProfile(_ id: String) {
        do { var next = library; next.remove(id); try storeLibrary(next); status = "收藏及相关绑定已删除" }
        catch { status = error.localizedDescription }
    }
    func bindProfile(_ id: String, to mode: ListeningMode) {
        do {
            var next = library
            if id.isEmpty { next.links.removeValue(forKey: String(mode.rawValue)) }
            else { guard next.profiles.contains(where: { $0.id == id }) else { throw HeadphoneError.message("收藏已不存在") }; next.links[String(mode.rawValue)] = id }
            try storeLibrary(next); status = "模式绑定已保存，未立即写入耳机"
        } catch { status = error.localizedDescription }
    }
    func setLinksEnabled(_ value: Bool) {
        do { try storeLibrary(library, enabled: value); status = value ? "联动已开启：首次连接只读，后续模式变化才应用" : "模式联动已关闭" }
        catch { status = error.localizedDescription }
    }
    func importLibrary(_ value: EQLibrary) {
        do { try storeLibrary(library.merged(with: value), enabled: false); status = "收藏已导入；自动联动关闭，未改动耳机" }
        catch { status = "导入未完成，原收藏保留：\(error.localizedDescription)" }
    }
    private func applyLinkedEQ(_ mode: ListeningMode) async throws {
        guard linksEnabled, let target = library.gains(for: mode) else { return }
        let before = try await readEQ()
        if before != target {
            status = "模式已确认，正在应用绑定 EQ…"
            _ = try await request(8, HeadphoneProtocol.eqPayload(target))
            try await Task.sleep(nanoseconds: 500_000_000)
            let actual = try await readEQ(); eqReadback = actual; draft = actual
            guard actual == target else { throw HeadphoneError.message("模式已切换，但绑定 EQ 回读未匹配") }
        } else { eqReadback = before; draft = before }
        status = "\(mode.name)与绑定 EQ 已回读确认"
    }
    func readExtras() {
        perform {
            for command in [UInt8(2),5,6,9,11,12,13] { self.features.accept(command, try await self.request(command)) }
            self.status = "扩展信息已读取；未写固件，也不更改 iOS 编码器"
        }
    }
    func readStrength() {
        perform {
            for command in [UInt8(2),5,6] { self.features.accept(command, try await self.request(command)) }
            self.status = "已读取强度能力；未写入未知档位"
        }
    }
    func setGame(_ enabled: Bool) {
        guard features.supportsGame == true, features.gameEnabled != nil else { status = "先读取扩展信息以确认支持游戏模式"; return }
        perform {
            _ = try await self.request(9, [enabled ? 1 : 0]); try await Task.sleep(nanoseconds: 600_000_000)
            let p = try await self.request(9); self.features.accept(9, p)
            guard p == [enabled ? 1 : 0] else { throw HeadphoneError.message("游戏模式回读不一致") }
            self.status = "游戏模式已\(enabled ? "开启" : "关闭")，耳机回读一致"
        }
    }
    func readTouches() {
        perform {
            do { self.touches = try TouchBinding.decode(await self.request(4)); self.touchMessage = "已读取映射；写入前将备份，写入后回读确认。" }
            catch { self.touchMessage = "本次触控查询未成功，写入保持禁用：\(error.localizedDescription)"; throw error }
        }
    }
    private func touchBackupURL() throws -> URL {
        guard identity.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else { throw HeadphoneError.message("耳机身份未确认") }
        return try storageURL("touch-original-" + identity.replacingOccurrences(of: ":", with: "") + ".json")
    }
    private func backupTouches(_ entries: [TouchBinding]) throws {
        let url = try touchBackupURL()
        if !FileManager.default.fileExists(atPath: url.path) { try JSONEncoder().encode(TouchBackup(identity: identity, mappings: entries)).write(to: url, options: .atomic) }
        else { let old = try JSONDecoder().decode(TouchBackup.self, from: Data(contentsOf: url)); guard old.identity == identity else { throw HeadphoneError.message("备份身份不匹配") }; for p in old.mappings { try p.validate() } }
    }
    private func writeTouch(_ target: TouchBinding, before: [TouchBinding]) async throws -> [TouchBinding] {
        try target.validate()
        guard let old = before.first(where: { $0.id == target.id }) else { throw HeadphoneError.message("耳机未返回此手势") }
        if old == target { return before }
        _ = try await request(4, target.payload); try await Task.sleep(nanoseconds: 450_000_000)
        let actual = try TouchBinding.decode(await request(4)); touches = actual
        guard Set(actual.map(\.id)) == Set(before.map(\.id)), actual.contains(target),
              before.filter({ $0.id != target.id }).allSatisfy({ actual.contains($0) }) else {
            throw HeadphoneError.message("触控回读未匹配，请检查映射或恢复原备份")
        }
        return actual
    }
    func setTouch(_ value: TouchBinding) {
        perform { let current = try TouchBinding.decode(await self.request(4)); try self.backupTouches(current); self.touches = try await self.writeTouch(value, before: current); self.touchMessage = "触控写入回读一致；实际手势请在耳机上确认。" }
    }
    func restoreTouches() {
        perform {
            let backup = try JSONDecoder().decode(TouchBackup.self, from: Data(contentsOf: self.touchBackupURL()))
            guard backup.identity == self.identity else { throw HeadphoneError.message("备份身份不匹配") }
            for value in backup.mappings { try value.validate() }
            var actual = try TouchBinding.decode(await self.request(4))
            guard Set(actual.map(\.id)) == Set(backup.mappings.map(\.id)) else { throw HeadphoneError.message("备份与当前手势集合不匹配") }
            for value in backup.mappings { actual = try await self.writeTouch(value, before: actual) }
            guard actual.sorted(by: { $0.id < $1.id }) == backup.mappings.sorted(by: { $0.id < $1.id }) else { throw HeadphoneError.message("触控恢复未匹配") }
            self.touches = actual; self.touchMessage = "原触控备份已恢复，回读一致。"
        }
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
        let session = generation
        let response: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pending = PendingRequest(id: id, command: command, continuation: continuation)
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
        try Task.checkCancellation()
        guard session == generation else { throw CancellationError() }
        return response
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
        if let error = error {
            central.cancelPeripheralConnection(device); reset("蓝牙写入失败：\(error.localizedDescription)"); return
        }
        pending?.acknowledged = true
        if let data = pending?.response { finishPending(.success(data)) }
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard device == peripheral, characteristic.uuid == CBUUID(string: HeadphoneProtocol.rx),
              error == nil, let data = characteristic.value else { return }
        for packet in stream.feed(data) {
            if pending?.command == packet.command { pending?.response = packet.payload; if pending?.acknowledged == true { finishPending(.success(packet.payload)) } }
        }
    }
}
