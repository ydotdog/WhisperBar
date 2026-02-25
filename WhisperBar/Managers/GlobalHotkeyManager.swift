import AppKit
import Carbon

/// Monitors ⌥⌘R globally via Carbon RegisterEventHotKey.
/// Does NOT require Accessibility permission.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    var onKeyDown: (() -> Void)?
    var onKeyUp:   (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func register(onFailure: (() -> Void)? = nil) {
        // "WBAR" as OSType
        let signature: OSType = 0x57424152
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),         // key code 15 = R
            UInt32(optionKey | cmdKey), // ⌥⌘
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr else {
            onFailure?()
            return
        }
        hotKeyRef = ref

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        // InstallApplicationEventHandler is a macro; call InstallEventHandler directly
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let mgr = Unmanaged<GlobalHotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard hkID.signature == 0x57424152, hkID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }

                let kind = GetEventKind(event)
                if kind == UInt32(kEventHotKeyPressed) {
                    mgr.onKeyDown?()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    mgr.onKeyUp?()
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &handlerRef
        )
        eventHandlerRef = handlerRef
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
}
