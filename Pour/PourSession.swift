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
    let history = DictationHistory()
    let stats = DictationStats()
    private let polisher = TranscriptPolisher()
    var phase: Phase = .idle

    /// How the session that just ended actually finished. The closing frame
    /// reports this rather than assuming a paste happened.
    private(set) var outcome: PourOutcome = .nothingHeard

    /// The transcript, held on screen because nothing editable had focus.
    private(set) var heldText: String?
    private var holdTask: Task<Void, Never>?
    /// How long the held transcript stays before the bar settles.
    static let holdDuration: Duration = .seconds(8)

    /// A release that arrived before recording had started.
    private var finishWhenReady = false

    /// Hold mode, hands-free: a double tap of the shortcut keeps listening
    /// after the keys come up, until the next press.
    private(set) var isLocked = false
    private var lastPress: Date?
    /// The end of a short tap, held back in case a second tap follows.
    private var pendingRelease: Task<Void, Never>?
    private static let tapLength: TimeInterval = 0.3
    private static let doubleTapGap: Duration = .milliseconds(350)

    /// Installed by `AppDelegate`, which owns the floating panel. Both the
    /// global hotkey and the in-app "Try it" button drive the same path.
    var presentHUD: (() -> Void)?
    var dismissHUD: (() -> Void)?

    enum Phase {
        /// `summoning` and `dismissing` are the two frames where the bar is in
        /// its resting shape — they bookend every session so the open and
        /// close both read as the resting bar itself growing and settling.
        /// `holding` shows the transcript with a Copy button, because there
        /// was nowhere to paste it.
        case idle, summoning, listening, transcribing, polishing, inserting, holding, dismissing, error
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

    /// The shortcut went down. Hold mode starts here; press-once mode starts
    /// or finishes, depending on whether a dictation is already running.
    func shortcutPressed() async {
        if settings.activation == .toggle {
            await toggle()
            return
        }
        let running = phase == .summoning || phase == .listening || phase == .transcribing
        if isLocked {
            if running {
                await end()
                return
            }
            // The locked dictation ended some other way; start afresh.
            isLocked = false
        }
        if let pending = pendingRelease {
            // The second tap of a double tap: keep listening, if there is
            // still something to keep.
            pending.cancel()
            pendingRelease = nil
            if running { isLocked = true }
            return
        }
        lastPress = .now
        await begin()
    }

    func shortcutReleased() async {
        guard settings.activation == .hold, !isLocked else { return }
        // A short tap may be the first half of a double tap, so wait a moment
        // for the second before finishing.
        if let lastPress, Date().timeIntervalSince(lastPress) < Self.tapLength {
            pendingRelease = Task {
                try? await Task.sleep(for: Self.doubleTapGap)
                guard !Task.isCancelled else { return }
                pendingRelease = nil
                await end()
            }
            return
        }
        await end()
    }

    /// Start when idle, finish when listening. Clicking the bar does this in
    /// either mode.
    func toggle() async {
        switch phase {
        case .idle, .holding:           await begin()
        case .listening, .transcribing: await end()
        default:                        break
        }
    }

    /// Start listening, with the bar on screen.
    func begin() async {
        isLocked = false
        // A new dictation replaces a transcript still waiting to be copied.
        if phase == .holding {
            holdTask?.cancel()
            heldText = nil
            phase = .idle
        }
        presentHUD?()
        await start()
    }

    /// Copy the held transcript, say so, and settle.
    func copyHeld() async {
        guard phase == .holding, let text = heldText else { return }
        holdTask?.cancel()
        Pasteboard.copy(text)
        heldText = nil
        outcome = .copied
        phase = .inserting
        try? await Task.sleep(for: .milliseconds(900))
        guard phase == .inserting else { return }
        await collapse()
        dismissHUD?()
    }

    /// Put the held transcript away without copying it.
    func dismissHeld() async {
        guard phase == .holding else { return }
        holdTask?.cancel()
        heldText = nil
        await collapse()
        dismissHUD?()
    }

    /// Finish, paste, and settle the bar.
    func end() async {
        await stop()
        // On the error path an auto-dismiss is already in flight; leave the
        // panel up so the message is actually readable.
        if phase == .idle { dismissHUD?() }
    }

    private func start() async {
        guard phase == .idle else { return }
        finishWhenReady = false
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
            try await recorder.startRecording(vocabulary: settings.vocabulary,
                                              microphoneUID: settings.microphoneUID,
                                              languageID: settings.languageID)
            // A quick release can finish the session while setup is still
            // running; don't drag it back into listening.
            if phase == .listening { phase = .transcribing }
        } catch {
            // Only if nothing else has taken the session over meanwhile.
            guard phase == .listening else { return }
            phase = .error
            autoDismiss(after: 1.6)
            return
        }
        if finishWhenReady {
            finishWhenReady = false
            await end()
        }
    }

    private func stop() async {
        // Released before recording even began: finish as soon as it has.
        if phase == .summoning {
            finishWhenReady = true
            return
        }
        guard phase == .listening || phase == .transcribing else { return }
        isLocked = false
        phase = .polishing

        // stopRecording() waits for the analyzer to drain so the last words
        // aren't lost — that wait is also this phase's natural duration.
        let started = Date()
        await recorder.stopRecording()

        let heard = recorder.finalTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        var final = heard
        let app = NSWorkspace.shared.frontmostApplication

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
            history.add(final, app: app?.localizedName)
            stats.record(raw: heard, final: final, seconds: recorder.recordingDuration,
                         bundleID: app?.bundleIdentifier, vocabulary: settings.vocabulary)
            if TextFocus.current() == .notEditable {
                hold(final)
                return
            }
            outcome = Pasteboard.deliver(final) == .pasted ? .pasted : .copied
        }
        phase = .inserting
        // The text has already landed; this beat is just long enough to read
        // the confirmation before the bar settles.
        try? await Task.sleep(for: .milliseconds(220))
        await collapse()
    }

    /// Nothing editable has focus, so pasting would go nowhere. Show the text
    /// with a Copy button instead, and leave the clipboard alone.
    private func hold(_ text: String) {
        heldText = text
        phase = .holding
        holdTask = Task {
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            // Cleared first, so dismissing doesn't cancel this very task and
            // cut the settle animation short.
            holdTask = nil
            await dismissHeld()
        }
    }

    /// Shrink the bar back to rest, then stand down.
    private func collapse() async {
        isLocked = false
        pendingRelease?.cancel()
        pendingRelease = nil
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
