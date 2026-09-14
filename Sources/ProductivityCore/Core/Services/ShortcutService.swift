import Foundation
import AppKit
import Carbon

@MainActor
public final class ShortcutService {
    public static let shared = ShortcutService()

    public var onQuickCapture: (() -> Void)?
    public var onSwitchToWork: (() -> Void)?
    public var onSwitchToPersonal: (() -> Void)?
    public var onSwitchToWorkspace: ((String) -> Void)?
    public var onToggleMainPanel: (() -> Void)?

    private var staticHotKeyRefs: [EventHotKeyRef] = []
    private var dynamicHotKeyRefs: [EventHotKeyRef] = []
    private var dynamicWorkspaceMap: [UInt32: String] = [:] // hotkey ID -> workspace ID
    private var eventHandlerRef: EventHandlerRef?

    private let signature: OSType = 0x544F444F // 'TODO'

    private init() {
        setupCarbonEventHandler()
        registerStaticHotkeys()
    }

    private func setupCarbonEventHandler() {
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
    }

    private func registerStaticHotkeys() {
        // Register ⌥ Space (Quick Capture, keycode 49)
        registerStaticHotKey(keyCode: 49, modifiers: UInt32(optionKey), id: 1)

        // Register ⌥⌘T (Toggle Main Task Panel, keycode 17)
        registerStaticHotKey(keyCode: 17, modifiers: UInt32(optionKey | cmdKey), id: 4)
    }

    private func registerStaticHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
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
            staticHotKeyRefs.append(ref)
        }
    }

    public func reloadDynamicHotkeys(workspaces: [WorkspaceDefinition]) {
        // Unregister previous dynamic hotkeys
        for ref in dynamicHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        dynamicHotKeyRefs.removeAll()
        dynamicWorkspaceMap.removeAll()

        var currentId: UInt32 = 100
        for ws in workspaces {
            guard let keyStr = ws.shortcutKey?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  let firstChar = keyStr.first,
                  let code = keyCode(for: firstChar) else {
                continue
            }

            let hotKeyID = EventHotKeyID(signature: signature, id: currentId)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                code,
                UInt32(optionKey | cmdKey),
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let ref = hotKeyRef {
                dynamicHotKeyRefs.append(ref)
                dynamicWorkspaceMap[currentId] = ws.id
                currentId += 1
            }
        }
    }

    private func handleHotKey(id: UInt32) {
        switch id {
        case 1:
            onQuickCapture?()
        case 4:
            onToggleMainPanel?()
        default:
            if let wsId = dynamicWorkspaceMap[id] {
                onSwitchToWorkspace?(wsId)
                if wsId == "work" {
                    onSwitchToWork?()
                } else if wsId == "personal" {
                    onSwitchToPersonal?()
                }
            }
        }
    }

    public func unregisterAll() {
        for ref in staticHotKeyRefs + dynamicHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        staticHotKeyRefs.removeAll()
        dynamicHotKeyRefs.removeAll()
        dynamicWorkspaceMap.removeAll()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    public static func keyCode(for char: Character) -> UInt32? {
        switch char {
        case "A", "a": return 0
        case "S", "s": return 1
        case "D", "d": return 2
        case "F", "f": return 3
        case "H", "h": return 4
        case "G", "g": return 5
        case "Z", "z": return 6
        case "X", "x": return 7
        case "C", "c": return 8
        case "V", "v": return 9
        case "B", "b": return 11
        case "Q", "q": return 12
        case "W", "w": return 13
        case "E", "e": return 14
        case "R", "r": return 15
        case "Y", "y": return 16
        case "T", "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "9": return 25
        case "7": return 26
        case "8": return 28
        case "0": return 29
        case "O", "o": return 31
        case "U", "u": return 32
        case "I", "i": return 34
        case "P", "p": return 35
        case "L", "l": return 37
        case "J", "j": return 38
        case "K", "k": return 40
        case "N", "n": return 45
        case "M", "m": return 46
        default: return nil
        }
    }

    private func keyCode(for char: Character) -> UInt32? {
        Self.keyCode(for: char)
    }
}
