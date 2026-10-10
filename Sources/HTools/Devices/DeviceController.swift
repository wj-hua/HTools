import AppKit
import Combine
import CoreImage

/// 原 ADB Bar 的 MenuController 改写为可观察的状态对象：菜单项变成方法，
/// NSAlert 输入框变成参数，弹窗变成 @Published 状态交给 SwiftUI 展示。
@MainActor
final class DeviceController: ObservableObject {
    struct QRPairing: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    let adb: ADBService?
    let setupError: String?
    private let recorder: RecordingController?
    /// 页面内嵌的投屏（Android 视频流 / 鸿蒙截图预览）。
    let mirror = DeviceMirror()
    private var mirrorObservation: AnyCancellable?

    @Published private(set) var devices: [ADBDevice] = []
    @Published private(set) var developerState = DeveloperOptionState(layoutBounds: false, overdraw: false, pointerLocation: false)
    @Published private(set) var foregroundPackage: String?
    @Published private(set) var deviceInfo: DeviceInfo?
    @Published private(set) var isLoadingInfo = false
    @Published private(set) var isRecording = false
    @Published private(set) var busyMessage: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var qrPairing: QRPairing?
    @Published var recordingFormat: RecordingFormat = .mp4
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published private(set) var lastWirelessAddress = UserDefaults.standard.string(forKey: "lastWirelessAddress")
    @Published private(set) var lastHDCAddress = UserDefaults.standard.string(forKey: "lastHDCAddress")

    private var qrPairingTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    init() {
        do {
            let adb = try ADBService()
            self.adb = adb
            self.recorder = RecordingController(adb: adb)
            self.setupError = nil
        } catch {
            self.adb = nil
            self.recorder = nil
            self.setupError = error.localizedDescription
        }
        // 投屏状态变化时刷新页面布局；不转发鸿蒙预览的逐帧图片，避免整页每秒重绘几次。
        mirrorObservation = Publishers.Merge(
            mirror.$phase.map { _ in () },
            mirror.$deviceSize.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] in self?.objectWillChange.send() }
        Task { await refreshDevices() }
    }

    var isBusy: Bool { busyMessage != nil }
    var hasADB: Bool { adb?.hasADB ?? false }
    var hasHDC: Bool { adb?.hasHDC ?? false }

    var connectedCount: Int {
        devices.filter { $0.state == .device }.count
    }

    var selectedDevice: ADBDevice? {
        guard let id = adb?.selectedDeviceID else { return nil }
        return devices.first { $0.identifier == id }
    }

    // MARK: - 设备列表

    /// 页面可见时每 3 秒刷新一次设备列表，插拔数据线无需手动刷新。
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.refreshDevices(includeDetails: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { break }
                if !self.isBusy { await self.refreshDevices() }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshDevices(includeDetails: Bool = false) async {
        guard let adb else {
            hasLoaded = true
            return
        }
        let previousSelection = adb.selectedDeviceID
        do {
            let devices = try await adb.listDevices()
            if self.devices != devices { self.devices = devices }
            let connected = devices.filter { $0.state == .device }
            if let mirrored = mirror.device, !connected.contains(where: { $0.identifier == mirrored.identifier }) {
                mirror.stop()
            }
            if let selected = adb.selectedDeviceID,
               !connected.contains(where: { $0.identifier == selected }),
               let first = connected.first {
                adb.selectDevice(first)
            } else if adb.selectedDeviceID == nil, let first = connected.first {
                adb.selectDevice(first)
            }
            if connected.isEmpty {
                foregroundPackage = nil
                deviceInfo = nil
            } else if includeDetails || previousSelection != adb.selectedDeviceID {
                await refreshDetails()
            }
        } catch {
            foregroundPackage = nil
        }
        hasLoaded = true
        objectWillChange.send()
    }

    func select(_ device: ADBDevice) {
        guard let adb, device.state == .device else { return }
        if mirror.device?.identifier != device.identifier { mirror.stop() }
        adb.selectDevice(device)
        foregroundPackage = nil
        deviceInfo = nil
        objectWillChange.send()
        Task { await refreshDetails() }
    }

    private func refreshDetails() async {
        guard let adb, selectedDevice?.state == .device else { return }
        if selectedDevice?.bridge == .adb, let state = try? await adb.developerOptionState() {
            developerState = state
        }
        foregroundPackage = try? await adb.foregroundPackage()
        await loadDeviceInfo()
    }

    func loadDeviceInfo() async {
        guard let adb, selectedDevice != nil else { return }
        isLoadingInfo = true
        deviceInfo = try? await adb.deviceInfo()
        isLoadingInfo = false
    }

    // MARK: - 通用操作封装

    private func run(_ progress: String, operation: @escaping @MainActor (ADBService) async throws -> String?) {
        guard let adb, !isBusy else { return }
        busyMessage = progress
        Task {
            do {
                let message = try await operation(adb)
                toastMessage = message ?? "操作完成"
            } catch {
                errorMessage = error.localizedDescription
            }
            busyMessage = nil
            isRecording = recorder?.isRecording ?? false
            await refreshDevices(includeDetails: true)
        }
    }

    // MARK: - 连接

    func enableWireless() {
        let bridge = selectedDevice?.bridge.displayName ?? "ADB"
        run("正在切换 Wi-Fi \(bridge)…") { adb in
            let output = try await adb.enableWirelessForActiveDevice()
            return output.isEmpty ? "Wi-Fi \(bridge) 已连接" : output
        }
    }

    func connect(address: String) {
        run("正在连接 \(address)…") { [weak self] adb in
            let output = try await adb.connect(address: address)
            self?.lastWirelessAddress = UserDefaults.standard.string(forKey: "lastWirelessAddress")
            return output
        }
    }

    func connectHDC(address: String) {
        run("正在连接 HDC · \(address)…") { [weak self] adb in
            let output = try await adb.connectHDC(address: address)
            self?.lastHDCAddress = UserDefaults.standard.string(forKey: "lastHDCAddress")
            return output
        }
    }

    func pair(address: String, code: String) {
        run("正在与设备配对…") { adb in
            _ = try await adb.pair(address: address, pairingCode: code)
            return "无线配对成功；设备未出现时请再连接指定 IP"
        }
    }

    func startQRPairing() {
        guard let adb, !isBusy else { return }
        let serviceName = "studio-\(randomToken(length: 10))"
        let password = randomToken(length: 12)
        guard let image = qrCodeImage(for: "WIFI:T:ADB;S:\(serviceName);P:\(password);;") else {
            errorMessage = "无法生成配对二维码。"
            return
        }

        busyMessage = "正在等待手机扫描二维码…"
        qrPairing = QRPairing(image: image)
        qrPairingTask = Task { [weak self] in
            do {
                _ = try await adb.pairWithQRCode(serviceName: serviceName, password: password)
                guard let self, !Task.isCancelled else { return }
                self.finishQRPairing()
                self.toastMessage = "二维码无线配对成功"
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.finishQRPairing()
                self.errorMessage = error.localizedDescription
            }
            await self?.refreshDevices(includeDetails: true)
        }
    }

    func cancelQRPairing() {
        guard qrPairing != nil else { return }
        qrPairingTask?.cancel()
        finishQRPairing()
    }

    private func finishQRPairing() {
        qrPairingTask = nil
        qrPairing = nil
        busyMessage = nil
    }

    // MARK: - 截屏 / 录屏 / 投屏

    func screenshot() {
        run("正在截屏…") { adb in
            let data = try await adb.screenshot()
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ADBBarError.commandFailed("设备返回的截图不是有效图片。")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(png, forType: .png) else {
                throw ADBBarError.commandFailed("无法写入 Mac 剪贴板。")
            }
            return "截图已复制到剪贴板"
        }
    }

    func toggleRecording() {
        guard let recorder else { return }
        if recorder.isRecording {
            let format = recordingFormat
            run("正在停止并保存录屏…") { _ in
                let url = try await recorder.stopAndSave(format: format)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return "录屏已保存到下载文件夹"
            }
        } else {
            run("正在开始录屏…") { _ in
                try await recorder.start()
                return "录屏中…"
            }
        }
    }

    func toggleMirroring() {
        if mirror.isActive {
            mirror.stop()
        } else if let device = selectedDevice, let adb {
            mirror.start(device: device, adb: adb)
        }
    }

    func restartMirroring(_ device: ADBDevice) {
        guard let adb else { return }
        mirror.start(device: device, adb: adb)
    }

    func stopMirroring() {
        mirror.stop()
    }

    func openDownloads() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        NSWorkspace.shared.open(downloads)
    }

    // MARK: - 开发者选项 / 系统设置

    func setLayoutBounds(_ enabled: Bool) {
        run(enabled ? "正在开启布局边界…" : "正在关闭布局边界…") { adb in
            try await adb.setLayoutBounds(enabled: enabled)
            return enabled ? "布局边界已开启" : "布局边界已关闭"
        }
    }

    func setOverdraw(_ enabled: Bool) {
        run(enabled ? "正在开启过度绘制…" : "正在关闭过度绘制…") { adb in
            try await adb.setOverdraw(enabled: enabled)
            return enabled ? "过度绘制已开启" : "过度绘制已关闭"
        }
    }

    func setPointerLocation(_ enabled: Bool) {
        run(enabled ? "正在开启指针位置…" : "正在关闭指针位置…") { adb in
            try await adb.setPointerLocation(enabled: enabled)
            return enabled ? "指针位置已开启" : "指针位置已关闭"
        }
    }

    func setLanguage(_ locale: String, title: String) {
        run("正在切换手机语言…") { adb in
            try await adb.setLanguage(locale)
            return "手机语言已切换为 \(title)"
        }
    }

    func setFontScale(_ scale: Double) {
        run("正在调整字体大小…") { adb in
            try await adb.setFontScale(scale)
            return "字体大小已设置为 \(Int(scale * 100))%"
        }
    }

    func setDarkMode(_ mode: String) {
        run("正在切换深色模式…") { adb in
            try await adb.setDarkMode(mode)
            return "深色模式已切换"
        }
    }

    // MARK: - 当前应用

    func refreshForegroundApp() {
        run("正在识别前台应用…") { [weak self] adb in
            let packageName = try await adb.foregroundPackage()
            self?.foregroundPackage = packageName
            return packageName.map { "已识别前台应用：\($0)" } ?? "未识别到前台应用"
        }
    }

    func launchApp(_ packageName: String) {
        run("正在启动 \(packageName)…") { adb in
            try await adb.launchApp(packageName: packageName)
            return "应用已启动"
        }
    }

    func forceStopApp(_ packageName: String) {
        run("正在停止 \(packageName)…") { adb in
            try await adb.forceStopApp(packageName: packageName)
            return "应用已停止"
        }
    }

    func clearAppData(_ packageName: String) {
        run("正在清除 \(packageName) 的数据…") { adb in
            try await adb.clearAppData(packageName: packageName)
            return "应用数据已清除"
        }
    }

    func uninstallApp(_ packageName: String) {
        run("正在卸载 \(packageName)…") { adb in
            try await adb.uninstallApp(packageName: packageName)
            return "应用已卸载"
        }
    }

    // MARK: - 安装

    static let packageExtensions: Set<String> = ["apk", "hap", "hsp", "app"]

    func install(_ url: URL) {
        let isHarmonyPackage = ["hap", "hsp", "app"].contains(url.pathExtension.lowercased())
        run("正在安装 \(url.lastPathComponent)…") { adb in
            let package = try await adb.installPackage(at: url)
            return package.map { "已安装并启动 \($0)" }
                ?? (isHarmonyPackage ? "鸿蒙应用已安装" : "APK 已安装（未能识别启动包名）")
        }
    }

    // MARK: - 工具函数

    func copy(_ text: String, message: String) {
        if Pasteboard.copy(text) {
            toastMessage = message
        } else {
            errorMessage = "无法写入 Mac 剪贴板。"
        }
    }

    private func randomToken(length: Int) -> String {
        let characters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in characters.randomElement(using: &generator) })
    }

    private func qrCodeImage(for payload: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = floor(240 / output.extent.width)
        let scaledOutput = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaledOutput)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
