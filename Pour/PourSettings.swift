import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A recorded keyboard shortcut, stored in Carbon's vocabulary because that is
/// what `RegisterEventHotKey` speaks.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask — `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var modifiers: UInt32

    /// ⌃Space. Kept as the default for continuity, but it collides with the
    /// macOS "Select the previous input source" shortcut once a second input
    /// source exists — which is exactly why this is now editable.
    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space),
                                       modifiers: UInt32(controlKey))

    var isValid: Bool { modifiers != 0 }

    // MARK: - Display

    var displayString: String { modifierSymbols + keyName }

    /// The combination split into individual legends, so the UI can draw one
    /// physical cap per key rather than a single run-on string.
    var keyCaps: [String] { modifierSymbols.map(String.init) + [keyName] }

    private var modifierSymbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Named keys first; anything else is resolved against the user's actual
    /// keyboard layout so a French or Dvorak user sees their own legend.
    private var keyName: String {
        if let named = Self.namedKeys[Int(keyCode)] { return named }
        return Self.character(for: keyCode) ?? "Key \(keyCode)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
        kVK_Escape: "Esc", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Ask the current keyboard layout what this key produces, unmodified.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layout = unsafeBitCast(data, to: CFData.self)
        return (layout as Data).withUnsafeBytes { raw -> String? in
            guard let header = raw.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                header, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

/// How a dictation session is started and stopped.
enum ActivationMode: String, Codable, CaseIterable {
    /// Hold the shortcut for the duration of the sentence.
    case hold
    /// Press once to start, again to stop — for anything longer than a breath.
    case toggle

    var label: String {
        switch self {
        case .hold:   "Hold"
        case .toggle: "Press once"
        }
    }

    var detail: String {
        switch self {
        case .hold:   "Speak while the keys are down. Double-tap to keep listening"
        case .toggle: "Press once to start, again to finish"
        }
    }
}

/// Everything the user can change, persisted to `UserDefaults`.
///
/// Deliberately one small object rather than scattered `@AppStorage`: the
/// hotkey has to be re-registered when it changes, and a single owner makes
/// that a normal `didSet` instead of an observer hunt.
@MainActor
@Observable
final class PourSettings {
    static let shared = PourSettings()

    var hotKey: HotKeyCombo {
        didSet {
            guard hotKey != oldValue else { return }
            store(hotKey, forKey: Key.hotKey)
            onHotKeyChange?(hotKey)
        }
    }

    var activation: ActivationMode {
        didSet { defaults.set(activation.rawValue, forKey: Key.activation) }
    }

    /// Run the transcript through the on-device model before pasting.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanup) }
    }

    /// Let the receiving app decide how formal the cleaned text reads.
    var adaptTone: Bool {
        didSet { defaults.set(adaptTone, forKey: Key.adaptTone) }
    }

    /// Names, acronyms and jargon the recogniser should lean toward.
    var vocabulary: [String] {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }

    /// Keep the resting bar above the Dock between dictations.
    var showBarAlways: Bool {
        didSet {
            guard showBarAlways != oldValue else { return }
            defaults.set(showBarAlways, forKey: Key.showBar)
            onShowBarChange?(showBarAlways)
        }
    }

    /// Which edge the bar lives on. Changed by dragging the bar.
    var barDock: BarDock {
        didSet {
            guard barDock != oldValue else { return }
            defaults.set(barDock.rawValue, forKey: Key.barDock)
            onBarDockChange?()
        }
    }

    /// Core Audio UID of the chosen input, `nil` for the system default.
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Key.microphone) }
    }

    /// BCP 47 identifier of the language to listen for, `nil` to follow the
    /// Mac's language and region.
    var languageID: String? {
        didSet { defaults.set(languageID, forKey: Key.language) }
    }

    /// Installed by `AppDelegate` so a new shortcut takes effect immediately.
    var onHotKeyChange: ((HotKeyCombo) -> Void)?
    /// Installed by `AppDelegate`, which owns the bar's panel.
    var onShowBarChange: ((Bool) -> Void)?
    var onBarDockChange: (() -> Void)?

    private let defaults: UserDefaults

    private enum Key {
        static let hotKey = "pour.hotKey"
        static let activation = "pour.activation"
        static let vocabulary = "pour.vocabulary"
        static let cleanup = "pour.cleanup"
        static let adaptTone = "pour.adaptTone"
        static let showBar = "pour.showBarAlways"
        static let barDock = "pour.barDock"
        static let microphone = "pour.microphoneUID"
        static let language = "pour.languageID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotKey = Self.load(HotKeyCombo.self, forKey: Key.hotKey, from: defaults)
            ?? .default
        self.activation = defaults.string(forKey: Key.activation)
            .flatMap(ActivationMode.init(rawValue:)) ?? .hold
        self.vocabulary = defaults.stringArray(forKey: Key.vocabulary) ?? []
        // Defaults on when the hardware supports it — it is the feature, not
        // an extra.
        self.cleanupEnabled = defaults.object(forKey: Key.cleanup) as? Bool ?? true
        self.adaptTone = defaults.object(forKey: Key.adaptTone) as? Bool ?? true
        self.showBarAlways = defaults.object(forKey: Key.showBar) as? Bool ?? true
        self.barDock = defaults.string(forKey: Key.barDock).flatMap(BarDock.init(rawValue:)) ?? .bottom
        self.microphoneUID = defaults.string(forKey: Key.microphone)
        self.languageID = defaults.string(forKey: Key.language)
    }

    func addVocabulary(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        vocabulary.append(trimmed)
    }

    func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
    }

    // MARK: - Codable storage

    private func store<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type,
                                          forKey key: String,
                                          from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Open at login, through the system's own Login Items list rather than a
/// preference of ours, so the toggle and System Settings can never disagree.
@MainActor
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status

    var isEnabled: Bool { status == .enabled }
    /// The user turned it on, but macOS wants them to confirm in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[pour] login item \(enabled ? "register" : "unregister") failed → \(error)")
        }
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
