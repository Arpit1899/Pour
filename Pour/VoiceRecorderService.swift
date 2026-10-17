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
    private var bestTranscription = ""
    private var segmentResults: [Double: String] = [:]

    func requestPermissions() async -> Bool {
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

    /// - Parameter vocabulary: names, acronyms and jargon to bias the
    ///   recogniser toward. A general model mangles proper nouns every single
    ///   time otherwise, so this is the cheapest accuracy win available.
    func startRecording(vocabulary: [String] = []) async throws {
        transcribedText = ""
        finalTranscription = ""
        bestTranscription = ""
        segmentResults = [:]
        words = []
        recordingDuration = 0
        error = nil

        let supportedLocales = await SpeechTranscriber.supportedLocales
        let currentLang = Locale.current.language.languageCode
        let locale: Locale
        if let exact = supportedLocales.first(where: { $0.language.languageCode == currentLang }) {
            locale = exact
        } else if let english = supportedLocales.first(where: { $0.language.languageCode?.identifier == "en" }) {
            locale = english
        } else if let first = supportedLocales.first {
            locale = first
        } else {
            throw RecordingError.transcriptionSetupFailed
        }

        let speechTranscriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let installedLocales = await Set(SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let alreadyInstalled = installedLocales.contains(locale.identifier(.bcp47))

        if !alreadyInstalled {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [speechTranscriber]) {
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
                try await downloader.downloadAndInstall()
                progressTask.cancel()
                isDownloadingModel = false
            }
        }

        self.transcriber = speechTranscriber

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [speechTranscriber])

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            // Best-effort: a rejected context should cost accuracy, not the
            // whole dictation.
            try? await analyzer?.setContext(context)
        }

        audioEngine = AVAudioEngine()
        guard let audioEngine else { throw RecordingError.audioEngineCreationFailed }
        let inputNode = audioEngine.inputNode

        let nativeFormat = inputNode.outputFormat(forBus: 0)

        let targetSampleRate: Double = 16000
        guard let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ) else { throw RecordingError.audioEngineCreationFailed }

        guard let converter = AVAudioConverter(from: nativeFormat, to: int16Format) else {
            throw RecordingError.audioEngineCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            let frames = buffer.frameLength
            let channelData = buffer.floatChannelData?[0]
            var sum: Float = 0
            for i in 0..<Int(frames) { sum += abs(channelData?[i] ?? 0) }
            let avg = sum / Float(frames)
            Task { @MainActor in self?.audioLevel = avg }

            let ratio = targetSampleRate / nativeFormat.sampleRate
            let convertedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let int16Buffer = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: convertedFrames) else { return }

            var conversionError: NSError?
            let status = converter.convert(to: int16Buffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status != .error, conversionError == nil {
                self?.continuation?.yield(AnalyzerInput(buffer: int16Buffer))
            }
        }

        resultsTask = Task {
            do {
                for try await result in speechTranscriber.results {
                    let text = String(result.text.characters)
                    let startTime = (result.range.start.seconds * 10).rounded() / 10
                    self.segmentResults[startTime] = text

                    let segments = self.segmentResults
                        .sorted { $0.key < $1.key }
                        .map { $0.value }

                    var deduped: [String] = []
                    for segment in segments where segment != deduped.last {
                        deduped.append(segment)
                    }
                    let fullText = deduped.joined(separator: " ")
                    self.transcribedText = fullText
                    if fullText.count > self.bestTranscription.count {
                        self.bestTranscription = fullText
                    }

                    self.words = fullText
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                }
            } catch {
                if self.transcribedText.isEmpty { self.error = error.localizedDescription }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
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

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false

        timer?.invalidate(); timer = nil
        audioLevel = 0

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Signal end of input — analyzer will flush its remaining buffered
        // audio and emit any final results.
        continuation?.finish()
        continuation = nil

        // Wait for the results stream to drain naturally. SpeechTranscriber's
        // results AsyncSequence completes once the input stream is closed
        // *and* all buffered audio has been processed — so awaiting the task
        // value is what guarantees we capture the last 1-2 words. A short
        // timeout protects against the rare case where the stream never
        // closes cleanly.
        if let task = resultsTask {
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                task.cancel()
            }
            _ = await task.result
            timeout.cancel()
        }
        resultsTask = nil

        finalTranscription = bestTranscription.isEmpty ? transcribedText : bestTranscription
        analyzer = nil
        transcriber = nil
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
