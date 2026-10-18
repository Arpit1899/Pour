import Foundation

/// The kinds of app dictation goes into, guessed from the app itself.
/// Browsers land in `other`: Pour can't see which site is open.
enum DictationPlace: String, Codable, CaseIterable {
    case aiPrompts, workChat, email, personal, documents, code, other

    var label: String {
        switch self {
        case .aiPrompts: "AI prompts"
        case .workChat:  "Work chat"
        case .email:     "Email"
        case .personal:  "Personal chat"
        case .documents: "Documents"
        case .code:      "Code"
        case .other:     "Other"
        }
    }

    var symbol: String {
        switch self {
        case .aiPrompts: "sparkles"
        case .workChat:  "bubble.left.and.text.bubble.right"
        case .email:     "envelope"
        case .personal:  "message"
        case .documents: "doc.text"
        case .code:      "chevron.left.forwardslash.chevron.right"
        case .other:     "square.grid.2x2"
        }
    }

    init(bundleID: String?) {
        let id = bundleID?.lowercased() ?? ""
        func has(_ parts: [String]) -> Bool { parts.contains { id.contains($0) } }
        if has(["com.openai.chat", "com.anthropic.claude", "perplexity"]) {
            self = .aiPrompts
        } else if has(["slack", "com.microsoft.teams"]) {
            self = .workChat
        } else if has(["com.apple.mail", "outlook", "superhuman", "spark", "mimestream"]) {
            self = .email
        } else if has(["mobilesms", "whatsapp", "telegram", "discord", "signal"]) {
            self = .personal
        } else if has(["iwork.pages", "microsoft.word", "com.apple.notes", "notion", "obsidian", "craft"]) {
            self = .documents
        } else if has(["xcode", "vscode", "jetbrains", "cursor", "zed", "terminal", "iterm", "ghostty", "warp"]) {
            self = .code
        } else {
            self = .other
        }
    }
}

/// Daily totals for Insights: counts only, never any text, so clearing the
/// recent dictations doesn't reset them. Kept in Application Support on this
/// Mac next to the history.
@MainActor
@Observable
final class DictationStats {
    struct Day: Codable, Equatable {
        var words = 0
        /// Time spent speaking, for words per minute.
        var seconds: Double = 0
        var dictations = 0
        /// Words the cleanup changed, added or dropped.
        var tidied = 0
        /// Dictionary terms that came out spelled your way.
        var dictionaryWords = 0
        var places: [DictationPlace: Int] = [:]
    }

    /// Keyed by local calendar day, "yyyy-MM-dd".
    private(set) var days: [String: Day] = [:]

    private let fileURL: URL?

    init() {
        fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pour", isDirectory: true)
            .appendingPathComponent("stats.json")
        load()
    }

    func record(raw: String, final: String, seconds: Double, bundleID: String?, vocabulary: [String]) {
        let key = Self.key(for: .now)
        var day = days[key] ?? Day()
        day.words += Self.words(in: final).count
        day.seconds += seconds
        day.dictations += 1
        day.tidied += Self.changedWords(from: raw, to: final)
        day.dictionaryWords += Self.dictionaryFixes(vocabulary, raw: raw, final: final)
        day.places[DictationPlace(bundleID: bundleID), default: 0] += 1
        days[key] = day
        save()
    }

    // MARK: - Totals

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalTidied: Int { days.values.reduce(0) { $0 + $1.tidied } }
    var totalDictionaryWords: Int { days.values.reduce(0) { $0 + $1.dictionaryWords } }

    /// Words per minute of speaking, `nil` until there's enough to say.
    var wordsPerMinute: Int? {
        let seconds = days.values.reduce(0) { $0 + $1.seconds }
        guard seconds >= 10 else { return nil }
        return Int((Double(totalWords) / (seconds / 60)).rounded())
    }

    /// A comfortable typing speed, the yardstick for speaking.
    static let typingWordsPerMinute = 40.0

    /// Minutes saved against typing the same words.
    var minutesSaved: Int {
        let seconds = days.values.reduce(0) { $0 + $1.seconds }
        return max(0, Int((Double(totalWords) / Self.typingWordsPerMinute - seconds / 60).rounded()))
    }

    var places: [(place: DictationPlace, count: Int)] {
        var totals: [DictationPlace: Int] = [:]
        for day in days.values {
            for (place, count) in day.places { totals[place, default: 0] += count }
        }
        return DictationPlace.allCases
            .map { (place: $0, count: totals[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    /// Days in a row with at least one dictation, ending today, or
    /// yesterday if today hasn't had one yet.
    var currentStreak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: .now)
        if days[Self.key(for: day)] == nil {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while days[Self.key(for: day)] != nil {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    var longestStreak: Int {
        let calendar = Calendar.current
        let dates = days.keys.compactMap(Self.date(for:)).sorted()
        var longest = 0, run = 0
        var previous: Date?
        for date in dates {
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    func words(on date: Date) -> Int { days[Self.key(for: date)]?.words ?? 0 }

    // MARK: - Counting

    static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    /// How many words differ between what was heard and what was typed:
    /// the longer of the two, less what they share in order.
    static func changedWords(from raw: String, to final: String) -> Int {
        let a = words(in: raw), b = words(in: final)
        guard !a.isEmpty, !b.isEmpty, a != b else { return a == b ? 0 : max(a.count, b.count) }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return max(a.count, b.count) - previous[b.count]
    }

    /// Dictionary terms the cleanup put right: those that appear more often
    /// in what was typed than in what was heard. Terms the recogniser already
    /// got right aren't fixes.
    static func dictionaryFixes(_ terms: [String], raw: String, final: String) -> Int {
        terms.reduce(0) { count, term in
            count + max(0, occurrences(of: [term], in: final) - occurrences(of: [term], in: raw))
        }
    }

    static func occurrences(of terms: [String], in text: String) -> Int {
        terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.reduce(0) { count, term in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { return count }
            return count + regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
    }

    // MARK: - Storage

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { formatter.string(from: date) }
    static func date(for key: String) -> Date? { formatter.date(from: key) }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = decoded
            return
        }
        // Unreadable: keep it to one side rather than overwrite it.
        let aside = fileURL.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: fileURL, to: aside)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(days).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[pour] saving stats failed → \(error)")
        }
    }
}
