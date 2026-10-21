import AppKit
import Carbon.HIToolbox
import SwiftUI

final class PinPanel: NSPanel {
    var onKeyChange: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }
}

/// 一张钉在屏幕上的图：置顶、可拖动、滚轮缩放、⌥滚轮调透明度、旋转、复制保存。
@MainActor
final class PinWindowController: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var image: CGImage
    let pixelsPerPoint: CGFloat
    private(set) var zoom: CGFloat = 1
    let panel: PinPanel
    private let contentView: PinContentView

    var onClose: ((PinWindowController) -> Void)?
    var onSave: ((PinWindowController) -> Void)?
    var onCloseAll: (() -> Void)?

    /// 100% 时的点尺寸。
    private var naturalSize: CGSize {
        CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)
    }

    init(image: CGImage, frame: CGRect, pixelsPerPoint: CGFloat) {
        self.image = image
        self.pixelsPerPoint = pixelsPerPoint
        panel = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = PinContentView(frame: CGRect(origin: .zero, size: frame.size))
        super.init()

        // 点贴图不激活 HTools，不会把主窗口带到前台。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.setFrame(frame, display: false)

        contentView.controller = self
        contentView.setImage(image)
        panel.contentView = contentView
        panel.onKeyChange = { [weak self] isKey in self?.contentView.isFocused = isKey }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        panel.orderOut(nil)
        onClose?(self)
    }

    // MARK: - 缩放与透明度

    /// 以 `anchor`（屏幕坐标）为不动点缩放，鼠标指着的地方缩放后仍在鼠标下。
    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        let natural = naturalSize
        // 最小保证短边 24pt 还能抓得住，最大 8 倍。
        let minimum = min(1, 24 / max(1, min(natural.width, natural.height)))
        let newZoom = min(max(value, minimum), 8)
        let old = panel.frame
        let anchor = anchor ?? CGPoint(x: old.midX, y: old.midY)
        let size = CGSize(width: (natural.width * newZoom).rounded(), height: (natural.height * newZoom).rounded())
        let ratioX = (anchor.x - old.minX) / max(1, old.width)
        let ratioY = (anchor.y - old.minY) / max(1, old.height)
        let origin = CGPoint(x: (anchor.x - ratioX * size.width).rounded(), y: (anchor.y - ratioY * size.height).rounded())

        zoom = newZoom
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        contentView.showHUD("\(Int((newZoom * 100).rounded()))%")
    }

    func setOpacity(_ value: CGFloat) {
        let opacity = min(max(value, 0.1), 1)
        panel.alphaValue = opacity
        contentView.showHUD("不透明度 \(Int((opacity * 100).rounded()))%")
    }

    // MARK: - 菜单动作

    @objc func copyImage() {
        SnipImage.copyToPasteboard(image, pixelsPerPoint: pixelsPerPoint)
        contentView.showHUD("已复制")
    }

    @objc func saveImage() {
        onSave?(self)
    }

    @objc func resetZoom() {
        setZoom(1)
    }

    @objc func rotateLeft() {
        rotate(clockwise: false)
    }

    @objc func rotateRight() {
        rotate(clockwise: true)
    }

    @objc func setOpacityFromMenu(_ sender: NSMenuItem) {
        setOpacity(CGFloat(sender.tag) / 100)
    }

    @objc func closeFromMenu() {
        close()
    }

    @objc func closeAllFromMenu() {
        onCloseAll?()
    }

    private func rotate(clockwise: Bool) {
        guard let rotated = SnipImage.rotated(image, clockwise: clockwise) else { return }
        image = rotated
        contentView.setImage(rotated)
        let old = panel.frame
        let size = CGSize(width: old.height, height: old.width)
        panel.setFrame(CGRect(x: (old.midX - size.width / 2).rounded(), y: (old.midY - size.height / 2).rounded(), width: size.width, height: size.height), display: true)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }

        add("复制", #selector(copyImage), key: "c", modifiers: .command)
        add("存储为…", #selector(saveImage), key: "s", modifiers: .command)
        menu.addItem(.separator())
        add("实际大小", #selector(resetZoom), key: "0")
        add("向左旋转", #selector(rotateLeft), key: "1")
        add("向右旋转", #selector(rotateRight), key: "2")

        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacityFromMenu(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = Int((panel.alphaValue * 100).rounded()) == percent ? .on : .off
            opacityMenu.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        add("关闭", #selector(closeFromMenu), key: "w", modifiers: .command)
        add("关闭所有贴图", #selector(closeAllFromMenu))
        return menu
    }
}

/// 贴图内容：图像交给图层由 GPU 缩放，事件转给控制器。
final class PinContentView: NSView {
    weak var controller: PinWindowController?
    private let hud = NSHostingView(rootView: PinHUD(text: ""))
    private var hudTask: Task<Void, Never>?

    var isFocused = false {
        didSet { updateBorder() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.borderWidth = 1

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.alphaValue = 0
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: CGImage) {
        layer?.contents = image
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    /// 获得焦点时描一圈强调色，一眼看出键盘操作作用在哪张贴图上。
    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    func showHUD(_ text: String) {
        hud.rootView = PinHUD(text: text)
        hudTask?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hud.animator().alphaValue = 1
        }
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.hud.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.close()
            return
        }
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller, event.momentumPhase.isEmpty else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        guard delta != 0 else { return }

        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
            controller.setOpacity(controller.panel.alphaValue + delta * 0.05)
        } else {
            controller.setZoom(controller.zoom * pow(1.1, delta), anchor: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let controller else { return }
        controller.setZoom(controller.zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == UInt16(kVK_Escape) {
            controller.close()
        } else if modifiers == .command {
            switch key {
            case "c": controller.copyImage()
            case "s": controller.saveImage()
            case "w": controller.close()
            default: super.keyDown(with: event)
            }
        } else if modifiers.subtracting(.shift).isEmpty {
            switch key {
            case "1": controller.rotateLeft()
            case "2": controller.rotateRight()
            case "0": controller.resetZoom()
            case "=", "+": controller.setZoom(controller.zoom * 1.1)
            case "-": controller.setZoom(controller.zoom / 1.1)
            default: super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct PinHUD: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            .fixedSize()
    }
}
