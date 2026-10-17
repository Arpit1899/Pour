import AppKit
import Carbon.HIToolbox

/// Carbon-based global hotkey manager. Works with no Accessibility or Input
/// Monitoring permission — the OS only delivers the specific combo we
/// registered, so it's not "monitoring input."
///
/// Default combo: ⌃␣ — push-to-talk (press + release).
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let hotKeyID: UInt32 = 1
    private static let signature: OSType = 0x504F5552 // 'POUR'

    private init() {}

    /// Install the event handler once, then bind `combo`. Safe to call again
    /// with a different combo — the old binding is released first.
    func register(_ combo: HotKeyCombo) {
        installHandlerIfNeeded()
        bind(combo)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(eventRef)

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.id == GlobalHotKey.hotKeyID else { return noErr }

                DispatchQueue.main.async {
                    switch Int(kind) {
                    case kEventHotKeyPressed:  manager.onPressed?()
                    case kEventHotKeyReleased: manager.onReleased?()
                    default: break
                    }
                }
                return noErr
            },
            2,
            &eventTypes,
            selfPtr,
            &handlerRef
        )
        if handlerStatus != noErr {
            NSLog("[pour] InstallEventHandler failed → \(handlerStatus)")
        }
    }

    /// Bind a combo, replacing whatever was bound before.
    ///
    /// A non-zero status here almost always means another app already owns the
    /// shortcut, which is the case worth surfacing to the user — so the result
    /// is reported rather than swallowed.
    @discardableResult
    private func bind(_ combo: HotKeyCombo) -> Bool {
        releaseBinding()
        guard combo.isValid else { return false }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("[pour] RegisterEventHotKey(\(combo.displayString)) failed → \(status)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    private func releaseBinding() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }

    func unregister() {
        releaseBinding()
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }
}
