import SwiftUI
import AVFoundation
import ApplicationServices

/// Bridges the recorder to the HUD: owns the phase machine, and hands the
/// finished transcript to the focused app.
@MainActor
@Observable
final class PourSessionModel {
    let recorder = VoiceRecorderService()
    let settings = PourSettings.shared
    private let polisher = TranscriptPolisher()
    var phase: Phase = .idle

    /// Re-measured against the active display each time the HUD is shown.
    var notch: NotchGeometry = .synthetic

    /// How the session that just ended actually finished. The closing frame
    /// reports this rather than assuming a paste happened.
    private(set) var outcome: PourOutcome = .nothingHeard

    /// Installed by `AppDelegate`, which owns the floating panel. Both the
    /// global hotkey and the in-app "Try it" button drive the same path.
    var presentHUD: (() -> Void)?
    var dismissHUD: (() -> Void)?

    enum Phase {
        /// `summoning` and `dismissing` are the two frames where the shape is
        /// flush with the hardware notch — they bookend every session so the
        /// open and close both read as the notch itself moving.
        case idle, summoning, listening, transcribing, polishing, inserting, dismissing, error
    }

    var hudState: PourState {
        switch phase {
        case .transcribing:            .transcribing
        case .polishing:               .polishing
        case .inserting, .dismissing:  .inserting
        case .error:                   .error
        default:                       .listening
        }
    }

    var isVisible: Bool { phase != .idle }

    var isExpanded: Bool {
        switch phase {
        case .idle, .summoning, .dismissing: false
        default: true
        }
    }

    /// Load the model ahead of first use so the first dictation isn't slower
    /// than every one after it.
    func prewarm() {
        guard settings.cleanupEnabled else { return }
        polisher.prewarm()
    }

    /// Start listening, with the notch on screen.
    func begin() async {
        presentHUD?()
        await start()
    }

    /// Finish, paste, and close the notch.
    func end() async {
        await stop()
        // On the error path an auto-dismiss is already in flight; leave the
        // panel up so the message is actually readable.
        if phase == .idle { dismissHUD?() }
    }

    private func start() async {
        guard phase == .idle else { return }
        phase = .summoning

        // Yield one frame so SwiftUI renders the entering state before the
        // spring settles it into place.
        await Task.yield()

        guard await recorder.requestPermissions() else {
            phase = .error
            autoDismiss(after: 1.6)
            return
        }

        phase = .listening
        do {
            try await recorder.startRecording(vocabulary: settings.vocabulary)
            phase = .transcribing
        } catch {
            phase = .error
            autoDismiss(after: 1.6)
        }
    }

    private func stop() async {
        guard phase == .listening || phase == .transcribing else { return }
        phase = .polishing

        // stopRecording() waits for the analyzer to drain so the last words
        // aren't lost — that wait is also this phase's natural duration.
        let started = Date()
        await recorder.stopRecording()

        var final = recorder.finalTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

        // The phase is named for this. Fails open — `polish` returns the input
        // unchanged on any error, unavailability or timeout.
        if settings.cleanupEnabled, !final.isEmpty {
            let tone: ToneProfile = settings.adaptTone ? .forFrontmostApp() : .neutral
            final = await polisher.polish(final, tone: tone)
        }

        // Floor the phase at ~300ms so the state change stays legible even
        // when both the analyzer and the model finish instantly.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 0.3 {
            try? await Task.sleep(for: .milliseconds(Int((0.3 - elapsed) * 1000)))
        }
        if final.isEmpty {
            outcome = .nothingHeard
        } else {
            outcome = Pasteboard.deliver(final) == .pasted ? .pasted : .copied
        }
        phase = .inserting
        // The text has already landed; this beat is just long enough to read
        // the confirmation before the notch closes.
        try? await Task.sleep(for: .milliseconds(220))
        await collapse()
    }

    /// Pull the shape back onto the hardware notch, then stand down.
    private func collapse() async {
        phase = .dismissing
        try? await Task.sleep(for: .milliseconds(320))
        phase = .idle
    }

    private func autoDismiss(after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            await collapse()
            dismissHUD?()
        }
    }
}

/// Read-only view of the two system permissions Pour depends on.
@MainActor
@Observable
final class PermissionStatus {
    var microphone: AVAuthorizationStatus = .notDetermined
    var accessibility = false

    var allGranted: Bool { microphone == .authorized && accessibility }

    init() { refresh() }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
    }

    func requestMicrophone() {
        guard microphone == .notDetermined else {
            openSettings("Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// Triggers the system prompt and registers Pour in System Settings →
    /// Privacy & Security → Accessibility. macOS may quit the app once the
    /// toggle flips; relaunching picks up the new grant.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
