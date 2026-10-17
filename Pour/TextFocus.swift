import AppKit
import ApplicationServices

/// Whether the app about to receive a paste has somewhere to put it, asked of
/// its focused element through Accessibility.
enum TextFocus {
    case editable, notEditable, unknown

    /// Controls that never take typed text. Anything else without a text
    /// selection is `unknown`, and unknown pastes: the card is only for when
    /// Pour is sure. That includes containers (windows, scroll areas), which
    /// is what terminals and editors that draw their own text report, and
    /// tables, because spreadsheets paste into a selected cell. Electron apps
    /// such as Slack and VS Code report no focused element at all, which is
    /// also unknown.
    private static let nonText: Set<String> = [
        "AXOutline", "AXList", "AXBrowser", "AXButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXSlider", "AXImage", "AXStaticText", "AXLink",
        "AXDisclosureTriangle",
    ]

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    static func current() -> TextFocus {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app would otherwise hold the paste for AX's six-second default.
        AXUIElementSetMessagingTimeout(target, 0.25)

        guard let focused = value(kAXFocusedUIElementAttribute, of: target),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unknown }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        let role = value(kAXRoleAttribute, of: element) as? String ?? ""
        if textRoles.contains(role) || value(kAXSelectedTextRangeAttribute, of: element) != nil {
            return .editable
        }
        // Pour's own windows draw no text of their own, so anything there
        // that isn't a text field really has nowhere to paste.
        if app == NSRunningApplication.current { return .notEditable }
        return nonText.contains(role) ? .notEditable : .unknown
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}
