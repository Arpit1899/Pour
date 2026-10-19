import AppKit
import Security

/// Updates Pour from its GitHub Releases. Nothing runs in the background:
/// Settings asks when it opens, at most once an hour, and the download only
/// starts when you press Update. Each release carries `Pour.zip`, the app
/// zipped with `ditto -c -k --keepParent`, and is tagged with its version,
/// e.g. `v1.1`.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(version: String, progress: Double)
        case installing(version: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private static let latestRelease = URL(string: "https://api.github.com/repos/Arpit1899/Pour/releases/latest")!
    private var download: URL?
    private var lastChecked: Date?
    private var progressObservation: NSKeyValueObservation?

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        var tag_name: String
        var assets: [Asset]
    }

    func checkIfDue() {
        switch state {
        case .checking, .available, .downloading, .installing: return
        case .idle, .upToDate, .failed: break
        }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 3600 { return }
        Task { await check() }
    }

    func check() async {
        state = .checking
        lastChecked = Date()
        do {
            var request = URLRequest(url: Self.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            // GitHub answers 404 until the first release is published.
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: break
            case 404:
                state = .upToDate
                return
            default:
                // Most likely GitHub's limit of 60 unsigned requests an hour.
                state = .failed("GitHub didn't answer. Try again in a while")
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = String(release.tag_name.trimmingPrefix("v"))
            guard version.compare(currentVersion, options: .numeric) == .orderedDescending,
                  let asset = release.assets.first(where: { $0.name == "Pour.zip" })
            else {
                state = .upToDate
                return
            }
            download = asset.browser_download_url
            state = .available(version: version)
        } catch {
            state = .failed("Couldn't reach GitHub to check for updates")
        }
    }

    func install() async {
        guard case .available(let version) = state, let download else { return }
        let app = Bundle.main.bundleURL
        state = .downloading(version: version, progress: 0)
        do {
            let zip = try await fetch(download, version: version)
            defer { try? FileManager.default.removeItem(at: zip) }
            state = .installing(version: version)
            try await Task.detached { try Self.replace(app, withAppIn: zip) }.value
            relaunch(app)
        } catch let error as UpdateError {
            state = .failed(error.message)
        } catch {
            state = .failed("The update didn't download. Try again")
        }
    }

    private func fetch(_ url: URL, version: String) async throws -> URL {
        let zip = FileManager.default.temporaryDirectory.appending(path: "Pour-\(UUID().uuidString).zip")
        defer {
            progressObservation?.invalidate()
            progressObservation = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { @Sendable file, response, error in
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: error ?? URLError(.badServerResponse))
                    return
                }
                // URLSession deletes the file as soon as this returns.
                do {
                    try FileManager.default.moveItem(at: file, to: zip)
                    continuation.resume(returning: zip)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { @Sendable progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard case .downloading = Updater.shared.state else { return }
                    Updater.shared.state = .downloading(version: version, progress: fraction)
                }
            }
            task.resume()
        }
    }

    /// Unzips the download beside the installed app, checks it is signed the
    /// same way, and swaps it in. The same signature is also what keeps the
    /// Microphone and Accessibility permissions across the update.
    nonisolated private static func replace(_ app: URL, withAppIn zip: URL) throws {
        let files = FileManager.default
        guard !app.path.contains("/AppTranslocation/"),
              files.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { throw UpdateError("Move Pour to your Applications folder to update it") }

        // On the same volume as the app, so the swap is a rename.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: app, create: true)
        defer { try? files.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let new = try files.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("The update was damaged, so it wasn't installed") }

        guard isSigned(new, like: app) else {
            throw UpdateError("The update isn't signed the same way as this copy of Pour, so it wasn't installed")
        }
        do {
            _ = try files.replaceItemAt(app, withItemAt: new)
        } catch {
            throw UpdateError("Pour couldn't replace itself. Download the new version from GitHub")
        }
    }

    /// The new build has to meet the installed app's own designated
    /// requirement: same bundle id, same developer certificate.
    nonisolated private static func isSigned(_ new: URL, like installed: URL) -> Bool {
        var installedCode: SecStaticCode?
        var newCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(new as CFURL, [], &newCode) == errSecSuccess,
              let newCode
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess
    }

    /// Quits, and a small shell waits for this process to be gone before
    /// opening the new build, so two copies never hold the shortcut at once.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }
}

private struct UpdateError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
