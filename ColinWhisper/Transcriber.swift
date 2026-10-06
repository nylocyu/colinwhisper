import AVFoundation
import Speech

/// Stage 2: batch transcription with SpeechAnalyzer + SpeechTranscriber (de-DE).
///
/// Deviations from the spec, verified against the macOS 26.5 SDK:
/// - SpeechTranscriber has no punctuation option; it always punctuates.
///   (DictationTranscriber has `.punctuation`, but in a side-by-side test it dropped
///   words in German, so SpeechTranscriber is used.)
/// - contextualStrings live on `AnalysisContext` and are set via `analyzer.setContext`.
///   They are passed as specified, but in tests neither transcriber changed its output
///   because of them — the glossary (stage 3) does the real work.
@Observable
final class Transcriber: Transcribing {
    enum Status: Equatable {
        case checking
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var status: Status = .checking

    /// The format the analyzer wants; AudioCapture converts to it while recording.
    @ObservationIgnored private(set) var audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

    @ObservationIgnored private let locale = Locale(identifier: "de-DE")
    // Keep the model loaded for the app's lifetime: no load delay per dictation.
    private static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    private func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// Checks model availability, downloads the German model if needed and preloads it.
    func prepare() async {
        status = .checking
        guard SpeechTranscriber.isAvailable else {
            status = .failed("Spracherkennung auf diesem Mac nicht verfügbar")
            return
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            status = .failed("Deutsch wird nicht unterstützt")
            return
        }
        let module = makeModule()
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                status = .downloading(0)
                let progress = Task {
                    while !Task.isCancelled {
                        status = .downloading(request.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                defer { progress.cancel() }
                try await request.downloadAndInstall()
            }
            if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) {
                audioFormat = format
            }
            let analyzer = SpeechAnalyzer(modules: [module], options: Self.options)
            try await analyzer.prepareToAnalyze(in: audioFormat)
            status = .ready
            log.info("transcriber ready, format \(self.audioFormat)")
        } catch {
            status = .failed(error.localizedDescription)
            log.error("transcriber prepare failed: \(error.localizedDescription)")
        }
    }

    func transcribe(_ buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async throws -> String {
        let module = makeModule()
        // Grab the (Sendable) results sequence before the module is handed to the analyzer.
        let results = module.results
        let collector = Task {
            var text = ""
            for try await result in results { text += String(result.text.characters) }
            return text
        }

        let analyzer = SpeechAnalyzer(modules: [module], options: Self.options)
        do {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
            continuation.finish()

            if let end = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
