import AVFoundation
import os

nonisolated let log = Logger(subsystem: "com.colinportisch.ColinWhisper", category: "app")

struct DictationResult: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let rawTranscript: String        // stage 2 — glossary learning diffs against this, never drop it
    let correctedTranscript: String  // stage 3
    let formattedText: String        // stage 4 (or fallback)
    let usedFallback: Bool
    let duration: TimeInterval       // length of the recorded audio
}

// MARK: - Stage protocols

protocol Transcribing {
    func transcribe(_ buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async throws -> String
}

protocol GlossaryProcessing {
    var contextualStrings: [String] { get }
    func apply(to text: String) throws -> String
}

protocol TextFormatting: Sendable {
    func format(_ text: String) async throws -> String
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
    /// `formatter == nil` means the LLM is unavailable: permanent fallback mode.
    static func run(
        buffers: [AVAudioPCMBuffer],
        duration: TimeInterval,
        transcriber: any Transcribing,
        glossary: any GlossaryProcessing,
        formatter: (any TextFormatting)?
    ) async throws -> DictationResult {
        let raw: String
        do {
            raw = try await transcriber.transcribe(buffers, contextualStrings: glossary.contextualStrings)
        } catch {
            throw PipelineError.transcription(error.localizedDescription)
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PipelineError.noSpeech }
        log.debug("raw: \(raw, privacy: .private)")

        let corrected: String
        do {
            corrected = try glossary.apply(to: raw)
        } catch {
            log.error("glossary failed, using raw transcript: \(error.localizedDescription)")
            corrected = raw
        }

        var formatted = corrected
        var usedFallback = true
        if let formatter {
            do {
                formatted = try await formatter.format(corrected)
                usedFallback = false
            } catch {
                // Guardrail violations, timeouts, implausible output: all normal fallback cases.
                log.notice("formatter fallback: \(String(describing: error))")
            }
        }

        return DictationResult(
            id: UUID(), timestamp: Date(), rawTranscript: raw, correctedTranscript: corrected,
            formattedText: formatted, usedFallback: usedFallback, duration: duration)
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
