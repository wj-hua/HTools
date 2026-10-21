import AppKit
import Combine
import CoreBluetooth
import SwiftUI

/// 黑鲨散热背夹的 BLE 连接与状态。
///
/// 背夹一次只处理一条命令，连发会被静默丢弃，所以所有命令都走 `pending` 队列：
/// 发出一条后等对应 cmd 的通知（最多 700 ms）再发下一条。
/// CBCentralManager 首次创建时才会弹蓝牙授权，因此延迟到进入页面时再创建。
@MainActor
final class CoolerController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case unavailable(String)
        case searching
        case connecting
        case ready
        /// 定时关闭到点，背夹整机断电，无法通过蓝牙开机。
        case poweredOff
    }

    struct Discovered: Identifiable {
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int?
        var id: UUID { peripheral.identifier }
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var discovered: [Discovered] = []
    @Published private(set) var deviceName = ""
    @Published private(set) var firmware: String?
    @Published private(set) var coolingMode: CoolingMode?
    @Published private(set) var coldTemperature: Int?
    @Published private(set) var hotTemperature: Int?
    @Published private(set) var lowTempProtect = true
    @Published private(set) var shutdownUnits = 0
    @Published private(set) var shutdownDeadline: Date?
    @Published private(set) var lightOn = false
    @Published private(set) var lightEffect = LightEffect.all[0]
    @Published private(set) var lightColorCount = 0
    @Published private(set) var lightSpeedLevel = 1
    @Published private(set) var lightColors: [UInt32]
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    /// 关闭制冷前的模式，重新打开时恢复它。
    private(set) var lastCoolingMode: CoolingMode = .smart

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var isPageVisible = false
    /// 用户点了“断开”：本次运行不再自动连接，直到手动点连接。
    private var userDisconnected = false

    private var pending: [Data] = []
    private var pumpTask: Task<Void, Never>?
    private var awaiting: (token: Int, command: UInt8, continuation: CheckedContinuation<Void, Never>)?
    private var awaitToken = 0
    private var heartbeatTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private static let lastDeviceKey = "cooler.lastDevice"
    private static let lightKey = "cooler.light"

    /// 定时关闭单位为 15 分钟，0 = 不开启。协议最小单位是 15 分钟，原版只给 30 分钟步进。
    static let shutdownOptions = [0, 1, 2, 4, 8, 12]

    override init() {
        lightColors = [0xFF00DC, 0x469DFC, 0xFFD700]
        super.init()
        loadLightConfig()
    }

    var isReady: Bool { phase == .ready }
    var isCooling: Bool { coolingMode != nil && coolingMode != .lightOnly }

    // MARK: - 页面生命周期

    func pageAppeared() {
        isPageVisible = true
        if let central {
            startSearchingIfNeeded(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    /// 离开页面只停止扫描，已建立的连接和心跳继续保持。
    func pageDisappeared() {
        isPageVisible = false
        central?.stopScan()
    }

    private func startSearchingIfNeeded(_ central: CBCentralManager) {
        guard central.state == .poweredOn, phase != .ready else { return }
        if peripheral == nil, phase != .poweredOff { phase = .searching }

        // 背夹被连着时不广播：先把系统里已连接的和上次连过的放进列表，不依赖广播也能连。
        let known = central.retrieveConnectedPeripherals(withServices: [CoolerProtocol.service])
            + central.retrievePeripherals(withIdentifiers: lastDeviceID.map { [$0] } ?? [])
        for item in known { remember(item, name: item.name, rssi: nil) }

        if peripheral == nil, !userDisconnected, phase != .poweredOff, let id = lastDeviceID,
           let target = discovered.first(where: { $0.id == id }) {
            // CoreBluetooth 的 connect 不会超时，背夹开机进入范围后会自动连上。
            connect(target)
        }
        if isPageVisible {
            central.scanForPeripherals(withServices: nil)
        }
    }

    private var lastDeviceID: UUID? {
        defaults.string(forKey: Self.lastDeviceKey).flatMap(UUID.init(uuidString:))
    }

    private func remember(_ peripheral: CBPeripheral, name: String?, rssi: Int?) {
        let title = name ?? peripheral.name ?? "黑鲨散热背夹"
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].name = title
            if let rssi { discovered[index].rssi = rssi }
        } else {
            discovered.append(Discovered(peripheral: peripheral, name: title, rssi: rssi))
        }
    }

    // MARK: - 连接

    func connect(_ item: Discovered) {
        guard let central else { return }
        userDisconnected = false
        if let current = peripheral, current.identifier != item.id {
            central.cancelPeripheralConnection(current)
            resetLink()
        }
        peripheral = item.peripheral
        deviceName = item.name
        item.peripheral.delegate = self
        phase = .connecting
        central.connect(item.peripheral)
    }

    func disconnect() {
        userDisconnected = true
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetLink()
        peripheral = nil
        phase = .searching
        if let central { startSearchingIfNeeded(central) }
    }

    /// 退出 App 时主动断开，避免背夹残留旧连接。
    func shutdown() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    private func resetLink() {
        writeCharacteristic = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pending.removeAll()
        resolveAwaiting(command: nil, token: nil)
        coldTemperature = nil
        hotTemperature = nil
    }

    private func linkReady(_ peripheral: CBPeripheral) {
        phase = .ready
        defaults.set(peripheral.identifier.uuidString, forKey: Self.lastDeviceKey)
        central?.stopScan()
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // 冷连接后约 1.5 秒内背夹不应答。
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.pending.append(contentsOf: CoolerProtocol.initSequence)
            self.pump()
            // 原版每 2 秒一次心跳，响应里带温度。队列忙时跳过，避免和设置命令挤在一起。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if self.pending.isEmpty, self.awaiting == nil { self.enqueue(CoolerProtocol.heartbeat) }
            }
        }
    }

    // MARK: - 命令队列

    private func enqueue(_ frames: Data...) {
        for frame in frames {
            // 拖动取色时会连续产生灯效帧，只保留最新一帧。
            if frame.first == 0x2F, let index = pending.firstIndex(where: { $0.first == 0x2F }) {
                pending[index] = frame
            } else {
                pending.append(frame)
            }
        }
        pump()
    }

    private func pump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                await self.transmit(self.pending.removeFirst())
            }
            self?.pumpTask = nil
        }
    }

    private func transmit(_ frame: Data) async {
        guard let peripheral, let writeCharacteristic else { return }
        if frame.count > peripheral.maximumWriteValueLength(for: .withoutResponse) {
            // 47 字节灯效帧依赖背夹自己发起的 MTU 51 协商，刚连上的一两秒内可能还不够。
            errorMessage = "蓝牙链路暂不支持发送灯效配置，请稍后再试。"
            return
        }
        peripheral.writeValue(frame, for: writeCharacteristic, type: .withoutResponse)
        awaitToken += 1
        let token = awaitToken
        await withCheckedContinuation { continuation in
            awaiting = (token, frame[1], continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.resolveAwaiting(command: nil, token: token)
            }
        }
        // 原版收到响应后隔几十毫秒再发下一条。
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// command 为 nil 表示超时或断开，直接放行。
    private func resolveAwaiting(command: UInt8?, token: Int?) {
        guard let awaiting else { return }
        if let command, command != awaiting.command { return }
        if let token, token != awaiting.token { return }
        self.awaiting = nil
        awaiting.continuation.resume()
    }

    private func handle(_ data: Data) {
        guard let (command, _, response) = CoolerProtocol.parse(data) else { return }
        switch response {
        case .cooling(let mode):
            if let mode { apply(mode) }
        case .light(let effect, let period, let colors):
            applyLight(effect: effect, period: period, colors: colors)
        case .lowTempProtect(let on):
            lowTempProtect = on
        case .firmware(let text):
            firmware = text.isEmpty ? nil : text
        case .shutdownTimer(let units, let elapsed):
            shutdownUnits = units
            let left = units * CoolerProtocol.shutdownUnitMinutes * 60 - elapsed
            shutdownDeadline = units == 0 ? nil : Date().addingTimeInterval(TimeInterval(max(0, left)))
        case .temperatures(let cold, let hot):
            coldTemperature = cold
            hotTemperature = hot
        case .ack:
            break
        }
        resolveAwaiting(command: command, token: nil)
    }

    // MARK: - 制冷 / 设置

    private func apply(_ mode: CoolingMode) {
        coolingMode = mode
        if mode != .lightOnly { lastCoolingMode = mode }
    }

    func setMode(_ mode: CoolingMode) {
        guard isReady else { return }
        // 先改界面再等回查；设置 ACK 不带当前值，原版也是设置后马上回查。
        apply(mode)
        enqueue(CoolerProtocol.setCooling(mode), CoolerProtocol.setPreset(mode), CoolerProtocol.queryCooling)
    }

    func setCooling(_ on: Bool) {
        setMode(on ? lastCoolingMode : .lightOnly)
    }

    func setLowTempProtect(_ on: Bool) {
        guard isReady else { return }
        lowTempProtect = on
        enqueue(CoolerProtocol.setLowTempProtect(on), CoolerProtocol.queryLowTempProtect)
    }

    func setShutdown(units: Int) {
        guard isReady else { return }
        shutdownUnits = units
        shutdownDeadline = units == 0 ? nil : Date().addingTimeInterval(TimeInterval(units * CoolerProtocol.shutdownUnitMinutes * 60))
        enqueue(CoolerProtocol.setShutdownTimer(units: units), CoolerProtocol.queryShutdownTimer)
        toastMessage = units == 0 ? "已取消定时关闭" : "将在\(Self.shutdownLabel(units))关闭背夹"
    }

    static func shutdownLabel(_ units: Int) -> String {
        let minutes = units * CoolerProtocol.shutdownUnitMinutes
        switch minutes {
        case 0: return "不开启"
        case ..<60: return "\(minutes) 分钟后"
        default: return minutes % 60 == 0 ? "\(minutes / 60) 小时后" : "\(minutes / 60) 小时 \(minutes % 60) 分钟后"
        }
    }

    // MARK: - 风扇灯效

    func setLightOn(_ on: Bool) {
        lightOn = on
        sendLight()
    }

    func setLightEffect(_ effect: LightEffect) {
        lightEffect = effect
        // 同原版：换模式时配色回到该模式的默认。
        lightColorCount = effect.schemes[0]
        sendLight()
    }

    func setLightColorCount(_ count: Int) {
        lightColorCount = count
        sendLight()
    }

    func setLightSpeed(_ level: Int) {
        lightSpeedLevel = level
        sendLight()
    }

    func setLightColor(_ color: Color, at index: Int) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        // 广色域颜色转换到 sRGB 后分量可能超出 0...1。
        let byte = { (component: CGFloat) in UInt32((min(max(component, 0), 1) * 255).rounded()) }
        let value = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        guard lightColors[index] != value else { return }
        lightColors[index] = value
        sendLight()
    }

    private func sendLight() {
        saveLightConfig()
        guard isReady else { return }
        let colors = Array(lightColors.prefix(lightColorCount))
        let period = lightEffect.period(colorCount: lightColorCount, level: lightSpeedLevel)
        enqueue(lightOn ? CoolerProtocol.setLight(effect: lightEffect.id, periodMs: period, colors: colors) : CoolerProtocol.lightOff)
    }

    /// 背夹回报的当前灯效优先；灯效关闭时保留本地记住的上次配置，方便重新打开。
    private func applyLight(effect id: UInt8, period: Int, colors: [UInt32]) {
        guard let effect = LightEffect.find(id) else {
            lightOn = false
            return
        }
        lightOn = true
        lightEffect = effect
        lightColorCount = effect.schemes.contains(colors.count) ? colors.count : effect.schemes[0]
        lightSpeedLevel = effect.level(ofPeriod: period)
        for (index, color) in colors.prefix(3).enumerated() { lightColors[index] = color }
    }

    private func saveLightConfig() {
        defaults.set([Int(lightEffect.id), lightColorCount, lightSpeedLevel] + lightColors.map { Int($0) }, forKey: Self.lightKey)
    }

    private func loadLightConfig() {
        guard let values = defaults.array(forKey: Self.lightKey) as? [Int], values.count == 6,
              let effect = LightEffect.find(UInt8(clamping: values[0])) else { return }
        lightEffect = effect
        lightColorCount = effect.schemes.contains(values[1]) ? values[1] : effect.schemes[0]
        lightSpeedLevel = min(max(values[2], 0), 2)
        lightColors = values[3...].map { UInt32(clamping: $0) }
    }
}

// MARK: - CoreBluetooth

extension CoolerController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                startSearchingIfNeeded(central)
            case .unauthorized:
                phase = .unavailable("请在“系统设置 > 隐私与安全性 > 蓝牙”中允许 HTools 使用蓝牙。")
            case .unsupported:
                phase = .unavailable("这台 Mac 不支持低功耗蓝牙。")
            default:
                resetLink()
                peripheral = nil
                phase = .unavailable("蓝牙已关闭，请在控制中心打开蓝牙。")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard CoolerProtocol.isCooler(name) else { return }
        MainActor.assumeIsolated {
            remember(peripheral, name: name, rssi: RSSI.intValue)
            if !userDisconnected, self.peripheral == nil, peripheral.identifier == lastDeviceID,
               let item = discovered.first(where: { $0.id == peripheral.identifier }) {
                connect(item)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            peripheral.discoverServices([CoolerProtocol.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if peripheral === self.peripheral, self.phase == .connecting { central.connect(peripheral) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            resetLink()
            // 断开发生在定时关闭到点前后 5 秒内，视为背夹按定时关机，重连没有意义。
            if let deadline = shutdownDeadline, Date() >= deadline.addingTimeInterval(-5) {
                self.peripheral = nil
                shutdownUnits = 0
                shutdownDeadline = nil
                phase = .poweredOff
                startSearchingIfNeeded(central)
                return
            }
            // 意外断开（走远、休眠）：挂起重连，背夹回到范围内会自动连上。
            phase = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == CoolerProtocol.service }) else {
                errorMessage = "没有找到背夹的控制服务，可能是不支持的型号。"
                disconnect()
                return
            }
            peripheral.discoverCharacteristics([CoolerProtocol.writeCharacteristic, CoolerProtocol.notifyCharacteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let characteristics = service.characteristics ?? []
            guard let write = characteristics.first(where: { $0.uuid == CoolerProtocol.writeCharacteristic }),
                  let notify = characteristics.first(where: { $0.uuid == CoolerProtocol.notifyCharacteristic }) else {
                errorMessage = "背夹的控制特征不完整，可能是不支持的型号。"
                disconnect()
                return
            }
            writeCharacteristic = write
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == CoolerProtocol.notifyCharacteristic, characteristic.isNotifying else { return }
            linkReady(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { handle(data) }
    }
}
