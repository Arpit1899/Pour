import SwiftUI
import AppKit
import AVFoundation

/// The window is a dark field with nothing drawn on it. There is exactly one
/// object here — the notch — and everything else is type, whitespace and
/// hairlines. Amber is reserved for what is live or wants a decision.
private enum Surface {
    static let window = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let hairline = Color.white.opacity(0.07)
    static let label = Color.white
    static let secondary = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.3)
    /// Where the text column starts, past the glyph gutter. Rules and rows
    /// align to it.
    static let gutter: CGFloat = 34
}

struct ContentView: View {
    @State private var permissions = PermissionStatus()
    @State private var hoveringKeys = false
    /// The last transcript, echoed back briefly under the keys.
    @State private var recent: String?
    @State private var echoTask: Task<Void, Never>?
    @State private var shortcutRejected = false
    @Environment(PourSessionModel.self) private var session
    @Environment(PourSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            Surface.window.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    hotkey
                    shortcut
                    polish
                    vocabulary
                    setup
                    steps
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 30)
                // Clears the closed header notch hanging above.
                .padding(.top, 58)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            // The window wears the same shape it puts on screen — closed, and
            // holding the lockup. It is a mark, not a second live HUD.
            NotchHeader()
        }
        // The header notch has to hang off the window's top edge the way the
        // real one hangs off the display's, so the content must reach under
        // the (hidden) titlebar rather than start below it.
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.dark)
        // A fixed pane. The column is a single readable measure, so letting
        // the window grow would only add empty margin.
        .frame(width: 500, height: 720)
        // Permissions are granted in System Settings, outside the app, so
        // re-read them whenever Pour comes back to the foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
    }

    // MARK: - Sections

    /// The keys are the control, and the line under them is the only thing
    /// that ever speaks. It carries the prompt, the live state, and then what
    /// you just said — so a finished transcript can never end up sitting on
    /// its own looking like a stray string.
    private var hotkey: some View {
        VStack(spacing: 16) {
            HoldableKeys(
                caps: settings.hotKey.keyCaps,
                isRecording: session.recorder.isRecording,
                onPress: { Task { await session.begin() } },
                onRelease: { Task { await session.end() } },
                onHoverChange: { hoveringKeys = $0 }
            )
            statusLine
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        // Registered on the container, not on the status text: the text is
        // `.id`-ed so it can cross-dissolve, which tears down and rebuilds it
        // on every change — taking any modifier attached to it along.
        .onChange(of: session.recorder.finalTranscription) { _, new in
            echo(new.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .animation(.easeOut(duration: 0.18), value: status.text)
    }

    private var statusLine: some View {
        Text(status.text)
            .font(.system(size: 13))
            .foregroundStyle(status.isEcho ? Surface.faint : Surface.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .textSelection(.enabled)
            .id(status.text)
            .transition(.opacity)
            // Fixed height: the line changes constantly, and the sections
            // below it must not move when it does.
            .frame(height: 36, alignment: .top)
    }

    /// `isEcho` marks the case where the line is quoting the user back to
    /// themselves, which is styled a step quieter than an instruction.
    private var status: (text: String, isEcho: Bool) {
        if session.recorder.isRecording { return ("Listening… let go to finish", false) }
        if let recent { return ("“\(recent)”", true) }
        return (hoveringKeys ? "Hold these to try it" : "Hold anywhere to dictate", false)
    }

    /// Show what was heard, then hand the line back to the prompt.
    private func echo(_ text: String) {
        echoTask?.cancel()
        guard !text.isEmpty else { recent = nil; return }
        recent = text
        echoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            recent = nil
        }
    }

    private var shortcut: some View {
        @Bindable var settings = settings
        return Section("Shortcut") {
            HStack(spacing: 14) {
                Image(systemName: "command")
                    .font(.system(size: 14))
                    .foregroundStyle(Surface.faint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold to dictate")
                        .font(.system(size: 14))
                        .foregroundStyle(Surface.label)
                    Text(shortcutHint)
                        .font(.system(size: 12))
                        .foregroundStyle(shortcutRejected ? PourTheme.accent : Surface.secondary)
                }

                Spacer(minLength: 12)

                ShortcutRecorder(combo: $settings.hotKey) {
                    // A bare key would be captured system-wide; say so rather
                    // than silently ignoring the press.
                    shortcutRejected = true
                }
            }
            .padding(.vertical, 12)
            .onChange(of: settings.hotKey) { _, _ in shortcutRejected = false }
        }
    }

    private var shortcutHint: String {
        shortcutRejected
            ? "Include ⌘, ⌃, ⌥ or ⇧ — a bare key would be captured everywhere"
            : "Click to record a new combination"
    }

    private var polish: some View {
        @Bindable var settings = settings
        let readiness = TranscriptPolisher.readiness
        return Section("Cleanup") {
            ToggleRow(
                symbol: "wand.and.sparkles",
                title: "Tidy up what I said",
                subtitle: readiness.explanation
                    ?? "Punctuation, capitals, and dropped filler words — on-device",
                isOn: $settings.cleanupEnabled,
                enabled: readiness.isReady
            )
            Rule()
            ToggleRow(
                symbol: "app.badge",
                title: "Match the app",
                subtitle: "Casual in chat, formal in mail, untouched in editors",
                isOn: $settings.adaptTone,
                enabled: readiness.isReady && settings.cleanupEnabled
            )
        }
    }

    private var vocabulary: some View {
        Section("Vocabulary") {
            VocabularyEditor(
                terms: settings.vocabulary,
                onAdd: settings.addVocabulary,
                onRemove: settings.removeVocabulary
            )
        }
    }

    private var setup: some View {
        Section("Setup", action: ("Re-check", permissions.refresh)) {
            PermissionRow(
                symbol: "mic",
                title: "Microphone",
                subtitle: "Capture your voice",
                isGranted: permissions.microphone == .authorized,
                grant: permissions.requestMicrophone
            )
            Rule()
            PermissionRow(
                symbol: "keyboard",
                title: "Accessibility",
                subtitle: "Paste into the app you're typing in",
                isGranted: permissions.accessibility,
                grant: permissions.requestAccessibility
            )
        }
    }

    private var steps: some View {
        Section("How it works") {
            StepRow(number: 1, title: "Hold the hotkey",
                    detail: "The notch opens up and starts listening.")
            Rule()
            StepRow(number: 2, title: "Speak naturally",
                    detail: "Transcription runs on-device. Nothing leaves your Mac.")
            Rule()
            StepRow(number: 3, title: "Let go",
                    detail: "The text lands in whatever you were typing in.")
        }
    }

}

// MARK: - Building blocks

/// A quiet label over a stack of rows. No fill, no border, no card — the rows
/// are separated by hairlines and nothing else.
private struct Section<Content: View>: View {
    var title: String
    var action: (label: String, run: () -> Void)?
    @ViewBuilder var content: Content

    init(_ title: String,
         action: (label: String, run: () -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Surface.secondary)
                Spacer()
                if let action {
                    Button(action.label, action: action.run)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Surface.faint)
                }
            }
            VStack(spacing: 0) { content }
        }
    }
}

private struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Surface.hairline)
            .frame(height: 0.5)
            .padding(.leading, Surface.gutter)
    }
}

/// Quiet once granted, amber while it still wants a decision.
private struct PermissionRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var isGranted: Bool
    var grant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isGranted ? Surface.faint : PourTheme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Surface.label)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Surface.secondary)
            }

            Spacer(minLength: 12)

            if isGranted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Surface.faint)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow", action: grant)
                    .buttonStyle(AmberPill())
            }
        }
        .padding(.vertical, 13)
    }
}

private struct ToggleRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    var enabled: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Surface.faint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Surface.label)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Surface.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(PourTheme.accent)
        }
        .padding(.vertical, 12)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
    }
}

private struct StepRow: View {
    var number: Int
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Surface.faint)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Surface.label)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Surface.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }
}

/// The window's own notch: the same silhouette Pour puts on the display,
/// closed, carrying the lockup.
private struct NotchHeader: View {
    private let width: CGFloat = 164
    private let height: CGFloat = 34
    private let shoulder: CGFloat = 13

    var body: some View {
        NotchShape()
            .fill(.black)
            .frame(width: width + shoulder * 2, height: height)
            .overlay {
                HStack(spacing: 8) {
                    PourMark(size: 18)
                    PourWordmark(size: 15, color: .white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The window is draggable by its background, which otherwise swallows a
/// press-and-hold on any control that isn't a real AppKit control — you end up
/// moving the window instead of dictating. This opts a region out.
private struct NotWindowDraggable: NSViewRepresentable {
    final class Blocker: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { Blocker() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keycaps stay physical — they stand for real keys, so the shape carries
/// meaning. Press and hold them and they do what the real keys do.
private struct HoldableKeys: View {
    var caps: [String]
    var isRecording: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    var onHoverChange: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(caps, id: \.self) { cap($0) }
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.18), value: isRecording)
        .background(NotWindowDraggable())
        .contentShape(.rect)
        .onHover(perform: onHoverChange)
        // Push-to-talk needs press *and* release callbacks, which `Button`
        // doesn't give us — a zero-distance drag gesture does.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    onPress()
                }
                .onEnded { _ in
                    isPressed = false
                    onRelease()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Control Space — hold to dictate")
    }

    private func cap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isRecording ? PourTheme.accent : Surface.label)
            .padding(.horizontal, 12)
            .frame(minWidth: 38, minHeight: 32)
            .background(
                (isRecording ? PourTheme.accent.opacity(0.16) : Color.white.opacity(0.07)),
                in: .rect(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isRecording ? PourTheme.accent.opacity(0.5) : Surface.hairline,
                                  lineWidth: 0.5)
            }
    }
}

private struct AmberPill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(PourTheme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: .capsule)
    }
}

#Preview {
    ContentView()
        .environment(PourSessionModel())
}
