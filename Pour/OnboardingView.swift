import SwiftUI
import AVFoundation
import Speech
import Combine

/// First run: what Pour is, the two permissions it needs, the shortcut, and
/// one practice dictation. Fills the main window until it's done.
struct OnboardingView: View {
    var permissions: PermissionStatus
    var onFinish: () -> Void

    @Environment(PourSettings.self) private var settings
    @Environment(PourSessionModel.self) private var session
    @State private var step: Int
    @State private var practice = ""
    @State private var speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
    @FocusState private var practiceFocused: Bool

    private static let steps = 4
    /// Permissions are granted in System Settings, so the ticks are polled.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(permissions: PermissionStatus, startStep: Int = 0, onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.onFinish = onFinish
        _step = State(initialValue: startStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                switch step {
                case 0:  welcome
                case 1:  access
                case 2:  shortcut
                default: tryIt
                }
            }
            .frame(maxWidth: 440)
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PourTheme.canvas)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: step)
        .onReceive(tick) { _ in
            guard step == 1 else { return }
            permissions.refresh()
            speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            PourMark(size: 72)
            Text("Talk, and it types.")
                .font(.system(size: 32, design: .serif))
            Text("Hold a shortcut, speak, and let go. Pour types what you said into whatever app you're using. Everything stays on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var microphoneReady: Bool {
        permissions.microphone == .authorized && speechAllowed
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Two permissions",
                    "Pour needs to hear you and to type for you. Nothing you say leaves this Mac.")
            Card {
                PermissionRow(title: "Microphone",
                              subtitle: "To hear you. Speech is turned into text on this Mac.",
                              isGranted: microphoneReady,
                              grant: allowMicrophone)
                Rule()
                PermissionRow(title: "Accessibility",
                              subtitle: "To type into the app you're using. Without it, Pour copies and you paste.",
                              isGranted: permissions.accessibility,
                              grant: permissions.requestAccessibility)
            }
            Text("After you allow Accessibility, macOS may ask to quit and reopen Pour. That's expected.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcut: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 18) {
            heading("Your shortcut", "Use it from any app. Change it here or later in Settings.")
            Card {
                SettingRow(title: "Shortcut", subtitle: "Click to record a new one") {
                    ShortcutRecorder(combo: $settings.hotKey)
                }
                Rule()
                SettingRow(title: "Mode", subtitle: settings.activation.detail) {
                    ModePicker(selection: $settings.activation)
                }
            }
            Text("A small bar above the Dock lights up while you speak. Drag it to either side of the screen if it's in the way.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tryIt: some View {
        let keys = settings.hotKey.displayString
        let how = settings.activation == .hold
            ? "Hold \(keys), say a sentence, and let go."
            : "Press \(keys), say a sentence, and press it again."
        return VStack(alignment: .leading, spacing: 18) {
            heading("Try it", how + " The words land in the box below.")
            TextEditor(text: $practice)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 120)
                .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if practice.isEmpty {
                        Text("Your words land here…")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(15)
                            .allowsHitTesting(false)
                    }
                }
                .focused($practiceFocused)
                .onAppear { practiceFocused = true }
            if !practice.isEmpty {
                Label("That's it. It works the same in any app.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(PourTheme.accent)
            } else if !permissions.accessibility {
                Text("Accessibility isn't allowed yet, so press ⌘V to paste what Pour copies.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pieces

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, design: .serif))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step -= 1 }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(step == 0 ? 0 : 1)
                .disabled(step == 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? PourTheme.accent : Color.primary.opacity(0.15))
                        .frame(width: index == step ? 16 : 6, height: 6)
                }
            }
            Spacer()
            Button(primaryLabel, action: advance)
                .buttonStyle(AmberPill())
        }
        .frame(maxWidth: 440)
    }

    private var primaryLabel: String {
        switch step {
        case 0: "Get started"
        case 1: microphoneReady && permissions.accessibility ? "Continue" : "Skip for now"
        case Self.steps - 1: "Done"
        default: "Continue"
        }
    }

    private func advance() {
        if step < Self.steps - 1 { step += 1 } else { onFinish() }
    }

    /// Asks for the microphone and speech recognition together the first
    /// time; once either has been refused, only System Settings can change it.
    private func allowMicrophone() {
        let undecided = permissions.microphone == .notDetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        guard undecided else {
            if permissions.microphone == .authorized,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                // The microphone is fine; it is speech recognition that was refused.
                NSWorkspace.shared.open(url)
            } else {
                permissions.requestMicrophone()
            }
            return
        }
        Task {
            _ = await session.recorder.requestPermissions()
            permissions.refresh()
            speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }
}
