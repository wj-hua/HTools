import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

final class GlobalHotKeyController {
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var globalEventMonitor: Any?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x4342484B), id: 1)
    private let logger = Logger(subsystem: "com.mino.CommonClipboard", category: "GlobalHotKey")
    private var lastTriggerTime: TimeInterval = 0

    var onHotKey: (() -> Void)?

    @discardableResult
    func register() -> Bool {
        guard hotKeyReference == nil, eventHandlerReference == nil else {
            logger.info("Global hot key was already registered")
            NSLog("[CommonClipboard] global hot key was already registered")
            return true
        }

        logger.info("Registering Option-Space global hot key")
        NSLog("[CommonClipboard] registering Option-Space global hot key")
        installGlobalMonitorFallback()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }

            let controller = Unmanaged<GlobalHotKeyController>
                .fromOpaque(userData)
                .takeUnretainedValue()
            controller.logger.info("Received Option-Space global hot key event")
            NSLog("[CommonClipboard] received Carbon Option-Space event")
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
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registrationStatus == noErr else {
            logger.error("RegisterEventHotKey failed with status \(registrationStatus)")
            NSLog("[CommonClipboard] RegisterEventHotKey failed: %d", registrationStatus)
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            return false
        }

        hotKeyReference = registeredHotKey
        logger.info("Option-Space global hot key registered successfully")
        NSLog("[CommonClipboard] Option-Space global hot key registered successfully")
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

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.contains(.option) else {
                return
            }

            self?.logger.info("Received Option-Space from global NSEvent monitor")
            NSLog("[CommonClipboard] received NSEvent monitor Option-Space event")
            self?.notifyHotKey()
        }
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
