import SwiftUI
import UniformTypeIdentifiers

struct DevicesView: View {
    @EnvironmentObject private var controller: DeviceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var isImportingPackage = false
    @State private var isInspectingNetwork = false

    var body: some View {
        Group {
            if let setupError = controller.setupError {
                ContentUnavailableView {
                    Label("未找到 adb 或 hdc", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(setupError + "\n安装 Android Platform-Tools（brew install android-platform-tools）或 HarmonyOS SDK 后重新启动 HTools。")
                }
            } else {
                content
            }
        }
        .navigationTitle("手机调试")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await controller.refreshDevices(includeDetails: true) }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .help("刷新设备 (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(controller.isBusy)
            }
        }
        .toast($controller.toastMessage)
        .alert("操作失败", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { controller.qrPairing }, set: { if $0 == nil { controller.cancelQRPairing() } })) { pairing in
            QRPairingSheet(image: pairing.image) { controller.cancelQRPairing() }
        }
        .sheet(isPresented: $isInspectingNetwork) {
            if let device, let adb = controller.adb {
                StethoView(device: device, adb: adb, preferredProcess: controller.foregroundPackage)
            }
        }
        .fileImporter(
            isPresented: $isImportingPackage,
            allowedContentTypes: DeviceController.packageExtensions.compactMap { UTType(filenameExtension: $0) } + [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                install(url)
            }
        }
        .onAppear { controller.startPolling(interval: DeviceController.foregroundPollInterval) }
        .onDisappear { controller.startPolling(interval: DeviceController.backgroundPollInterval) }
    }

    private var subtitle: String {
        if let busy = controller.busyMessage { return busy }
        guard controller.hasLoaded else { return "正在读取设备…" }
        return controller.connectedCount == 0 ? "未连接设备" : "已连接 \(controller.connectedCount) 台设备"
    }

    private var device: ADBDevice? { controller.selectedDevice }
    private var isADB: Bool { device?.bridge == .adb }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            if controller.mirror.isActive {
                MirrorPane(mirror: controller.mirror)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            cards
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: controller.mirror.isActive)
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { DeviceController.packageExtensions.contains($0.pathExtension.lowercased()) }) else {
                return false
            }
            install(url)
            return true
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy) {
                isDropTargeted = targeted
            }
        }
    }

    private var cards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                deviceHeader
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    if device != nil {
                        quickActions
                        currentAppCard
                        if isADB {
                            networkCard
                            developerCard
                            displayCard
                        }
                        infoCard
                    }
                    connectionCard
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: device?.identifier)
        }
    }

    private func install(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        controller.install(url)
        if accessing {
            // 安装命令在后台读取文件，稍后再释放访问权限。
            Task {
                try? await Task.sleep(for: .seconds(120))
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: - 设备选择

    private var deviceHeader: some View {
        Card(padding: 16) {
            HStack(spacing: 14) {
                IconTile(
                    systemImage: device?.isWireless == true ? "wifi" : "cable.connector",
                    tint: device?.bridge == .hdc ? .red : .green,
                    size: 44,
                    isActive: device != nil
                )
                VStack(alignment: .leading, spacing: 3) {
                    if let device {
                        Text(device.model?.replacingOccurrences(of: "_", with: " ") ?? device.serial)
                            .font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            PlatformBadge(bridge: device.bridge)
                            Text(device.serial)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(controller.hasLoaded ? "未连接设备" : "正在读取设备…")
                            .font(.title2.weight(.semibold))
                        Text("用数据线连接手机并允许 USB 调试，或在下方通过 Wi-Fi 连接")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let busy = controller.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                }
                if controller.devices.count > 1 || (controller.devices.count == 1 && device == nil) {
                    Menu {
                        ForEach(controller.devices, id: \.identifier) { item in
                            Button {
                                controller.select(item)
                            } label: {
                                if item.identifier == device?.identifier {
                                    Label(item.displayName, systemImage: "checkmark")
                                } else {
                                    Text(item.state == .device ? item.displayName : "\(item.displayName)（\(item.state.rawValue)）")
                                }
                            }
                            .disabled(item.state != .device)
                        }
                    } label: {
                        Label("切换设备", systemImage: "arrow.left.arrow.right")
                    }
                    .fixedSize()
                    .disabled(controller.isBusy)
                }
            }
        }
    }

    // MARK: - 快捷操作

    private var quickActions: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("快捷操作", systemImage: "bolt.fill")
                HStack(spacing: 10) {
                    ActionTile(title: "截屏", subtitle: "复制到剪贴板", systemImage: "camera.fill", tint: .blue) {
                        controller.screenshot()
                    }
                    ActionTile(
                        title: controller.isRecording ? "停止录屏" : "录屏",
                        subtitle: controller.isRecording ? "保存到下载" : (isADB ? controller.recordingFormat.rawValue : "仅 Android"),
                        systemImage: controller.isRecording ? "stop.fill" : "record.circle",
                        tint: .red,
                        isHighlighted: controller.isRecording
                    ) {
                        controller.toggleRecording()
                    }
                    .disabled(!isADB && !controller.isRecording)
                    ActionTile(
                        title: controller.mirror.isActive ? "停止投屏" : "投屏",
                        subtitle: controller.mirror.isActive ? "关闭预览" : (device?.bridge == .hdc ? "只读预览" : "可操作"),
                        systemImage: controller.mirror.isActive ? "rectangle.badge.xmark" : "rectangle.on.rectangle",
                        tint: .purple,
                        isHighlighted: controller.mirror.isActive
                    ) {
                        controller.toggleMirroring()
                    }
                    ActionTile(
                        title: "安装",
                        subtitle: device?.bridge == .hdc ? "HAP / APP" : "APK",
                        systemImage: "square.and.arrow.down.fill",
                        tint: .green
                    ) {
                        isImportingPackage = true
                    }
                }
                .disabled(controller.isBusy && !controller.isRecording)

                HStack {
                    Picker("录屏格式", selection: $controller.recordingFormat) {
                        ForEach(RecordingFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!isADB || controller.isRecording)
                    Spacer()
                    Button("打开下载文件夹") { controller.openDownloads() }
                        .buttonStyle(.link)
                }
                Text("也可以把安装包直接拖进这个窗口安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var networkCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("网络抓包", systemImage: "network")
                Text("查看已集成 Stetho 的应用发出的 HTTP / HTTPS 请求、请求头和响应正文。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Label("USB / 无线 ADB", systemImage: "cable.connector")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开 Stetho 抓包") { isInspectingNetwork = true }
                        .disabled(device?.state != .device)
                }
            }
        }
    }

    // MARK: - 当前应用

    private var currentAppCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("前台应用", systemImage: "app.badge") {
                    Button {
                        controller.refreshForegroundApp()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新识别前台应用")
                    .disabled(controller.isBusy)
                }
                if let package = controller.foregroundPackage {
                    HStack {
                        Text(package)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            controller.copy(package, message: "包名已复制")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制包名")
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack(spacing: 8) {
                        Button("启动") { controller.launchApp(package) }
                        Button("强制停止") { controller.forceStopApp(package) }
                        Spacer()
                        DestructiveButton(
                            title: "清除数据…",
                            confirmTitle: "清除应用数据？",
                            message: "将永久删除 \(package) 的账号、设置和本地数据，但不会卸载应用。",
                            confirmButton: "清除数据"
                        ) { controller.clearAppData(package) }
                        DestructiveButton(
                            title: "卸载…",
                            confirmTitle: "卸载应用？",
                            message: "将从手机卸载 \(package)，并删除它的应用数据。",
                            confirmButton: "卸载"
                        ) { controller.uninstallApp(package) }
                    }
                    .disabled(controller.isBusy)
                } else {
                    Text("未识别到前台应用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        }
    }

    // MARK: - 开发者选项 / 显示

    private var developerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("开发者选项", systemImage: "hammer.fill")
                SettingRow("布局边界") { Toggle("布局边界", isOn: Binding(get: { controller.developerState.layoutBounds }, set: { controller.setLayoutBounds($0) })).labelsHidden() }
                Divider()
                SettingRow("过度绘制") { Toggle("过度绘制", isOn: Binding(get: { controller.developerState.overdraw }, set: { controller.setOverdraw($0) })).labelsHidden() }
                Divider()
                SettingRow("指针位置") { Toggle("指针位置", isOn: Binding(get: { controller.developerState.pointerLocation }, set: { controller.setPointerLocation($0) })).labelsHidden() }
            }
            .toggleStyle(.switch)
            .disabled(controller.isBusy)
        }
    }

    private var displayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("显示与语言", systemImage: "textformat.size")
                SettingRow("手机语言") {
                    Menu("选择…") {
                        ForEach([("English (US)", "en-US"), ("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("日本語", "ja-JP")], id: \.1) { title, locale in
                            Button(title) { controller.setLanguage(locale, title: title) }
                        }
                    }
                    .fixedSize()
                }
                Divider()
                SettingRow("字体大小") {
                    Menu("选择…") {
                        ForEach([("标准 · 100%", 1.0), ("较大 · 130%", 1.3), ("大 · 150%", 1.5), ("超大 · 200%", 2.0)], id: \.1) { title, scale in
                            Button(title) { controller.setFontScale(scale) }
                        }
                    }
                    .fixedSize()
                }
                Divider()
                SettingRow("深色模式") {
                    Menu("选择…") {
                        Button("浅色") { controller.setDarkMode("no") }
                        Button("深色") { controller.setDarkMode("yes") }
                        Button("跟随系统") { controller.setDarkMode("auto") }
                    }
                    .fixedSize()
                }
            }
            .disabled(controller.isBusy)
        }
    }

    // MARK: - 设备信息

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("设备信息", systemImage: "info.circle") {
                    if let info = controller.deviceInfo {
                        Button {
                            controller.copy(info.formattedText, message: "设备信息已复制")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制全部信息")
                    }
                }
                if let info = controller.deviceInfo {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        infoRow("设备", "\(info.manufacturer) \(info.model)")
                        infoRow("系统", "\(info.bridge.platformName) \(info.systemVersion)（API \(info.apiLevel)）")
                        infoRow("分辨率", info.resolution)
                        infoRow("电量", info.battery)
                        infoRow("存储", info.storage)
                        infoRow("IP 地址", info.ipAddress)
                    }
                } else if controller.isLoadingInfo {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    Button("读取设备信息") {
                        Task { await controller.loadDeviceInfo() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

    // MARK: - 无线连接

    private var connectionCard: some View {
        ConnectionCard()
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay {
                Label("松开以安装到 \(device?.displayName ?? "设备")", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct ConnectionCard: View {
    @EnvironmentObject private var controller: DeviceController
    @State private var address = ""
    @State private var isPairingWithCode = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("无线连接", systemImage: "wifi")

                if let device = controller.selectedDevice, !device.isWireless {
                    Button {
                        controller.enableWireless()
                    } label: {
                        Label("一键切换到 Wi-Fi \(device.bridge.displayName)", systemImage: "wifi.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Text("需要手机当前通过 USB 连接，且与 Mac 位于同一局域网。成功后可拔掉数据线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                }

                HStack {
                    TextField("IP 地址，例如 192.168.1.100:5555", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectDefault)
                    if controller.hasADB {
                        Button("连接 ADB") { controller.connect(address: address) }
                            .disabled(address.isEmpty)
                    }
                    if controller.hasHDC {
                        Button("连接 HDC") { controller.connectHDC(address: address) }
                            .disabled(address.isEmpty)
                    }
                }

                let recents = [
                    controller.lastWirelessAddress.map { ("ADB", $0) },
                    controller.lastHDCAddress.map { ("HDC", $0) }
                ].compactMap { $0 }
                if !recents.isEmpty {
                    HStack(spacing: 8) {
                        Text("最近")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(recents, id: \.1) { bridge, recent in
                            Button {
                                bridge == "ADB" ? controller.connect(address: recent) : controller.connectHDC(address: recent)
                            } label: {
                                Label("\(bridge) · \(recent)", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                if controller.hasADB {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ADB 无线配对")
                                .font(.callout.weight(.medium))
                            Text("Android 11+ · 手机“开发者选项 > 无线调试”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("二维码配对") { controller.startQRPairing() }
                        Button("配对码…") { isPairingWithCode = true }
                    }
                }
            }
            .disabled(controller.isBusy)
        }
        .sheet(isPresented: $isPairingWithCode) {
            PairingCodeSheet { address, code in
                controller.pair(address: address, code: code)
            }
        }
    }

    private func connectDefault() {
        guard !address.isEmpty else { return }
        if controller.hasADB {
            controller.connect(address: address)
        } else {
            controller.connectHDC(address: address)
        }
    }
}

// MARK: - 组件

/// 内嵌投屏面板：画面、触控（Android）与导航键。
private struct MirrorPane: View {
    @ObservedObject var mirror: DeviceMirror
    @EnvironmentObject private var controller: DeviceController
    @State private var dragStart: Date?

    /// 手机未返回分辨率前先用常见的竖屏比例占位，避免画面出现时布局跳动。
    private var aspectRatio: CGFloat {
        guard let size = mirror.deviceSize, size.height > 0 else { return 9.0 / 19.5 }
        return size.width / size.height
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("实时投屏", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    mirror.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.9))
                .help("关闭投屏")
            }

            screen
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if mirror.isControllable {
                HStack(spacing: 10) {
                    navButton("chevron.backward", "返回", key: 4)
                    navButton("circle", "主页", key: 3)
                    navButton("square.on.square", "最近任务", key: 187)
                }
                Text("点击 / 拖动画面即可操作手机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("鸿蒙投屏通过 HDC 连续截图，只能查看画面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330)
        .frame(maxHeight: .infinity)
    }

    private var screen: some View {
        ZStack {
            Color.black
            if mirror.device?.bridge == .hdc {
                if let image = mirror.hdcImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                MirrorSurface(layer: mirror.displayLayer)
            }

            switch mirror.phase {
            case .connecting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("正在连接手机画面…")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                    if let device = mirror.device ?? controller.selectedDevice {
                        Button("重试") { controller.restartMirroring(device) }
                            .controlSize(.small)
                    }
                }
                .padding(16)
            case .idle, .streaming:
                EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .overlay {
            if mirror.isControllable, mirror.phase == .streaming {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if dragStart == nil { dragStart = Date() }
                                }
                                .onEnded { value in
                                    let duration = Date().timeIntervalSince(dragStart ?? Date())
                                    dragStart = nil
                                    let size = proxy.size
                                    guard size.width > 0, size.height > 0 else { return }
                                    let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                                    let end = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                                    if hypot(value.translation.width, value.translation.height) < 6 {
                                        mirror.tap(at: start)
                                    } else {
                                        mirror.swipe(from: start, to: end, duration: duration)
                                    }
                                }
                        )
                }
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func navButton(_ systemImage: String, _ title: String, key: Int) -> some View {
        Button {
            mirror.pressKey(key)
        } label: {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .help(title)
        .disabled(mirror.phase != .streaming)
    }
}

/// 设置行：标签靠左、控件靠右，与系统设置一致。
private struct PlatformBadge: View {
    let bridge: DeviceBridge

    var body: some View {
        Text("\(bridge.platformName) · \(bridge.displayName)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(bridge == .hdc ? Color.red : Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((bridge == .hdc ? Color.red : Color.green).opacity(0.12), in: Capsule())
    }
}

/// 需要二次确认的破坏性操作。
private struct DestructiveButton: View {
    let title: String
    let confirmTitle: String
    let message: String
    let confirmButton: String
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button(title, role: .destructive) { isConfirming = true }
            .confirmationDialog(confirmTitle, isPresented: $isConfirming) {
                Button(confirmButton, role: .destructive, action: action)
            } message: {
                Text(message)
            }
    }
}

private struct QRPairingSheet: View {
    let image: NSImage
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("二维码无线配对")
                .font(.title2.weight(.semibold))
            Text("在手机上打开“开发者选项 > 无线调试”，选择“使用二维码配对设备”，然后扫描下方二维码。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Image(nsImage: image)
                .interpolation(.none)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("等待手机扫描…（最多 2 分钟）")
                    .foregroundStyle(.secondary)
            }
            Button("取消", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 400)
    }
}

private struct PairingCodeSheet: View {
    let onPair: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配对码配对")
                .font(.title2.weight(.semibold))
            Text("在手机“无线调试”页面选择“使用配对码配对设备”，然后填写显示的信息。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("IP 地址和端口", text: $address, prompt: Text("192.168.1.100:37123"))
                TextField("配对码", text: $code, prompt: Text("6 位数字"))
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("配对") {
                    onPair(address, code)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || code.count != 6)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
