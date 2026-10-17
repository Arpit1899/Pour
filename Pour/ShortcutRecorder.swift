import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click, then press a combination. Captures the next key-down while armed and
/// hands back a Carbon-flavoured combo.
///
/// A local event monitor rather than a first responder: the settings window is
/// SwiftUI and we need the raw `keyCode`, which is not something a `TextField`
/// or `Button` will give up.
struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo
    /// Reported when the user presses a combination with no modifiers, which
    /// would swallow a bare key system-wide.
    var onInvalid: (() -> Void)? = nil

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(isRecording ? "Press keys…" : combo.displayString)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isRecording ? PourTheme.accent : .primary)
                .frame(minWidth: 96, minHeight: 30)
                .padding(.horizontal, 12)
                .background(
                    PourTheme.control.opacity(isRecording || hovering ? 0.75 : 1),
                    in: .rect(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isRecording ? PourTheme.accent.opacity(0.6)
                                        : PourTheme.hairline,
                            lineWidth: isRecording ? 1 : 0.5
                        )
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isRecording)
        .onChange(of: isRecording) { _, recording in
            recording ? startListening() : stopListening()
        }
        .onDisappear(perform: stopListening)
        .accessibilityLabel("Keyboard shortcut, currently \(combo.displayString)")
    }

    private func startListening() {
        stopListening()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifier presses alone just keep us waiting for the real key.
            guard event.type == .keyDown else { return nil }

            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                return nil            // swallow: Esc cancels, it doesn't bind
            }

            let carbon = Self.carbonModifiers(from: event.modifierFlags)
            guard carbon != 0 else {
                // A bare key would hijack that key everywhere on the system.
                onInvalid?()
                return nil
            }

            combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon)
            isRecording = false
            return nil                // swallow, so it never reaches the UI
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }
}
