import SwiftUI
import AppKit
import AVFoundation

// MARK: - Home

/// Try the shortcut, and see what you've said lately.
struct HomePage: View {
    @Environment(PourSessionModel.self) private var session
    @Environment(PourSettings.self) private var settings
    @State private var hoveringKeys = false
    @State private var confirmingClear = false

    var body: some View {
        PageScaffold(title: greeting) {
            HStack(alignment: .top, spacing: 12) {
                tryIt
                StatsGlance(stats: session.stats)
            }
            .fixedSize(horizontal: false, vertical: true)
            recent
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12:  "Good morning"
        case 12..<17: "Good afternoon"
        default:      "Good evening"
        }
    }

    private var tryIt: some View {
        Card {
            VStack(spacing: 14) {
                HoldableKeys(
                    caps: settings.hotKey.keyCaps,
                    isRecording: session.recorder.isRecording,
                    onPress: { Task { await session.shortcutPressed() } },
                    onRelease: { Task { await session.shortcutReleased() } },
                    onHoverChange: { hoveringKeys = $0 }
                )
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .id(status)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: status)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    private var status: String {
        let holding = settings.activation == .hold
        if session.recorder.isRecording {
            return holding ? "Listening… let go to finish" : "Listening… press again to finish"
        }
        if hoveringKeys { return holding ? "Hold these to try it" : "Press these to try it" }
        return holding ? "Hold anywhere and speak. Let go and it's typed."
                       : "Press anywhere and speak. Press again and it's typed."
    }

    @ViewBuilder
    private var recent: some View {
        let entries = session.history.entries
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !entries.isEmpty {
                    Button("Clear") { confirmingClear = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if entries.isEmpty {
                Card {
                    VStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text("Your dictations show up here")
                            .font(.system(size: 13, weight: .medium))
                        Text("They're kept on this Mac only.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(days(entries), id: \.day) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(label(for: group.day))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            Card {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Rule() }
                                    HistoryRow(entry: entry) { session.history.remove(entry) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clear your recent dictations?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { session.history.clear() }
        } message: {
            Text("This removes them from this Mac and can't be undone.")
        }
    }

    private func days(_ entries: [DictationHistory.Entry]) -> [(day: Date, entries: [DictationHistory.Entry])] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, entries: $0.value) }
    }

    private func label(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct HistoryRow: View {
    var entry: DictationHistory.Entry
    var remove: () -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let app = entry.app {
                    Text(app)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 76, alignment: .leading)

            Text(entry.text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Delete", role: .destructive, action: remove)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @Environment(PourSettings.self) private var settings

    var body: some View {
        PageScaffold(title: "Dictionary",
                     subtitle: "Names, acronyms and jargon Pour should spell your way. When it hears something close, it leans toward these.") {
            Card {
                VocabularyEditor(
                    terms: settings.vocabulary,
                    onAdd: settings.addVocabulary,
                    onRemove: settings.removeVocabulary
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Style

struct StylePage: View {
    @Environment(PourSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let readiness = TranscriptPolisher.readiness
        let matching = readiness.isReady && settings.cleanupEnabled && settings.adaptTone

        return PageScaffold(title: "Style",
                            subtitle: "Pour can tidy up what you said before it types it. It all runs on this Mac.") {
            Card {
                ToggleRow(
                    title: "Tidy up what I said",
                    subtitle: readiness.explanation
                        ?? "Punctuation, capitals and dropped filler words",
                    isOn: $settings.cleanupEnabled,
                    enabled: readiness.isReady
                )
                Rule()
                ToggleRow(
                    title: "Match the app",
                    subtitle: "Casual in chat, formal in mail, left alone in code",
                    isOn: $settings.adaptTone,
                    enabled: readiness.isReady && settings.cleanupEnabled
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("How the same words read")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ToneSample(symbol: "message", where: "Chat", tone: "Casual",
                               text: "sounds good, see you at 12")
                    ToneSample(symbol: "envelope", where: "Mail", tone: "Formal",
                               text: "Sounds good. See you at 12.")
                    ToneSample(symbol: "chevron.left.forwardslash.chevron.right",
                               where: "Code", tone: "As said",
                               text: "sounds good see you at 12")
                }
            }
            .opacity(matching ? 1 : 0.45)
            .animation(.easeOut(duration: 0.2), value: matching)
        }
    }
}

private struct ToneSample: View {
    var symbol: String
    var `where`: String
    var tone: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(`where`)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(tone)
                .font(.system(size: 13, weight: .medium))
            Text(text)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PourTheme.control, in: .rect(cornerRadius: 10, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PourTheme.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Settings

struct SettingsPage: View {
    var permissions: PermissionStatus

    @Environment(PourSettings.self) private var settings
    @State private var shortcutRejected = false
    @State private var microphones: [AudioInputDevice] = []
    @State private var defaultMicrophone: String?
    @State private var languages: [Locale] = []
    @State private var automaticLanguage: Locale?
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginItem = LoginItem()
    @State private var updater = Updater.shared

    var body: some View {
        @Bindable var settings = settings

        return PageScaffold(title: "Settings") {
            CardSection("Dictation") {
                SettingRow(title: "Shortcut",
                           subtitle: shortcutHint,
                           subtitleColor: shortcutRejected ? PourTheme.accent : .secondary) {
                    ShortcutRecorder(combo: $settings.hotKey) {
                        // A bare key would be captured system-wide; say so
                        // rather than silently ignoring the press.
                        shortcutRejected = true
                    }
                }
                .onChange(of: settings.hotKey) { _, _ in shortcutRejected = false }
                Rule()
                SettingRow(title: "Mode", subtitle: settings.activation.detail) {
                    ModePicker(selection: $settings.activation)
                }
                Rule()
                SettingRow(title: "Microphone", subtitle: "Used for every dictation") {
                    Picker("Microphone", selection: $settings.microphoneUID) {
                        Text(defaultMicrophone.map { "System default (\($0))" } ?? "System default")
                            .tag(String?.none)
                        ForEach(microphones) { Text($0.name).tag(Optional($0.uid)) }
                        if let uid = settings.microphoneUID,
                           !microphones.contains(where: { $0.uid == uid }) {
                            Text("Disconnected microphone").tag(Optional(uid))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                }
                Rule()
                SettingRow(title: "Language", subtitle: "The language and accent you speak in") {
                    Picker("Language", selection: $settings.languageID) {
                        Text(automaticLanguage.map { "Automatic (\(name(of: $0)))" } ?? "Automatic")
                            .tag(String?.none)
                        ForEach(languages, id: \.self) { locale in
                            Text(name(of: locale)).tag(Optional(locale.identifier(.bcp47)))
                        }
                        if let id = settings.languageID,
                           !languages.contains(where: { $0.identifier(.bcp47) == id }) {
                            Text(languages.isEmpty ? name(of: Locale(identifier: id)) : "Unavailable language")
                                .tag(Optional(id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230)
                }
            }

            CardSection("App") {
                SettingRow(title: "Launch at login",
                           subtitle: loginItem.needsApproval
                               ? "Waiting for you to allow Pour in System Settings → Login Items"
                               : nil) {
                    HStack(spacing: 10) {
                        if loginItem.needsApproval {
                            Button("Open", action: loginItem.openSystemSettings)
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(PourTheme.accent)
                        }
                        Toggle("", isOn: Binding(
                            get: { loginItem.isEnabled || loginItem.needsApproval },
                            set: { loginItem.set($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(PourTheme.accent)
                    }
                }
                Rule()
                SettingRow(title: "Welcome tour", subtitle: "Walk through setup and the shortcut again") {
                    Button("Show") { settings.hasOnboarded = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PourTheme.accent)
                }
                Rule()
                ToggleRow(title: "Show the bar at all times",
                          subtitle: "Click it to dictate. Drag it to the bottom or either side.",
                          isOn: $settings.showBarAlways)
                Rule()
                ToggleRow(title: "Show in Dock",
                          subtitle: "When off, Pour lives in the menu bar",
                          isOn: $settings.showInDock)
                Rule()
                UpdateRow(updater: updater)
            }

            CardSection("Permissions", action: ("Re-check", permissions.refresh)) {
                PermissionRow(title: "Microphone",
                              subtitle: "To hear you",
                              isGranted: permissions.microphone == .authorized,
                              grant: permissions.requestMicrophone)
                Rule()
                PermissionRow(title: "Accessibility",
                              subtitle: "To type into the app you're using",
                              isGranted: permissions.accessibility,
                              grant: permissions.requestAccessibility)
            }

            Text("Pour \(version). Speech is transcribed on this Mac and never leaves it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .onAppear(perform: refresh)
        // Login Items approval and new microphones both happen outside Pour.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        .task {
            languages = await VoiceRecorderService.availableLanguages()
                .sorted { name(of: $0) < name(of: $1) }
            automaticLanguage = await VoiceRecorderService.automaticLanguage()
        }
    }

    private func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier(.bcp47)
    }

    private var shortcutHint: String {
        shortcutRejected
            ? "Include ⌘, ⌃, ⌥ or ⇧. A bare key would be captured everywhere."
            : "Click to record a new combination"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func refresh() {
        microphones = AudioInputDevices.all()
        defaultMicrophone = AudioInputDevices.defaultInput?.name
        loginItem.refresh()
        updater.checkIfDue()
    }
}

/// Checks GitHub when Settings opens; Update downloads, swaps and relaunches.
private struct UpdateRow: View {
    var updater: Updater

    var body: some View {
        SettingRow(title: "Updates", subtitle: subtitle,
                   subtitleColor: isFailed ? PourTheme.accent : .secondary) {
            switch updater.state {
            case .idle, .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                link("Check") { await updater.check() }
            case .available:
                Button("Update") { Task { await updater.install() } }
                    .buttonStyle(AmberPill())
            case .downloading(_, let progress):
                ProgressView(value: progress)
                    .tint(PourTheme.accent)
                    .frame(width: 80)
            case .installing:
                ProgressView().controlSize(.small)
            case .failed:
                link("Try again") { await updater.check() }
            }
        }
    }

    private var subtitle: String {
        let current = updater.currentVersion
        switch updater.state {
        case .idle, .checking:          return "Pour \(current), checking for updates…"
        case .upToDate:                 return "Pour \(current) is the latest"
        case .available(let version):   return "Pour \(version) is out. You have \(current)"
        case .downloading(let version, _): return "Downloading Pour \(version)…"
        case .installing:               return "Restarting Pour…"
        case .failed(let message):      return message
        }
    }

    private var isFailed: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private func link(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PourTheme.accent)
    }
}

/// Hold or press once. Drawn here rather than as a system segmented control,
/// which insists on the system accent and fights the amber.
struct ModePicker: View {
    @Binding var selection: ActivationMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ActivationMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button { selection = mode } label: {
                    Text(mode.label)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(isSelected ? PourTheme.control : .clear,
                                    in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}
