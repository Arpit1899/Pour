import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Drops `text` into the system pasteboard and synthesizes ⌘V at the focused
/// app, so whatever text field the user was just typing in receives it.
@MainActor
enum Pasteboard {
    enum Delivery {
        /// The keystroke was sent; the text should be in the focused field.
        case pasted
        /// Accessibility isn't granted, so the text is on the clipboard only
        /// and the user has to paste it themselves.
        case copiedOnly
    }

    @discardableResult
    static func deliver(_ text: String) -> Delivery {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Without Accessibility the synthetic keystroke is dropped on the
        // floor with no error, so check first rather than reporting a paste
        // that silently never happened.
        guard AXIsProcessTrusted() else { return .copiedOnly }

        // Small delay so the pasteboard write commits before the synthetic
        // keystroke fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            synthesizeCmdV()
        }
        return .pasted
    }

    private static func synthesizeCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
