import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

/// 一组 Carbon 全局快捷键。默认是常用文本面板的 ⌥Space；
/// 截图、贴图等其他功能用不同的 `id` 各自注册一个实例。
final class GlobalHotKeyController {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var globalEventMonitor: Any?
    private let keyCode: UInt32
    private let carbonModifiers: UInt32
    private let hotKeyID: EventHotKeyID
    private let name: String
    private let logger = Logger(subsystem: "com.mino.CommonClipboard", category: "GlobalHotKey")
    private var lastTriggerTime: TimeInterval = 0

    var onHotKey: (() -> Void)?

    init(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(optionKey),
        id: UInt32 = 1,
        name: String = "Option-Space"
    ) {
        self.keyCode = keyCode
        self.carbonModifiers = modifiers
        self.hotKeyID = EventHotKeyID(signature: OSType(0x4342484B), id: id)
        self.name = name
    }

    @discardableResult
    func register() -> Bool {
        guard hotKeyReference == nil, eventHandlerReference == nil else {
            logger.info("Global hot key \(self.name) was already registered")
            return true
        }

        logger.info("Registering \(self.name) global hot key")
        NSLog("[CommonClipboard] registering %@ global hot key", name)
        installGlobalMonitorFallback()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

            let controller = Unmanaged<GlobalHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()

            // 每个实例都在应用事件目标上装了处理器，只认自己的 id；
            // 不是自己的就交给下一个处理器，否则其他快捷键会被吞掉。
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            guard status == noErr,
                  pressedID.signature == controller.hotKeyID.signature,
                  pressedID.id == controller.hotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }

            controller.logger.info("Received \(controller.name) global hot key event")
            controller.notifyHotKey()
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            userData,
            &eventHandlerReference
        )

        guard handlerStatus == noErr else {
            logger.error("InstallEventHandler failed with status \(handlerStatus)")
            NSLog("[CommonClipboard] InstallEventHandler failed: %d", handlerStatus)
            return false
        }

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registrationStatus == noErr else {
            logger.error("RegisterEventHotKey failed with status \(registrationStatus)")
            NSLog("[CommonClipboard] RegisterEventHotKey %@ failed: %d", name, registrationStatus)
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            return false
        }

        hotKeyReference = registeredHotKey
        logger.info("\(self.name) global hot key registered successfully")
        NSLog("[CommonClipboard] %@ global hot key registered successfully", name)
        return true
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }

        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    deinit {
        unregister()
    }

    private func installGlobalMonitorFallback() {
        guard globalEventMonitor == nil else { return }

        let keyCode = UInt16(keyCode)
        let modifiers = Self.cocoaModifiers(carbonModifiers)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == keyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .intersection([.command, .option, .control, .shift]) == modifiers else {
                return
            }

            self?.logger.info("Received hot key from global NSEvent monitor")
            self?.notifyHotKey()
        }
    }

    private static func cocoaModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private func notifyHotKey() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTime > 0.25 else { return }
        lastTriggerTime = now

        DispatchQueue.main.async { [weak self] in
            self?.onHotKey?()
        }
    }
}
