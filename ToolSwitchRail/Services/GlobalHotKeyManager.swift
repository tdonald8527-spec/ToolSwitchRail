import Foundation
import Carbon.HIToolbox

final class GlobalHotKeyManager {
    var onHotKey: ((Int) -> Void)?
    var onMinimizeHotKey: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let signature: OSType = 0x5453524C // 'TSRL'
    private let minimizeHotKeyID: UInt32 = 999

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                if hotKeyID.id == manager.minimizeHotKeyID {
                    manager.onMinimizeHotKey?()
                } else {
                    manager.onHotKey?(Int(hotKeyID.id))
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(count: Int) {
        unregisterAll()

        let keyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]

        let modifiers = UInt32(cmdKey | optionKey)

        for index in 0..<min(count, keyCodes.count) {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: signature, id: UInt32(index))
            RegisterEventHotKey(
                keyCodes[index],
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            hotKeyRefs.append(ref)
        }

        // Register Cmd + Option + M for Minimize / Toggle
        var minRef: EventHotKeyRef?
        let minHotKeyID = EventHotKeyID(signature: signature, id: minimizeHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            modifiers,
            minHotKeyID,
            GetApplicationEventTarget(),
            0,
            &minRef
        )
        hotKeyRefs.append(minRef)
    }

    private func unregisterAll() {
        for ref in hotKeyRefs.compactMap({ $0 }) {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}
