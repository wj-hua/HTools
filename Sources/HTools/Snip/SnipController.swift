import AppKit
import Carbon.HIToolbox
import Combine

/// 截图 / 贴图 / 截图翻译三个全局快捷键的预设。
enum SnipHotKeyPreset: String, CaseIterable, Identifiable {
    /// 与 Snipaste 相同；MacBook 键盘上需要按住 fn。
    case functionKeys
    case controlOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .functionKeys: return "F1 / F3 / F4"
        case .controlOption: return "⌃⌥A / ⌃⌥P / ⌃⌥T"
        }
    }

    var captureLabel: String { self == .functionKeys ? "F1" : "⌃⌥A" }
    var pinLabel: String { self == .functionKeys ? "F3" : "⌃⌥P" }
    var translateLabel: String { self == .functionKeys ? "F4" : "⌃⌥T" }

    fileprivate var capture: (keyCode: Int, modifiers: Int) {
        self == .functionKeys ? (kVK_F1, 0) : (kVK_ANSI_A, controlKey | optionKey)
    }

    fileprivate var pin: (keyCode: Int, modifiers: Int) {
        self == .functionKeys ? (kVK_F3, 0) : (kVK_ANSI_P, controlKey | optionKey)
    }

    fileprivate var translate: (keyCode: Int, modifiers: Int) {
        self == .functionKeys ? (kVK_F4, 0) : (kVK_ANSI_T, controlKey | optionKey)
    }
}

@MainActor
final class SnipController: ObservableObject {
    @Published var hotKeyPreset: SnipHotKeyPreset {
        didSet {
            UserDefaults.standard.set(hotKeyPreset.rawValue, forKey: "snip.hotKeyPreset")
            registerHotKeys()
        }
    }
    @Published var detectsElements: Bool {
        didSet { UserDefaults.standard.set(detectsElements, forKey: "snip.detectsElements") }
    }
    @Published private(set) var hotKeysRegistered = true
    @Published private(set) var hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var pins: [PinWindowController] = []
    @Published private(set) var pinsHidden = false
    @Published private(set) var isCapturing = false
    @Published var toastMessage: String?
    @Published var errorMessage: String?

    private var captureHotKey: GlobalHotKeyController?
    private var pinHotKey: GlobalHotKeyController?
    private var translateHotKey: GlobalHotKeyController?
    private var capture: CaptureController?
    /// 截图前的前台 App，存储对话框结束后把焦点还给它。
    private var previousApplication: NSRunningApplication?
    /// 从 HTools 里发起时先藏起了自己，取消截图后要恢复。
    private var hidAppForCapture = false
    /// 选区交给翻译页做 OCR 和翻译。
    var onTranslate: ((CGImage) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        hotKeyPreset = defaults.string(forKey: "snip.hotKeyPreset").flatMap(SnipHotKeyPreset.init(rawValue:)) ?? .functionKeys
        detectsElements = defaults.object(forKey: "snip.detectsElements") as? Bool ?? true
    }

    func start() {
        registerHotKeys()
    }

    private func registerHotKeys() {
        captureHotKey?.unregister()
        pinHotKey?.unregister()
        translateHotKey?.unregister()

        let capture = GlobalHotKeyController(
            keyCode: UInt32(hotKeyPreset.capture.keyCode), modifiers: UInt32(hotKeyPreset.capture.modifiers),
            id: 2, name: "Snip capture"
        )
        capture.onHotKey = { [weak self] in self?.startCapture() }
        let pin = GlobalHotKeyController(
            keyCode: UInt32(hotKeyPreset.pin.keyCode), modifiers: UInt32(hotKeyPreset.pin.modifiers),
            id: 3, name: "Snip pin"
        )
        pin.onHotKey = { [weak self] in self?.pinClipboard() }

        let translate = GlobalHotKeyController(
            keyCode: UInt32(hotKeyPreset.translate.keyCode), modifiers: UInt32(hotKeyPreset.translate.modifiers),
            id: 4, name: "Snip translate"
        )
        translate.onHotKey = { [weak self] in self?.startCapture(primaryAction: .translate) }

        let captureOK = capture.register()
        let pinOK = pin.register()
        let translateOK = translate.register()
        hotKeysRegistered = captureOK && pinOK && translateOK
        captureHotKey = capture
        pinHotKey = pin
        translateHotKey = translate
    }

    func refreshPermission() {
        hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    }

    /// 第一次调用会弹出系统授权框；之后系统不再弹，只能去系统设置里打开。
    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            openScreenCaptureSettings()
        }
        refreshPermission()
    }

    func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 截图

    /// 从 HTools 窗口或菜单里发起：先把自己藏起来，等窗口真正消失后再截，画面里才不会有 HTools。
    func captureHidingApp(primaryAction: CaptureAction = .copy) {
        guard capture == nil, !isCapturing else { return }
        NSApp.hide(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            startCapture(primaryAction: primaryAction)
            // 没有权限等原因没能开始截图时，马上把窗口还回来。
            hidAppForCapture = isCapturing
            if !isCapturing { NSApp.unhide(nil) }
        }
    }

    /// `primaryAction` 是 ↩ / 双击选区时执行的操作。
    func startCapture(primaryAction: CaptureAction = .copy) {
        guard capture == nil, !isCapturing else { return }
        refreshPermission()
        guard hasScreenCapturePermission else {
            requestPermission()
            return
        }

        isCapturing = true
        previousApplication = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                guard !shots.isEmpty else { throw CocoaError(.featureUnsupported) }
                let detector = WindowDetector(usesAccessibility: detectsElements && AXIsProcessTrusted())
                let controller = CaptureController(shots: shots, detector: detector)
                controller.primaryAction = primaryAction
                controller.onFinish = { [weak self] action, output in
                    self?.finishCapture(action, output: output)
                }
                capture = controller
                controller.present()
            } catch {
                isCapturing = false
                if hidAppForCapture { NSApp.unhide(nil) }
                hidAppForCapture = false
                errorMessage = "截图失败：\(error.localizedDescription)"
                NSSound.beep()
            }
        }
    }

    private func finishCapture(_ action: CaptureAction, output: CaptureOutput?) {
        // 推迟到下一轮再释放：这次回调还在截图窗口的事件处理里。
        let finished = capture
        DispatchQueue.main.async { _ = finished }
        capture = nil
        isCapturing = false
        if hidAppForCapture, action == .cancel { NSApp.unhide(nil) }
        hidAppForCapture = false

        guard let output else { return }
        switch action {
        case .copy:
            SnipImage.copyToPasteboard(output.image, pixelsPerPoint: output.pixelsPerPoint)
            toastMessage = "截图已复制"
        case .pin:
            addPin(image: output.image, frame: output.frame, pixelsPerPoint: output.pixelsPerPoint)
        case .save:
            save(output.image, pixelsPerPoint: output.pixelsPerPoint)
        case .translate:
            onTranslate?(output.image)
        case .cancel:
            break
        }
    }

    // MARK: - 贴图

    /// 截图中按贴图键：把选区贴到原位；否则把剪贴板里的图片或文字贴到鼠标处。
    func pinClipboard() {
        if let capture {
            capture.finish(.pin)
            return
        }

        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           image.size.width > 0 {
            pinAtMouse(cgImage, pixelsPerPoint: CGFloat(cgImage.width) / image.size.width)
        } else if let text = pasteboard.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let scale = screenUnderMouse?.backingScaleFactor ?? 2
            guard let image = Self.renderText(text, scale: scale) else { return }
            pinAtMouse(image, pixelsPerPoint: scale)
        } else {
            NSSound.beep()
            toastMessage = "剪贴板里没有图片或文字"
        }
    }

    private var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private func pinAtMouse(_ image: CGImage, pixelsPerPoint: CGFloat) {
        let mouse = NSEvent.mouseLocation
        var size = CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)
        // 大图先缩到屏幕可见区域的八成以内，之后仍可滚轮放大。
        if let visible = screenUnderMouse?.visibleFrame {
            let fit = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
            size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        var frame = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        if let visible = screenUnderMouse?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        let pin = addPin(image: image, frame: frame, pixelsPerPoint: pixelsPerPoint)
        let fitZoom = size.width / (CGFloat(image.width) / pixelsPerPoint)
        if fitZoom < 1 { pin.setZoom(fitZoom) }
    }

    @discardableResult
    private func addPin(image: CGImage, frame: CGRect, pixelsPerPoint: CGFloat) -> PinWindowController {
        let pin = PinWindowController(image: image, frame: frame, pixelsPerPoint: pixelsPerPoint)
        pin.onClose = { [weak self] pin in
            self?.pins.removeAll { $0 === pin }
        }
        pin.onSave = { [weak self] pin in
            self?.previousApplication = NSWorkspace.shared.frontmostApplication
            self?.save(pin.image, pixelsPerPoint: pin.pixelsPerPoint)
        }
        pin.onCloseAll = { [weak self] in self?.closeAllPins() }
        pins.append(pin)
        if pinsHidden { setPinsHidden(false) }
        pin.show()
        return pin
    }

    func setPinsHidden(_ hidden: Bool) {
        pinsHidden = hidden
        pins.forEach { hidden ? $0.hide() : $0.show() }
    }

    func closeAllPins() {
        let all = pins
        pins.removeAll()
        all.forEach { $0.close() }
        pinsHidden = false
    }

    func focus(_ pin: PinWindowController) {
        if pinsHidden { setPinsHidden(false) }
        pin.show()
    }

    /// 文字贴图：按系统文本样式排版，最宽 480pt 自动换行。
    private static func renderText(_ text: String, scale: CGFloat) -> CGImage? {
        let padding: CGFloat = 12
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor,
        ])
        let bounds = attributed.boundingRect(
            with: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let size = CGSize(width: ceil(bounds.width) + padding * 2, height: ceil(bounds.height) + padding * 2)
        return SnipImage.render(size: size, scale: scale) { _ in
            NSColor.textBackgroundColor.setFill()
            CGRect(origin: .zero, size: size).fill()
            attributed.draw(
                with: CGRect(x: padding, y: padding, width: ceil(bounds.width), height: ceil(bounds.height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
    }

    // MARK: - 保存

    private func save(_ image: CGImage, pixelsPerPoint: CGFloat) {
        let restoring = previousApplication
        NSApp.activate()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = SnipImage.defaultFileName()
        panel.canCreateDirectories = true
        // 贴图在 floating 层，存储框要在它们之上。
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            defer {
                if let restoring, restoring.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    restoring.activate()
                }
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let data = SnipImage.pngData(image, pixelsPerPoint: pixelsPerPoint) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                self?.toastMessage = "已保存到 \(url.lastPathComponent)"
            } catch {
                self?.errorMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
