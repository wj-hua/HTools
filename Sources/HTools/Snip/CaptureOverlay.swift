import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 截图完成后交给调用方的结果。
struct CaptureOutput {
    let image: CGImage
    /// 选区在全局 Cocoa 坐标中的位置，贴图会出现在原处。
    let frame: CGRect
    let pixelsPerPoint: CGFloat
}

/// 一次截图会话：每块屏幕一个全屏遮罩窗口，选区只能落在其中一块屏幕上。
@MainActor
final class CaptureController {
    let editor = CaptureEditor()
    let detector: WindowDetector
    var onFinish: ((CaptureAction, CaptureOutput?) -> Void)?
    /// ↩ 和双击选区执行的操作：普通截图是复制，截图翻译是翻译。
    var primaryAction: CaptureAction = .copy

    private var windows: [CaptureWindow] = []
    private var views: [CaptureOverlayView] = []
    /// 拥有选区的那块屏幕。
    private(set) weak var activeView: CaptureOverlayView?
    /// 放大镜里颜色的显示格式：十六进制或 RGB，按 ⇧ 切换。
    var showsRGB = false

    init(shots: [ScreenShot], detector: WindowDetector) {
        self.detector = detector
        for shot in shots {
            let window = CaptureWindow(frame: shot.frame)
            let view = CaptureOverlayView(shot: shot, controller: self)
            let container = NSView(frame: CGRect(origin: .zero, size: shot.frame.size))
            container.wantsLayer = true
            container.layer?.contents = shot.image
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            window.contentView = container
            windows.append(window)
            views.append(view)
        }

        editor.onChange = { [weak self] in self?.activeView?.needsDisplay = true }
        editor.onToolChange = { [weak self] in self?.activeView?.toolDidChange() }
    }

    var hasSelection: Bool { activeView?.selection != nil }

    func present() {
        let mouse = NSEvent.mouseLocation
        for (window, view) in zip(windows, views) {
            window.orderFrontRegardless()
            view.updateHover(atScreenPoint: mouse)
        }
        let keyIndex = windows.firstIndex { $0.frame.contains(mouse) } ?? 0
        if windows.indices.contains(keyIndex) {
            windows[keyIndex].makeKey()
            windows[keyIndex].makeFirstResponder(views[keyIndex])
        }
    }

    /// 某块屏幕开始框选：其他屏幕上的状态全部清掉。
    func activate(_ view: CaptureOverlayView) {
        guard activeView !== view else { return }
        activeView?.clearSelection()
        activeView = view
        editor.reset()
    }

    func resignActive(_ view: CaptureOverlayView) {
        if activeView === view { activeView = nil }
    }

    func redrawAll() {
        views.forEach { $0.needsDisplay = true }
    }

    func finish(_ action: CaptureAction) {
        activeView?.commitText()
        var output: CaptureOutput?
        if action != .cancel {
            guard let view = activeView, let rendered = view.renderSelection() else {
                NSSound.beep()
                return
            }
            output = rendered
        }

        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        onFinish?(action, output)
        onFinish = nil
    }
}

final class CaptureWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 不激活 HTools：否则主窗口会被带到前台，退出截图后也回不到原来的 App。
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 一块屏幕上的截图画布：自动识别窗口、拖拽框选、调整选区、标注、放大镜取色。
final class CaptureOverlayView: NSView, NSTextFieldDelegate {
    let shot: ScreenShot
    private unowned let controller: CaptureController
    private var editor: CaptureEditor { controller.editor }

    private(set) var selection: CGRect?
    private var mouse: CGPoint?
    private var candidates: [CGRect] = []
    private var candidateLevel = 0
    private var drag: Drag?
    private var draft: Annotation?
    private var textField: NSTextField?
    private var toolbar: PanelHostingView<CaptureToolbar>?
    private var trackingArea: NSTrackingArea?

    private enum Drag {
        /// 从空白处拖出新选区；`moved` 为假时松手等于点选识别到的区域。
        case creating(start: CGPoint, moved: Bool)
        case moving(start: CGPoint, original: CGRect)
        /// `edges` 的 x / y 分量取 -1（左/上）、0、1（右/下）。
        case resizing(edges: (x: Int, y: Int), original: CGRect)
        case drawing
    }

    private static let handleRadius: CGFloat = 4
    private static let dimColor = NSColor.black.withAlphaComponent(0.4)

    init(shot: ScreenShot, controller: CaptureController) {
        self.shot = shot
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: shot.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - 状态

    private var currentCandidate: CGRect? {
        candidates.isEmpty ? nil : candidates[min(candidateLevel, candidates.count - 1)]
    }

    /// 框选、调整选区和还没选的时候显示放大镜；标注和移动时不挡视线。
    private var showsMagnifier: Bool {
        guard mouse != nil else { return false }
        switch drag {
        case .creating, .resizing: return true
        case .moving, .drawing: return false
        case nil: return selection == nil && !controller.hasSelection
        }
    }

    func clearSelection() {
        commitText()
        selection = nil
        drag = nil
        draft = nil
        hideToolbar()
        needsDisplay = true
    }

    func toolDidChange() {
        commitText()
        layoutToolbar()
        updateCursor()
        needsDisplay = true
    }

    // MARK: - 鼠标

    func updateHover(atScreenPoint screenPoint: CGPoint) {
        guard shot.frame.contains(screenPoint) else {
            mouse = nil
            needsDisplay = true
            return
        }
        updateHover(at: CGPoint(x: screenPoint.x - shot.frame.minX, y: shot.frame.maxY - screenPoint.y))
    }

    private func updateHover(at point: CGPoint) {
        mouse = point
        if !controller.hasSelection, drag == nil {
            let found = controller.detector.candidates(at: shot.globalPoint(fromView: point))
                .map { shot.viewRect(fromGlobal: $0).intersection(bounds) }
                .filter { !$0.isEmpty }
            var unique: [CGRect] = []
            for rect in found + [bounds] where unique.last != rect { unique.append(rect) }
            if unique != candidates {
                candidates = unique
                candidateLevel = 0
            }
        }
        updateCursor()
        needsDisplay = true
    }

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: point(for: event))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: point(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // 还没选定时滚轮在“界面元素 → 窗口 → 整个屏幕”之间切换层级。
        guard selection == nil, drag == nil, candidates.count > 1, event.scrollingDeltaY != 0 else { return }
        if event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) < 3 { return }
        let step = event.scrollingDeltaY > 0 ? 1 : -1
        candidateLevel = min(max(candidateLevel + step, 0), candidates.count - 1)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = point(for: event).clamped(to: bounds)
        commitText()

        if let selection {
            if let tool = editor.tool {
                beginAnnotation(tool, at: point.clamped(to: selection))
                return
            }
            if event.clickCount == 2, selection.contains(point) {
                controller.finish(controller.primaryAction)
                return
            }
            if let edges = handle(at: point, in: selection) {
                drag = .resizing(edges: edges, original: selection)
            } else if selection.contains(point) {
                drag = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
            } else if editor.annotations.isEmpty {
                // 还没标注时，在选区外拖动就重新框选；已有标注则不丢弃。
                self.selection = nil
                drag = .creating(start: point, moved: false)
            } else {
                return
            }
            hideToolbar()
            needsDisplay = true
            return
        }

        // 另一块屏幕上已经有标注时不切走，避免误点丢掉标注。
        if controller.hasSelection, !editor.annotations.isEmpty { return }
        controller.activate(self)
        drag = .creating(start: point, moved: false)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = point(for: event).clamped(to: bounds)
        mouse = point

        switch drag {
        case let .creating(start, moved):
            guard moved || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            drag = .creating(start: start, moved: true)
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        case let .moving(start, original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            selection = moved
        case let .resizing(edges, original):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if edges.x < 0 { minX = point.x } else if edges.x > 0 { maxX = point.x }
            if edges.y < 0 { minY = point.y } else if edges.y > 0 { maxY = point.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        case .drawing:
            guard let selection else { return }
            updateDraft(to: point.clamped(to: selection), constrained: event.modifierFlags.contains(.shift))
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            updateCursor()
            needsDisplay = true
        }

        switch drag {
        case let .creating(_, moved):
            if !moved { selection = currentCandidate ?? bounds }
            if let selection, selection.width < 1 || selection.height < 1 { self.selection = nil }
        case .drawing:
            if let draft, draft.tool != .text { editor.add(draft) }
            draft = nil
        case .moving, .resizing, nil:
            break
        }

        if selection != nil { layoutToolbar() } else { controller.resignActive(self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键：有选区就回到重新选择，否则退出截图。
        if selection != nil {
            clearSelection()
            editor.reset()
            controller.resignActive(self)
            updateHover(at: point(for: event))
        } else {
            controller.finish(.cancel)
        }
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> (x: Int, y: Int)? {
        let tolerance: CGFloat = 6
        for y in -1...1 {
            for x in -1...1 where !(x == 0 && y == 0) {
                let handle = handlePoint(x: x, y: y, in: rect)
                if abs(point.x - handle.x) <= tolerance, abs(point.y - handle.y) <= tolerance { return (x, y) }
            }
        }
        // 也可以直接拖边。
        let nearLeft = abs(point.x - rect.minX) <= tolerance, nearRight = abs(point.x - rect.maxX) <= tolerance
        let nearTop = abs(point.y - rect.minY) <= tolerance, nearBottom = abs(point.y - rect.maxY) <= tolerance
        let withinX = point.x > rect.minX && point.x < rect.maxX, withinY = point.y > rect.minY && point.y < rect.maxY
        if withinY, nearLeft { return (-1, 0) }
        if withinY, nearRight { return (1, 0) }
        if withinX, nearTop { return (0, -1) }
        if withinX, nearBottom { return (0, 1) }
        return nil
    }

    private func handlePoint(x: Int, y: Int, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + CGFloat(x) * rect.width / 2, y: rect.midY + CGFloat(y) * rect.height / 2)
    }

    private func updateCursor() {
        guard let mouse else { return }
        if let toolbar, !toolbar.isHidden, toolbar.frame.contains(mouse) {
            NSCursor.arrow.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let tool = editor.tool {
            (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        } else if let edges = handle(at: mouse, in: selection) {
            NSCursor.frameResize(position: Self.resizePosition(edges), directions: .all).set()
        } else if selection.contains(mouse) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func resizePosition(_ edges: (x: Int, y: Int)) -> NSCursor.FrameResizePosition {
        switch (edges.x, edges.y) {
        case (-1, -1): return .topLeft
        case (1, -1): return .topRight
        case (-1, 1): return .bottomLeft
        case (1, 1): return .bottomRight
        case (-1, _): return .left
        case (1, _): return .right
        case (_, -1): return .top
        default: return .bottom
        }
    }

    // MARK: - 标注

    private func beginAnnotation(_ tool: CaptureTool, at point: CGPoint) {
        switch tool {
        case .text:
            beginText(at: point)
        case .number:
            editor.add(editor.makeAnnotation(.number, at: point))
        default:
            draft = editor.makeAnnotation(tool, at: point)
            drag = .drawing
        }
    }

    private func updateDraft(to point: CGPoint, constrained: Bool) {
        guard var draft, let start = draft.points.first else { return }
        switch draft.tool {
        case .pen, .marker:
            draft.points.append(point)
        case .rectangle, .ellipse, .mosaic:
            var end = point
            if constrained {
                // ⇧：正方形 / 正圆。
                let side = max(abs(point.x - start.x), abs(point.y - start.y))
                end = CGPoint(x: start.x + (point.x >= start.x ? side : -side), y: start.y + (point.y >= start.y ? side : -side))
            }
            draft.points = [start, end]
            if draft.tool == .mosaic {
                draft.mosaic = Annotation.pixelate(shot, rect: draft.boxRect, block: draft.mosaicBlock)
            }
        case .arrow:
            var end = point
            if constrained {
                // ⇧：吸附到 45° 的整数倍。
                let angle = (atan2(point.y - start.y, point.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(point.x - start.x, point.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            draft.points = [start, end]
        case .text, .number:
            break
        }
        self.draft = draft
    }

    private func beginText(at point: CGPoint) {
        let annotation = editor.makeAnnotation(.text, at: point)
        let field = NSTextField(string: "")
        field.font = annotation.font
        field.textColor = annotation.color
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldDidSubmit)
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        field.layer?.cornerRadius = 3

        let height = ceil(annotation.font.ascender - annotation.font.descender + annotation.font.leading) + 2
        field.frame = CGRect(x: point.x - 2, y: point.y - height / 2, width: 40, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        draft = annotation
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField, let selection else { return }
        let width = ceil(textField.attributedStringValue.size().width) + 12
        textField.frame.size.width = min(max(40, width), max(40, selection.maxX - textField.frame.minX))
    }

    @objc private func textFieldDidSubmit() {
        commitText()
        window?.makeFirstResponder(self)
    }

    /// 把正在编辑的文字落成一笔标注。
    func commitText() {
        guard let textField else { return }
        self.textField = nil
        if var draft, draft.tool == .text {
            draft.text = textField.stringValue
            // NSTextField 的文字左边有 2pt 内边距，落笔位置与编辑时对齐。
            draft.points = [CGPoint(x: textField.frame.minX + 2, y: textField.frame.minY + 1)]
            editor.add(draft)
        }
        draft = nil
        textField.removeFromSuperview()
        needsDisplay = true
    }

    // MARK: - 工具栏

    private func layoutToolbar() {
        guard let selection else { return hideToolbar() }
        let host: PanelHostingView<CaptureToolbar>
        if let toolbar {
            host = toolbar
        } else {
            host = PanelHostingView(rootView: CaptureToolbar(editor: editor, primaryAction: controller.primaryAction) { [weak controller] action in
                controller?.finish(action)
            })
            addSubview(host)
            toolbar = host
        }
        host.isHidden = false
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let gap: CGFloat = 8

        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + gap)
        if origin.y + size.height > bounds.maxY - gap {
            // 下方放不下就放到上方，再不行放在选区内的右下角。
            origin.y = selection.minY - gap - size.height
            if origin.y < bounds.minY + gap { origin.y = selection.maxY - gap - size.height }
        }
        origin.x = min(max(origin.x, gap), bounds.maxX - size.width - gap)
        origin.y = min(max(origin.y, gap), bounds.maxY - size.height - gap)
        host.frame = CGRect(origin: origin, size: size)
    }

    private func hideToolbar() {
        toolbar?.isHidden = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch Int(event.keyCode) {
        case kVK_Escape:
            controller.finish(.cancel)
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection == nil, let candidate = currentCandidate {
                controller.activate(self)
                selection = candidate
            }
            controller.finish(controller.primaryAction)
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(keyCode: Int(event.keyCode), step: modifiers.contains(.shift) ? 10 : 1)
            return
        default:
            break
        }

        if modifiers == .command {
            switch key {
            case "c" where selection != nil: controller.finish(.copy)
            case "s" where selection != nil: controller.finish(.save)
            case "t" where selection != nil: controller.finish(.pin)
            case "e" where selection != nil: controller.finish(.translate)
            case "z": editor.undo()
            default: super.keyDown(with: event)
            }
            return
        }
        if modifiers == [.command, .shift], key == "z" {
            editor.redo()
            return
        }

        if modifiers.isEmpty, let character = key.first {
            if selection == nil, character == "c" {
                copyColor()
                return
            }
            if selection != nil, let tool = CaptureTool.allCases.first(where: { $0.shortcut == character }) {
                editor.tool = editor.tool == tool ? nil : tool
                return
            }
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // 单独按下 ⇧ 切换放大镜里的颜色格式。
        guard event.keyCode == UInt16(kVK_Shift) || event.keyCode == UInt16(kVK_RightShift),
              event.modifierFlags.contains(.shift), showsMagnifier else { return }
        controller.showsRGB.toggle()
        controller.redrawAll()
    }

    /// 方向键：还没选时逐点移动鼠标（精确对准像素），选好后逐点移动选区。
    private func nudge(keyCode: Int, step: CGFloat) {
        let delta: CGPoint
        switch keyCode {
        case kVK_LeftArrow: delta = CGPoint(x: -step, y: 0)
        case kVK_RightArrow: delta = CGPoint(x: step, y: 0)
        case kVK_UpArrow: delta = CGPoint(x: 0, y: -step)
        default: delta = CGPoint(x: 0, y: step)
        }

        if var selection, editor.tool == nil {
            selection.origin.x = min(max(selection.minX + delta.x, 0), bounds.width - selection.width)
            selection.origin.y = min(max(selection.minY + delta.y, 0), bounds.height - selection.height)
            self.selection = selection
            layoutToolbar()
            needsDisplay = true
        } else if selection == nil, let mouse {
            let target = CGPoint(x: mouse.x + delta.x, y: mouse.y + delta.y).clamped(to: bounds)
            CGWarpMouseCursorPosition(shot.globalPoint(fromView: target))
            CGAssociateMouseAndMouseCursorPosition(1)
            updateHover(at: target)
        }
    }

    private func copyColor() {
        guard let mouse, let color = shot.color(at: mouse) else { return }
        Pasteboard.copy(controller.showsRGB ? color.rgb : color.hex)
        controller.finish(.cancel)
    }

    // MARK: - 导出

    func renderSelection() -> CaptureOutput? {
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        let pixelRect = shot.pixelRect(for: selection)
        guard let base = shot.image.cropping(to: pixelRect) else { return nil }

        let image: CGImage?
        if editor.annotations.isEmpty {
            image = base
        } else {
            let size = CGSize(width: pixelRect.width / shot.scale, height: pixelRect.height / shot.scale)
            let origin = CGPoint(x: pixelRect.minX / shot.scale, y: pixelRect.minY / shot.scale)
            image = SnipImage.render(size: size, scale: shot.scale, colorSpace: base.colorSpace) { context in
                context.drawUpright(base, in: CGRect(origin: .zero, size: size))
                context.translateBy(x: -origin.x, y: -origin.y)
                editor.annotations.forEach { $0.draw(in: context) }
            }
        }
        guard let image else { return nil }
        return CaptureOutput(image: image, frame: shot.cocoaRect(fromView: selection), pixelsPerPoint: shot.scale)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 已有选区就挖出选区；还没选时只在鼠标所在、且没有被别的屏幕占用时预览识别到的区域。
        let hole: CGRect?
        if let selection {
            hole = selection
        } else if mouse != nil, controller.activeView == nil || controller.activeView === self {
            hole = currentCandidate
        } else {
            hole = nil
        }
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(rect: hole)) }
        dim.windingRule = .evenOdd
        Self.dimColor.setFill()
        dim.fill()

        if let selection {
            context.saveGState()
            context.clip(to: selection)
            editor.annotations.forEach { $0.draw(in: context) }
            if let draft, draft.tool != .text { draft.draw(in: context) }
            context.restoreGState()
            drawSelectionChrome(selection)
        } else if let hole {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: hole.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }

        if showsMagnifier, let mouse {
            drawMagnifier(at: mouse)
        }
    }

    private func drawSelectionChrome(_ rect: CGRect) {
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()

        if editor.tool == nil, !isDrawing {
            for y in -1...1 {
                for x in -1...1 where !(x == 0 && y == 0) {
                    let center = handlePoint(x: x, y: y, in: rect)
                    let dot = NSBezierPath(ovalIn: CGRect(x: center.x - Self.handleRadius, y: center.y - Self.handleRadius, width: Self.handleRadius * 2, height: Self.handleRadius * 2))
                    NSColor.controlAccentColor.setFill()
                    dot.fill()
                    NSColor.white.setStroke()
                    dot.lineWidth = 1
                    dot.stroke()
                }
            }
        }

        // 左上角的像素尺寸。
        let pixel = shot.pixelRect(for: rect)
        let label = "\(Int(pixel.width)) × \(Int(pixel.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        var badge = CGRect(x: rect.minX, y: rect.minY - textSize.height - 10, width: textSize.width + 12, height: textSize.height + 6)
        if badge.minY < 2 { badge.origin.y = rect.minY + 4; badge.origin.x += 4 }
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        (label as NSString).draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
    }

    private var isDrawing: Bool {
        if case .drawing = drag { return true }
        return false
    }

    private func drawMagnifier(at point: CGPoint) {
        let pixels = 15
        let cell: CGFloat = 8
        let zoomSide = CGFloat(pixels) * cell
        let infoHeight: CGFloat = 58
        let size = CGSize(width: zoomSide, height: zoomSide + infoHeight)

        var origin = CGPoint(x: point.x + 18, y: point.y + 22)
        if origin.x + size.width > bounds.maxX - 4 { origin.x = point.x - 18 - size.width }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = point.y - 22 - size.height }
        let frame = CGRect(origin: origin, size: size)
        let zoomRect = CGRect(x: frame.minX, y: frame.minY, width: zoomSide, height: zoomSide)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        context.saveGState()
        shape.addClip()

        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        frame.fill()

        // 放大区域：以鼠标所在像素为中心，图像边缘外的部分留黑。
        let centerX = Int(point.x * shot.scale), centerY = Int(point.y * shot.scale)
        let region = CGRect(x: centerX - pixels / 2, y: centerY - pixels / 2, width: pixels, height: pixels)
        let available = region.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        NSColor.black.setFill()
        zoomRect.fill()
        if !available.isEmpty, let crop = shot.image.cropping(to: available) {
            context.interpolationQuality = .none
            let destination = CGRect(
                x: zoomRect.minX + (available.minX - region.minX) * cell,
                y: zoomRect.minY + (available.minY - region.minY) * cell,
                width: available.width * cell,
                height: available.height * cell
            )
            context.drawUpright(crop, in: destination)
        }

        // 十字准线与中心像素框。
        let middle = CGFloat(pixels / 2) * cell
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        CGRect(x: zoomRect.minX, y: zoomRect.minY + middle, width: zoomSide, height: cell).fill()
        CGRect(x: zoomRect.minX + middle, y: zoomRect.minY, width: cell, height: zoomSide).fill()
        NSColor.white.setStroke()
        let centerBox = NSBezierPath(rect: CGRect(x: zoomRect.minX + middle, y: zoomRect.minY + middle, width: cell, height: cell))
        centerBox.lineWidth = 1
        centerBox.stroke()

        // 信息区：坐标（或正在框选的尺寸）、颜色值、操作提示。
        let primary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textX = frame.minX + 8
        var textY = zoomRect.maxY + 6

        let positionText: String
        if let selection, drag != nil {
            let pixel = shot.pixelRect(for: selection)
            positionText = "\(Int(pixel.width)) × \(Int(pixel.height))"
        } else {
            positionText = "\(Int(point.x)), \(Int(point.y))"
        }
        (positionText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: primary)
        textY += 16

        if let color = shot.color(at: point) {
            let swatch = CGRect(x: textX, y: textY + 2, width: 10, height: 10)
            color.nsColor.setFill()
            swatch.fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: swatch).stroke()
            ((controller.showsRGB ? color.rgb : color.hex) as NSString).draw(at: CGPoint(x: textX + 16, y: textY), withAttributes: primary)
        }
        textY += 17

        ("C 复制颜色  ⇧ 切换格式" as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: secondary)
        context.restoreGState()

        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

private extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
