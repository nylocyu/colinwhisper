import AVFoundation
import os

nonisolated let log = Logger(subsystem: "com.colinportisch.ColinWhisper", category: "app")

struct DictationResult: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let rawTranscript: String        // stage 2 — glossary learning diffs against this, never drop it
    let correctedTranscript: String  // stage 3 plus question marks (3b)
    let formattedText: String        // stage 4 (or fallback)
    let usedFallback: Bool
    let duration: TimeInterval       // length of the recorded audio
    var formattedBy: String? = nil   // `TextFormatting.name`; nil with the fallback
}

// MARK: - Stage protocols

protocol Transcribing {
    /// One string per recognized segment, in order. The pipeline joins them.
    func transcribe(_ buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async throws -> [String]
}

protocol GlossaryProcessing {
    var contextualStrings: [String] { get }
    func apply(to text: String) throws -> String
}

protocol TextFormatting: Sendable {
    var name: String { get }
    /// `terms`: glossary spellings the model has to keep exactly.
    func format(_ text: String, terms: [String]) async throws -> String
}

// MARK: - Pipeline

enum PipelineError: LocalizedError {
    case noSpeech
    case transcription(String)

    var errorDescription: String? {
        switch self {
        case .noSpeech: "Keine Sprache erkannt"
        case .transcription(let reason): "Transkription fehlgeschlagen: \(reason)"
        }
    }
}

enum Pipeline {
    /// Stages 2–4. Throws only when transcription fails; later stages fall back instead.
    /// `formatters` are tried in order (Claude with the user's key, then the local model);
    /// when none is left, the stage-3 text is inserted.
    static func run(
        buffers: [AVAudioPCMBuffer],
        duration: TimeInterval,
        transcriber: any Transcribing,
        glossary: any GlossaryProcessing,
        formatters: [any TextFormatting]
    ) async throws -> DictationResult {
        let raw: String
        do {
            raw = join(try await transcriber.transcribe(buffers, contextualStrings: glossary.contextualStrings))
        } catch {
            throw PipelineError.transcription(error.localizedDescription)
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PipelineError.noSpeech }
        log.debug("raw: \(raw, privacy: .private)")

        var corrected = raw
        do {
            corrected = try glossary.apply(to: raw)
        } catch {
            log.error("glossary failed, using raw transcript: \(error.localizedDescription)")
        }
        corrected = Questions.mark(corrected)

        var formatted = corrected
        var formattedBy: String?
        for formatter in formatters {
            do {
                formatted = try await formatter.format(corrected, terms: glossary.contextualStrings)
                formattedBy = formatter.name
                break
            } catch {
                // Offline, guardrails, timeouts, implausible output: all normal fallback cases.
                log.notice("\(formatter.name) failed: \(String(describing: error))")
            }
        }

        return DictationResult(
            id: UUID(), timestamp: Date(), rawTranscript: raw, correctedTranscript: corrected,
            formattedText: formatted, usedFallback: formattedBy == nil, duration: duration, formattedBy: formattedBy)
    }

    /// Stage 2b. SpeechTranscriber delivers one result per segment, and a segment doesn't
    /// always start with a space: plain concatenation glued "Whisper" + "Fällt mir".
    static func join(_ segments: [String]) -> String {
        tidy(segments.joined(separator: " "))
    }

    /// One space between words, none before punctuation, and one after a sentence end that
    /// runs into the next sentence ("aufnehme.Ich"). Two letters before the dot keep
    /// abbreviations like "z.B." and "U.S.A." intact.
    static func tidy(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([.,;:?!])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "(?<=\\p{L}{2}[.?!])(?=\\p{Lu})", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Helpers

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "Zeitüberschreitung" }
}

/// Resolves with whichever comes first. Unlike a task group this doesn't wait for
/// `operation` to honor cancellation, so a hung model call can't stall the pipeline.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
    let gate = Gate()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await operation()
                if gate.open() { continuation.resume(returning: value) }
            } catch {
                if gate.open() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if gate.open() {
                work.cancel()
                continuation.resume(throwing: TimeoutError())
            }
        }
    }
}

private final class Gate {
    private var used = false
    func open() -> Bool {
        defer { used = true }
        return !used
    }
}

enum AppFiles {
    static let directory: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "ColinWhisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for name: String) -> URL { directory.appending(path: name) }
}
