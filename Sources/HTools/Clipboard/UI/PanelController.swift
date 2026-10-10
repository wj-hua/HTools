import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 菜单栏 App 的面板可能在第一次点击时还不是 key window。普通的 `NSHostingView`
/// 会让空白背景遵循 AppKit 的 first-mouse 规则，导致这次按压没有进入 SwiftUI 手势。
/// 明确接受 first mouse 后，空白区域和按钮一样会拦住点击，不会落到下面的 App。
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 把面板空白区域里的鼠标拖动转换成窗口移动。
///
/// 位移一律按**屏幕坐标**计算，不能用 SwiftUI 手势的 `translation`：后者是窗口
/// 坐标系里的量，窗口一旦被移动，同一个鼠标位置算出来的 translation 就会缩回去，
/// 于是每个事件都在 `W0` 和 `W0 + 位移` 之间来回跳。屏幕坐标不受窗口移动影响。
struct WindowDragRecognizer {
    private struct Anchor {
        let windowOrigin: CGPoint
        let pointerLocation: CGPoint
    }

    private var anchor: Anchor?

    var isDragging: Bool {
        anchor != nil
    }

    /// 返回窗口应该被放到的新原点；返回 `nil` 表示这次事件不移动窗口。
    ///
    /// - Parameters:
    ///   - pointerLocation: 鼠标的屏幕坐标（y 轴向上，与窗口原点同向）。
    ///   - windowFrame: 当前窗口位置，只有按下的第一个事件会用到。
    mutating func update(
        pointerLocation: CGPoint,
        windowFrame: CGRect
    ) -> CGPoint? {
        guard let anchor else {
            // 第一个事件发生在按下的瞬间，此时只记录起点；后续任意位移都会直接移动窗口。
            self.anchor = Anchor(
                windowOrigin: windowFrame.origin,
                pointerLocation: pointerLocation
            )
            return nil
        }

        return origin(from: anchor, pointerLocation: pointerLocation)
    }

    mutating func end() {
        anchor = nil
    }

    private func offset(from anchor: Anchor, pointerLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: pointerLocation.x - anchor.pointerLocation.x,
            y: pointerLocation.y - anchor.pointerLocation.y
        )
    }

    private func origin(from anchor: Anchor, pointerLocation: CGPoint) -> CGPoint {
        let offset = self.offset(from: anchor, pointerLocation: pointerLocation)
        return CGPoint(
            x: anchor.windowOrigin.x + offset.x,
            y: anchor.windowOrigin.y + offset.y
        )
    }
}

/// 把滚轮位移转换成离散的列表/标签选择。
///
/// 普通鼠标滚轮的事件会经过限速；触控板和高精度滚轮还会先累计位移，达到阈值后
/// 再移动。无论设备一次发出多少事件或多大的位移，每个时间窗口最多只移动一步。
struct ScrollWheelNavigationRecognizer {
    enum Axis: Equatable {
        case items
        case tags
    }

    struct Navigation: Equatable {
        let axis: Axis
        let offset: Int
    }

    static let preciseStepThreshold: CGFloat = 12
    static let minimumStepInterval: TimeInterval = 0.25

    private var lockedGestureAxis: Axis?
    private var accumulatedAxis: Axis?
    private var accumulatedDelta: CGFloat = 0
    private var lastNavigationTimestamp: TimeInterval?

    mutating func update(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Navigation? {
        // 惯性阶段没有新的用户输入，若继续响应会在松手后仍不断改变选择。
        guard momentumPhase.isEmpty else {
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                resetGestureState()
            }
            return nil
        }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            resetGestureState()
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            resetGestureState()
            return nil
        }

        guard let dominantAxis = dominantAxis(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta
        ) else {
            return nil
        }

        guard hasPreciseScrollingDeltas else {
            resetGestureState()
            guard shouldEmitNavigation(at: timestamp) else { return nil }
            return Navigation(
                axis: dominantAxis,
                offset: offset(
                    for: delta(
                        along: dominantAxis,
                        horizontalDelta: horizontalDelta,
                        verticalDelta: verticalDelta
                    ),
                    along: dominantAxis
                )
            )
        }

        let axis: Axis
        if let lockedGestureAxis {
            axis = lockedGestureAxis
        } else {
            axis = dominantAxis
            // 只有带 phase 的连续手势才锁定方向。部分高精度鼠标不提供 phase，
            // 它们仍可以在相邻事件之间自由切换横向和纵向滚动。
            if !phase.isEmpty {
                lockedGestureAxis = axis
            }
        }

        if accumulatedAxis != axis {
            accumulatedAxis = axis
            accumulatedDelta = 0
        }

        accumulatedDelta += delta(
            along: axis,
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta
        )

        let stepCount = Int(abs(accumulatedDelta) / Self.preciseStepThreshold)
        guard stepCount > 0 else { return nil }

        let direction = offset(for: accumulatedDelta, along: axis)
        accumulatedDelta -= CGFloat(-direction * stepCount) * Self.preciseStepThreshold
        guard shouldEmitNavigation(at: timestamp) else { return nil }

        // 大位移只取一步，多余的整步直接丢弃，避免限速后又补跳。
        return Navigation(axis: axis, offset: direction)
    }

    mutating func reset() {
        resetGestureState()
        lastNavigationTimestamp = nil
    }

    private mutating func resetGestureState() {
        lockedGestureAxis = nil
        accumulatedAxis = nil
        accumulatedDelta = 0
    }

    private mutating func shouldEmitNavigation(at timestamp: TimeInterval) -> Bool {
        guard let lastNavigationTimestamp else {
            self.lastNavigationTimestamp = timestamp
            return true
        }

        guard timestamp >= lastNavigationTimestamp else {
            self.lastNavigationTimestamp = timestamp
            return true
        }

        guard timestamp - lastNavigationTimestamp >= Self.minimumStepInterval else {
            return false
        }

        self.lastNavigationTimestamp = timestamp
        return true
    }

    private func dominantAxis(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat
    ) -> Axis? {
        guard horizontalDelta != 0 || verticalDelta != 0 else { return nil }
        return abs(horizontalDelta) > abs(verticalDelta) ? .tags : .items
    }

    private func delta(
        along axis: Axis,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat
    ) -> CGFloat {
        switch axis {
        case .items:
            return verticalDelta
        case .tags:
            return horizontalDelta
        }
    }

    private func offset(for delta: CGFloat, along axis: Axis) -> Int {
        switch axis {
        case .items:
            return delta > 0 ? -1 : 1
        case .tags:
            return delta > 0 ? 1 : -1
        }
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let viewModel: ClipboardViewModel
    private let panel: FloatingPanel
    private var localEventMonitor: Any?
    private var sizeCancellables = Set<AnyCancellable>()
    private var windowDragRecognizer = WindowDragRecognizer()
    private var scrollWheelNavigationRecognizer = ScrollWheelNavigationRecognizer()

    init(viewModel: ClipboardViewModel) {
        self.viewModel = viewModel
        self.panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardPanelView.panelWidth,
                height: ClipboardPanelView.panelHeight(
                    for: viewModel.visibleItems.count,
                    tags: viewModel.tags,
                    mode: viewModel.mode
                )
            ),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Window movement is implemented below so interactive controls can be
        // excluded. The AppKit default would also move the panel from controls.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = PanelHostingView(
            rootView: ClipboardPanelView(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.hide()
                },
                onWindowDragChanged: { [weak self] in
                    self?.handleWindowDragChanged()
                },
                onWindowDragEnded: { [weak self] in
                    self?.endWindowDrag()
                }
            )
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        viewModel.$items
            .combineLatest(viewModel.$tags, viewModel.$mode)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updatePanelSize()
            }
            .store(in: &sizeCancellables)

        viewModel.$searchText
            .combineLatest(viewModel.$searchScope)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updatePanelSize()
            }
            .store(in: &sizeCancellables)

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else {
                return event
            }

            switch event.type {
            case .keyDown:
                return self.handleKeyDown(event) ? nil : event
            case .scrollWheel:
                return self.handleScrollWheel(event) ? nil : event
            default:
                return event
            }
        }
    }

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        present(targetApplication: currentTargetApplication())
    }

    func showForAdding() {
        present(targetApplication: currentTargetApplication())
        viewModel.beginAdding()
    }

    func hide() {
        endWindowDrag()
        scrollWheelNavigationRecognizer.reset()
        panel.orderOut(nil)
        viewModel.dismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.sheets.isEmpty, panel.isVisible else { return }

        // AppKit may briefly report a resign-key event while the accessory app is
        // being activated. Wait one run-loop turn before treating it as an
        // intentional click outside the panel.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.panel.sheets.isEmpty,
                  self.panel.isVisible,
                  !self.panel.isKeyWindow,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else {
                return
            }

            // An alert that AppKit puts in its own window instead of a sheet also
            // takes key away from the panel (alerts are NSPanel subclasses).
            // `keyWindow` is nil once the click went to another application;
            // clicking HTools' own main window should also dismiss the panel.
            if let keyWindow = NSApp.keyWindow, keyWindow is NSPanel { return }

            self.hide()
        }
    }

    private func present(targetApplication: NSRunningApplication?) {
        viewModel.prepareForPresentation(targetApplication: targetApplication)
        updatePanelSize(animated: false)
        positionPanel()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        viewModel.requestSearchFocus()
    }

    private func updatePanelSize(animated: Bool = true) {
        let desiredHeight = ClipboardPanelView.panelHeight(
            for: viewModel.visibleItems.count,
            tags: viewModel.tags,
            mode: viewModel.mode
        )
        guard abs(panel.frame.height - desiredHeight) > 0.5 else { return }

        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: ClipboardPanelView.panelWidth, height: desiredHeight)
        frame.origin.y = topEdge - desiredHeight
        frame.origin.y = clampedOriginY(for: frame)
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    /// 面板固定顶边向下生长，标签换行时底栏可能被顶到屏幕外，
    /// 所以变高之后要把它拉回可视区域；比可视区域还高时只能居中，两端各让一点。
    private func clampedOriginY(for frame: NSRect) -> CGFloat {
        guard let screen = panel.screen ?? NSScreen.main else { return frame.origin.y }

        let visibleFrame = screen.visibleFrame
        guard frame.height < visibleFrame.height else {
            return visibleFrame.midY - frame.height / 2
        }

        return min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func currentTargetApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            if viewModel.mode == .editor {
                viewModel.cancelEditing()
            } else if viewModel.clearSearch() {
                viewModel.requestSearchFocus()
            } else {
                hide()
            }
            return true
        }

        if viewModel.mode == .list, isSearchFocusShortcut(event) {
            viewModel.requestSearchFocus()
            return true
        }

        if viewModel.mode == .editor {
            if handleEditingShortcut(event) {
                return true
            }

            if handleEditorSubmit(event) {
                return true
            }
        }

        guard viewModel.mode == .list else { return false }

        if isCopyShortcut(event) {
            _ = viewModel.copySelectedItem()
            return true
        }

        if handleListShortcut(event) {
            return true
        }

        switch event.keyCode {
        case UInt16(kVK_UpArrow):
            viewModel.moveSelection(by: -1)
            return true
        case UInt16(kVK_DownArrow):
            viewModel.moveSelection(by: 1)
            return true
        case UInt16(kVK_LeftArrow):
            viewModel.moveTagSelection(by: -1)
            return true
        case UInt16(kVK_RightArrow):
            viewModel.moveTagSelection(by: 1)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if viewModel.pasteSelectedItem() {
                hide()
            }
            return true
        default:
            return false
        }
    }

    private func isSearchFocusShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        return modifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    private func isCopyShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        return modifiers == .command
            && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard viewModel.mode == .list,
              panel.frame.contains(NSEvent.mouseLocation) else {
            scrollWheelNavigationRecognizer.reset()
            return false
        }

        var horizontalDelta = event.scrollingDeltaX
        var verticalDelta = event.scrollingDeltaY

        // 兼容没有侧向滚轮的鼠标：macOS 常用 Shift + 滚轮表达横向滚动。
        if event.modifierFlags.contains(.shift), horizontalDelta == 0 {
            horizontalDelta = verticalDelta
            verticalDelta = 0
        }

        let hasScrollingDelta = horizontalDelta != 0 || verticalDelta != 0
        let hasScrollingPhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard hasScrollingDelta || hasScrollingPhase else { return false }

        if let navigation = scrollWheelNavigationRecognizer.update(
            horizontalDelta: horizontalDelta,
            verticalDelta: verticalDelta,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            timestamp: event.timestamp
        ) {
            switch navigation.axis {
            case .items:
                viewModel.moveSelection(by: navigation.offset)
            case .tags:
                viewModel.moveTagSelection(by: navigation.offset)
            }
        }

        // 列表模式下滚轮用于改变选择；吞掉原事件，避免 List/标签 ScrollView 同时滚动。
        return true
    }

    private func handleListShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift) else {
            return false
        }

        guard let index = listShortcutItemIndex(for: event.keyCode) else { return false }
        if viewModel.pasteItem(at: index) {
            hide()
        }
        return true
    }

    private func listShortcutItemIndex(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_Keypad1):
            return 0
        case UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_Keypad2):
            return 1
        case UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_Keypad3):
            return 2
        case UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_Keypad4):
            return 3
        case UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_Keypad5):
            return 4
        case UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_Keypad6):
            return 5
        case UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_Keypad7):
            return 6
        case UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_Keypad8):
            return 7
        case UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_Keypad9):
            return 8
        default:
            return nil
        }
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        let selector: Selector?
        switch characters {
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "x":
            selector = #selector(NSText.cut(_:))
        case "a":
            selector = #selector(NSText.selectAll(_:))
        default:
            selector = nil
        }

        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func handleEditorSubmit(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Return)
                || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else {
            return false
        }

        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        guard textInputModifiers.isEmpty else { return false }

        if let textInputClient = panel.firstResponder as? NSTextInputClient,
           textInputClient.hasMarkedText() {
            return false
        }

        viewModel.saveDraft()
        return true
    }

    private func handleWindowDragChanged() {
        guard panel.isVisible,
              let origin = windowDragRecognizer.update(
                  pointerLocation: NSEvent.mouseLocation,
                  windowFrame: panel.frame
              ) else {
            return
        }

        panel.setFrameOrigin(origin)
    }

    private func endWindowDrag() {
        windowDragRecognizer.end()
    }
}
