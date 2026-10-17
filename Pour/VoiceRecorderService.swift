import Foundation
import Speech
import AVFoundation
import CoreMedia

@MainActor
@Observable
final class VoiceRecorderService {
    var isRecording = false
    var transcribedText = ""
    var finalTranscription = ""
    var recordingDuration: TimeInterval = 0
    var audioLevel: Float = 0
    var error: String?
    var isDownloadingModel = false
    var downloadProgress: Double = 0

    /// Words emitted in order, useful for the HUD's word-by-word fade-in.
    var words: [String] = []

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var timer: Timer?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Text the recogniser has committed to. Never revised.
    private var finalizedText = ""
    /// Its current guess at the audio after that. Replaced on every result,
    /// and usually less accurate than what it settles on.
    private var volatileText = ""
    /// True between the start of `startRecording` and the analyzer running,
    /// so a release that lands mid-setup waits instead of being lost.
    private var isStarting = false
    /// A release arrived during setup. Checked before the microphone opens,
    /// so a release during a model download doesn't start a recording.
    private var stopRequested = false

    /// Looked up once and reused, so every press after the first opens the
    /// microphone without waiting on the speech framework.
    private var resolvedLocales: [String?: Locale] = [:]
    private var formats: [String: AVAudioFormat] = [:]
    private var installed: Set<String> = []

    /// How long to keep listening after the key comes up. The last word is
    /// often still being said as you let go.
    private static let tail: Duration = .milliseconds(300)

    func requestPermissions() async -> Bool {
        // Granted already on every press but the first; skip the round trips.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }
        let micAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAllowed = true
        case .notDetermined: micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: micAllowed = false
        }
        let speechAllowed = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        return micAllowed && speechAllowed
    }

    /// The languages the on-device model can transcribe.
    static func availableLanguages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// What "Automatic" resolves to on this Mac.
    static func automaticLanguage() async -> Locale? {
        try? await locale(for: nil)
    }

    /// - Parameter vocabulary: names, acronyms and jargon to bias the
    ///   recogniser toward. A general model mangles proper nouns every single
    ///   time otherwise, so this is the cheapest accuracy win available.
    /// - Parameter microphoneUID: the input to record from, `nil` for the
    ///   system default.
    /// - Parameter languageID: BCP 47 identifier of the language to listen
    ///   for, `nil` to follow the Mac's own language and region.
    func startRecording(vocabulary: [String] = [],
                        microphoneUID: String? = nil,
                        languageID: String? = nil) async throws {
        isStarting = true
        stopRequested = false
        defer { isStarting = false }

        transcribedText = ""
        finalTranscription = ""
        finalizedText = ""
        volatileText = ""
        words = []
        recordingDuration = 0
        error = nil

        let locale: Locale
        if let known = resolvedLocales[languageID] {
            locale = known
        } else {
            locale = try await Self.locale(for: languageID)
            resolvedLocales[languageID] = locale
        }
        let key = locale.identifier(.bcp47)
        let speechTranscriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // A first run in a new language downloads the model before the
        // microphone opens: speech during a download would only be thrown away.
        if !installed.contains(key) {
            try await installModelIfNeeded(for: speechTranscriber, locale: locale)
            installed.insert(key)
        }
        if stopRequested { return }

        let format: AVAudioFormat
        if let known = formats[key] {
            format = known
        } else {
            guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechTranscriber])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)
            else { throw RecordingError.audioEngineCreationFailed }
            format = best
            formats[key] = best
        }

        // Open the microphone before the analyzer. The stream holds the audio
        // until the analyzer is ready for it, so the first word isn't lost to
        // setup time.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try startEngine(microphoneUID: microphoneUID, format: format, into: continuation)

        do {
            let analyzer = SpeechAnalyzer(modules: [speechTranscriber])
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: vocabulary]
                // Best-effort: a rejected context should cost accuracy, not
                // the whole dictation.
                try? await analyzer.setContext(context)
            }

            resultsTask = Task {
                do {
                    for try await result in speechTranscriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            self.finalizedText = Self.join(self.finalizedText, text)
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.transcribedText = Self.join(self.finalizedText, self.volatileText)
                        self.words = self.transcribedText
                            .split(whereSeparator: { $0.isWhitespace })
                            .map(String.init)
                    }
                } catch {
                    if self.transcribedText.isEmpty { self.error = error.localizedDescription }
                }
            }

            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            self.transcriber = speechTranscriber
        } catch {
            stopEngine()
            resultsTask?.cancel()
            resultsTask = nil
            throw error
        }
    }

    func stopRecording() async {
        // A release during setup: let setup finish, then stop as normal.
        if isStarting { stopRequested = true }
        while isStarting { try? await Task.sleep(for: .milliseconds(20)) }
        guard isRecording else { return }

        try? await Task.sleep(for: Self.tail)
        stopEngine()

        // Settle everything heard so far, including the words the recogniser
        // was still unsure about, and wait for those results to arrive. The
        // watchdog keeps a stuck analyzer from holding the paste hostage.
        if let analyzer {
            let results = resultsTask
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(3))
                await analyzer.cancelAndFinishNow()
                results?.cancel()
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = await results?.result
            watchdog.cancel()
        }
        resultsTask = nil

        finalTranscription = Self.join(finalizedText, volatileText)
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Microphone

    private func startEngine(microphoneUID: String?,
                             format: AVAudioFormat,
                             into continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if let microphoneUID {
            AudioInputDevices.select(uid: microphoneUID, on: inputNode)
        }

        // No tap format: the node's own, whatever device it ended up on. A
        // format read right after switching devices can be stale, and a tap
        // whose format disagrees with the hardware crashes the engine. The
        // converter is built from the first buffer that actually arrives.
        let resampler = Resampler(target: format)

        // Small buffers, so stopping drops at most a few milliseconds.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let level = Self.meanLevel(of: buffer)
            Task { @MainActor in self?.audioLevel = level }
            if let converted = resampler.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true

        // `.common` rather than the default mode: a scheduled timer is parked
        // while the run loop is tracking mouse events, which would freeze the
        // duration for the whole time a press-and-hold button is held.
        let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in self?.recordingDuration += 0.1 }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func stopEngine() {
        isRecording = false
        timer?.invalidate(); timer = nil
        audioLevel = 0
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        // End of input: the analyzer can now finish what it has.
        continuation?.finish()
        continuation = nil
    }

    nonisolated private static func meanLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += abs(samples[i]) }
        return sum / Float(buffer.frameLength)
    }


    // MARK: - Language model

    /// The chosen language if the model supports it, otherwise the closest
    /// match to the Mac's own language and region. Matching on language alone
    /// picked whichever English Apple lists first (India), not the user's.
    private static func locale(for languageID: String?) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if let languageID,
           let chosen = supported.first(where: { $0.identifier(.bcp47) == languageID }) {
            return chosen
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return match
        }
        // No exact match for the region: the same language somewhere else
        // still beats switching to English.
        if let sameLanguage = supported.first(where: {
            $0.language.languageCode == Locale.current.language.languageCode
        }) {
            return sameLanguage
        }
        if let english = supported.first(where: { $0.identifier(.bcp47) == "en-US" }) ?? supported.first {
            return english
        }
        throw RecordingError.transcriptionSetupFailed
    }

    private func installModelIfNeeded(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        guard !installed.contains(locale.identifier(.bcp47)) else { return }

        _ = try? await AssetInventory.reserve(locale: locale)
        guard let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }

        isDownloadingModel = true
        downloadProgress = 0
        let progress = downloader.progress
        let progressTask = Task {
            while !progress.isFinished && !Task.isCancelled {
                self.downloadProgress = progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(200))
            }
            self.downloadProgress = 1.0
        }
        defer {
            progressTask.cancel()
            isDownloadingModel = false
        }
        try await downloader.downloadAndInstall()
    }

    /// Glue two runs of text with exactly one space between them.
    private static func join(_ head: String, _ tail: String) -> String {
        let a = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    enum RecordingError: Error, LocalizedError {
        case transcriptionSetupFailed
        case audioEngineCreationFailed
        var errorDescription: String? {
            switch self {
            case .transcriptionSetupFailed: "speech transcription setup failed"
            case .audioEngineCreationFailed: "audio engine setup failed"
            }
        }
    }
}

/// Turns tap buffers into the analyzer's format. Only ever used from the
/// audio thread that delivers the tap.
private final class Resampler: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    /// The converter may ask for input more than once per call. Each buffer
    /// is handed over exactly once and then it is told there is no more for
    /// now; handing the same buffer over again would splice repeated audio
    /// into the stream, which the recogniser hears as garbled words.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
