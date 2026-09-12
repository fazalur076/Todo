import Foundation
import AppKit
import Carbon

@MainActor
public final class ShortcutService {
    public static let shared = ShortcutService()

    public var onQuickCapture: (() -> Void)?
    public var onSwitchToWork: (() -> Void)?
    public var onSwitchToPersonal: (() -> Void)?
    public var onToggleMainPanel: (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    private let signature: OSType = 0x544F444F // 'TODO'

    private init() {
        setupCarbonHotkeys()
    }

    private func setupCarbonHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr else { return noErr }

            DispatchQueue.main.async {
                ShortcutService.shared.handleHotKey(id: hkID.id)
            }
            return noErr
        }

        // Install event handler on system event dispatcher target for global intercept
        let target = GetEventDispatcherTarget()
        InstallEventHandler(target, handler, 1, &eventType, nil, &eventHandlerRef)

        // Register ⌥ Space (Quick Capture, keycode 49)
        registerHotKey(keyCode: 49, modifiers: UInt32(optionKey), id: 1)

        // Register ⌥⌘W (Switch to Work, keycode 13)
        registerHotKey(keyCode: 13, modifiers: UInt32(optionKey | cmdKey), id: 2)

        // Register ⌥⌘P (Switch to Personal, keycode 35)
        registerHotKey(keyCode: 35, modifiers: UInt32(optionKey | cmdKey), id: 3)

        // Register ⌥⌘T (Toggle Main Task Panel, keycode 17)
        registerHotKey(keyCode: 17, modifiers: UInt32(optionKey | cmdKey), id: 4)
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs.append(ref)
        } else {
            print("Failed to register hotkey \(id), status: \(status)")
        }
    }

    private func handleHotKey(id: UInt32) {
        switch id {
        case 1:
            onQuickCapture?()
        case 2:
            onSwitchToWork?()
        case 3:
            onSwitchToPersonal?()
        case 4:
            onToggleMainPanel?()
        default:
            break
        }
    }

    public func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}
