import Foundation

/// What you've dictated, newest first. Kept in a JSON file in Application
/// Support on this Mac and nowhere else, capped so it can't grow forever.
@MainActor
@Observable
final class DictationHistory {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var date: Date
        var text: String
        /// The app the text was pasted into, if known.
        var app: String?
    }

    private(set) var entries: [Entry] = []

    private static let limit = 200
    private let fileURL: URL?

    init() {
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pour", isDirectory: true)
        fileURL = folder?.appendingPathComponent("history.json")
        load()
    }

    func add(_ text: String, app: String?) {
        entries.insert(Entry(date: .now, text: text, app: app), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
            return
        }
        // Unreadable: keep it to one side rather than overwrite it on the
        // next save.
        let aside = fileURL.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: fileURL, to: aside)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[pour] saving history failed → \(error)")
        }
    }
}
