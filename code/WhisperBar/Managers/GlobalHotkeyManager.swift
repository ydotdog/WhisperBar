import AppKit
import Carbon

/// Manages two global hotkeys:
/// 1. Long-press Space Bar (CGEvent tap) — push-to-talk
/// 2. ⌥⌘R (Carbon hotkey) — toggle recording on/off
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    // Space bar: push-to-talk callbacks
    var onSpaceDown: (() -> Void)?
    var onSpaceUp:   (() -> Void)?

    // ⌥⌘R: toggle callback
    var onHotkeyPressed: (() -> Void)?

    // ── Space bar state ──
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var spaceDownTime: Date?
    private var isRecordingTriggered = false
    private var holdTimer: DispatchWorkItem?
    private var tapCheckTimer: Timer?

    private let holdThreshold: TimeInterval = 0.4
    private static let spaceKeyCode: Int64 = 49
    private static let reinjectedTag: Int64 = 0x57_42_41  // "WBA"

    // ── Carbon hotkey state ──
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Register both hotkey mechanisms.
    func register() {
        registerSpaceBar()
        registerCarbonHotkey()
    }

    func unregister() {
        unregisterSpaceBar()
        unregisterCarbonHotkey()
    }

    // MARK: - Space Bar (CGEvent Tap)

    private func registerSpaceBar() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<GlobalHotkeyManager>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return mgr.handleSpaceEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            // CGEvent tap failed (likely missing Accessibility permission)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Periodically verify tap is alive
        tapCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    private func unregisterSpaceBar() {
        tapCheckTimer?.invalidate()
        tapCheckTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleSpaceEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if system disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.spaceKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Pass through re-injected events
        if event.getIntegerValueField(.eventSourceUserData) == Self.reinjectedTag {
            return Unmanaged.passUnretained(event)
        }

        // Pass through if any modifier is held
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate) {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return isRecordingTriggered ? nil : Unmanaged.passUnretained(event)
            }
            if spaceDownTime == nil {
                spaceDownTime = Date()
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.spaceDownTime != nil else { return }
                    self.isRecordingTriggered = true
                    self.onSpaceDown?()
                }
                holdTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
                return nil
            }
            return nil
        } else if type == .keyUp {
            guard spaceDownTime != nil else {
                return Unmanaged.passUnretained(event)
            }
            spaceDownTime = nil
            holdTimer?.cancel()
            holdTimer = nil

            if isRecordingTriggered {
                isRecordingTriggered = false
                onSpaceUp?()
                return nil
            } else {
                // Quick tap — re-inject space
                let src = CGEventSource(stateID: .combinedSessionState)
                if let down = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true) {
                    down.setIntegerValueField(.eventSourceUserData, value: Self.reinjectedTag)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false) {
                    up.setIntegerValueField(.eventSourceUserData, value: Self.reinjectedTag)
                    up.post(tap: .cghidEventTap)
                }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - ⌥⌘R (Carbon Hotkey)

    private func registerCarbonHotkey() {
        let signature: OSType = 0x57424152  // "WBAR"
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else { return }
        hotKeyRef = ref

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed))
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<GlobalHotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()

                var hkID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                guard hkID.signature == 0x57424152, hkID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                mgr.onHotkeyPressed?()
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &handlerRef
        )
        eventHandlerRef = handlerRef
    }

    private func unregisterCarbonHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
}
