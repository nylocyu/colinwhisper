import AVFoundation
import Foundation
import Testing

// MARK: - Glossary

@Test func glossaryRespectsWordBoundaries() {
    let entries = [GlossaryEntry(wrong: "Ei", correct: "E1")]
    #expect(Glossary.apply(entries, to: "Ein Eiweiß und ein Ei.").text == "Ein Eiweiß und ein E1.")
}

@Test func glossaryAppliesLongerEntriesFirst() {
    let entries = [
        GlossaryEntry(wrong: "Peiper", correct: "Paper"),
        GlossaryEntry(wrong: "Peiper less", correct: "Paperless"),
    ]
    #expect(Glossary.apply(entries, to: "Das Peiper less Projekt").text == "Das Paperless Projekt")
}

@Test func glossaryCaseHandlingAndHits() {
    let insensitive = GlossaryEntry(wrong: "eidas", correct: "eIDAS")
    let sensitive = GlossaryEntry(wrong: "QS", correct: "QES", caseSensitive: true)
    let result = Glossary.apply([insensitive, sensitive], to: "Eidas und EIDAS, qs und QS, eIDAS")
    #expect(result.text == "eIDAS und eIDAS, qs und QES, eIDAS")
    #expect(result.hits[insensitive.id] == 2)  // the already-correct "eIDAS" isn't a hit
    #expect(result.hits[sensitive.id] == 1)
}

@Test func dictionaryWordFixesCaseSpacesAndHyphens() {
    let entries = [GlossaryEntry(wrong: "", correct: "QES-Addon"), GlossaryEntry(wrong: "", correct: "Paperless")]
    let result = Glossary.apply(entries, to: "Das qes add-on für paper less, Paperless und Paperlessness")
    #expect(result.text == "Das QES-Addon für Paperless, Paperless und Paperlessness")
    #expect(result.hits[entries[1].id] == 1)
}

@Test func glossaryStoreCountsHitsAndPersists() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "glossary-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = GlossaryStore(url: url)
    store.entries = [GlossaryEntry(wrong: "Peiperless", correct: "Paperless")]
    #expect(store.apply(to: "Peiperless ist gut") == "Paperless ist gut")
    #expect(GlossaryStore(url: url).entries.first?.hitCount == 1)
}

// MARK: - Learning

@Test func candidatesFindRecognitionErrorsOnly() {
    let candidates = Glossary.candidates(
        raw: "ähm wir starten das Peiperless Projekt am Montag drei nein vier Leute",
        corrected: "Wir starten das Paperless Projekt am Montag.\n\n- vier Leute",
        existing: [])
    // Fillers, self-corrections, capitalization and list dashes are not candidates.
    #expect(candidates == [GlossaryCandidate(wrong: "Peiperless", correct: "Paperless")])
}

@Test func candidatesRejectStyleChangesAndKnownEntries() {
    #expect(Glossary.candidates(
        raw: "das ist ein ganz toller Vorschlag finde ich",
        corrected: "Ich halte den Vorschlag für sinnvoll.",
        existing: []).isEmpty)
    #expect(Glossary.candidates(
        raw: "Peiperless läuft", corrected: "Paperless läuft",
        existing: [GlossaryEntry(wrong: "peiperless", correct: "Paperless")]).isEmpty)
}

@Test func candidatesSkipWhatTheDictionaryAlreadyFixes() {
    #expect(Glossary.candidates(
        raw: "Das QES Add-on läuft", corrected: "Das QES-Addon läuft",
        existing: [GlossaryEntry(wrong: "", correct: "QES-Addon")]).isEmpty)
}

@Test func candidatesKeepRealCaseChanges() {
    #expect(Glossary.candidates(raw: "Die Eidas Verordnung", corrected: "Die eIDAS Verordnung", existing: [])
        == [GlossaryCandidate(wrong: "Eidas", correct: "eIDAS")])
}

// MARK: - Formatter guardrails

@Test func plausibilityAcceptsFormatting() {
    let input = "Also ich wollte kurz sagen, dass wir das Paperless-Projekt nächste Woche starten. Neuer Absatz, bitte schick mir drei. Nein, vier Angebote."
    #expect(Formatter.isPlausible(
        "Ich wollte kurz sagen, dass wir das Paperless-Projekt nächste Woche starten.\n\nBitte schick mir vier Angebote.",
        for: input))
    #expect(Formatter.isPlausible(
        "Für morgen brauchen wir:\n- Milch\n- Eier\n- Brot\n- Butter",
        for: "Ähm, für morgen brauchen wir Aufzählung Milch Eier Brot und äh Butter"))
}

@Test func plausibilityRejectsAnswersRewritesAndTruncation() {
    // Real outputs of the on-device model with a weaker prompt.
    #expect(!Formatter.isPlausible("Es ist 14:30 Uhr.", for: "Kannst du mir sagen wie spät es ist"))
    #expect(!Formatter.isPlausible(
        "Das Paperless-Projekt startet nächste Woche. Wir haben vier Angebote.",
        for: "Also ich wollte kurz sagen, dass wir das Paperless-Projekt nächste Woche starten. Neuer Absatz, bitte schick mir drei. Nein, vier Angebote."))
    #expect(!Formatter.isPlausible(
        "Sehr geehrter Herr Müller,\n\nleider muss ich Ihnen mitteilen, dass das geplante Meeting verschoben werden muss. Ich melde mich mit einem neuen Termin.\n\nMit freundlichen Grüßen",
        for: "Schreib mir eine E-Mail an Herrn Müller dass das Meeting verschoben wird"))
    #expect(!Formatter.isPlausible("Good morning", for: "Übersetze das ins Englische: Guten Morgen"))
    // These two slipped through the first version of the guard.
    #expect(!Formatter.isPlausible("Die Hauptstadt von Frankreich ist Paris.", for: "Was ist die Hauptstadt von Frankreich?"))
    #expect(!Formatter.isPlausible(
        "Der Kunde hat angerufen und möchte die Lieferung auf Donnerstag verschieben.",
        for: "Fasse den folgenden Text zusammen. Der Kunde hat angerufen und möchte die Lieferung auf Donnerstag verschieben."))
}

@Test func plausibilityAllowsListConversion() {
    #expect(Formatter.isPlausible(
        "Die Punkte für heute sind:\n- Das Budget\n- Die Personalplanung\n- Der Umzug",
        for: "Die Punkte für heute sind erstens das Budget, zweitens die Personalplanung und drittens der Umzug."))
}

@Test func cleanNormalizesBulletsAndTags() {
    #expect(Formatter.clean("<diktat>Wir brauchen:\n*   Milch\n• Eier</diktat>\n") == "Wir brauchen:\n- Milch\n- Eier")
}

@Test func chunksSplitAtSentencesWithoutLosingText() {
    let text = (1...40).map { "Das ist Satz Nummer \($0)." }.joined(separator: " ")
    let chunks = Formatter.chunks(text, limit: 200)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 200 })
    #expect(chunks.joined(separator: " ") == text)
    #expect(Formatter.chunks("kurz", limit: 200) == ["kurz"])
}

// MARK: - Pipeline fallbacks

private struct FakeTranscriber: Transcribing {
    var text: String
    var error: Error?
    func transcribe(_ buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async throws -> String {
        if let error { throw error }
        return text
    }
}

private struct FakeGlossary: GlossaryProcessing {
    var contextualStrings: [String] { ["Paperless"] }
    var fails = false
    func apply(to text: String) throws -> String {
        if fails { throw CocoaError(.featureUnsupported) }
        return text.replacingOccurrences(of: "Peiperless", with: "Paperless")
    }
}

private struct FakeFormatter: TextFormatting {
    var output: String?
    func format(_ text: String) async throws -> String {
        guard let output else { throw FormatterError.implausible }
        return output
    }
}

@Test func pipelineUsesFormatterOutput() async throws {
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless läuft"),
        glossary: FakeGlossary(), formatter: FakeFormatter(output: "Paperless läuft."))
    #expect(result.formattedText == "Paperless läuft.")
    #expect(!result.usedFallback)
    #expect(result.rawTranscript == "Peiperless läuft")
    #expect(result.correctedTranscript == "Paperless läuft")
}

@Test func pipelineFallsBackToGlossaryTextWhenFormatterFails() async throws {
    for formatter in [FakeFormatter(output: nil), nil] {
        let result = try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless läuft"),
            glossary: FakeGlossary(), formatter: formatter)
        #expect(result.formattedText == "Paperless läuft")
        #expect(result.usedFallback)
    }
}

@Test func pipelineFallsBackToRawWhenGlossaryFails() async throws {
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless"),
        glossary: FakeGlossary(fails: true), formatter: nil)
    #expect(result.correctedTranscript == "Peiperless")
    #expect(result.formattedText == "Peiperless")
}

@Test func pipelineAbortsOnTranscriptionFailureOrSilence() async {
    await #expect(throws: PipelineError.self) {
        try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "", error: CocoaError(.fileReadUnknown)),
            glossary: FakeGlossary(), formatter: nil)
    }
    await #expect(throws: PipelineError.self) {
        try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "  "),
            glossary: FakeGlossary(), formatter: nil)
    }
}

@Test func timeoutDoesNotWaitForUncooperativeWork() async {
    let start = Date()
    await #expect(throws: TimeoutError.self) {
        try await withTimeout(seconds: 0.1) {
            // Ignores cancellation, like a hung model call might.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
            return "late"
        }
    }
    #expect(Date().timeIntervalSince(start) < 1)
}

// MARK: - Automatic learning

private func tempURL() -> URL { FileManager.default.temporaryDirectory.appending(path: "pending-\(UUID()).json") }

@Test func candidateIsPromotedAfterSecondDictation() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let memory = CandidateMemory(url: url)
    let candidate = GlossaryCandidate(wrong: "Peiperless", correct: "Paperless")

    let first = memory.record([candidate], from: UUID())
    #expect(first.promoted.isEmpty)
    #expect(first.remembered == [candidate])

    // A second, independent dictation with the same correction promotes it.
    let second = CandidateMemory(url: url).record([candidate], from: UUID())
    #expect(second.promoted == [candidate])
    #expect(CandidateMemory(url: url).pending.isEmpty)
}

@Test func reapplyingTheSameDictationDoesNotPromote() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let memory = CandidateMemory(url: url)
    let candidate = GlossaryCandidate(wrong: "Peiperless", correct: "Paperless")
    let resultID = UUID()

    _ = memory.record([candidate], from: resultID)
    let again = memory.record([candidate], from: resultID)
    #expect(again.promoted.isEmpty)
    #expect(memory.pending.first?.count == 1)
}

@Test func glossaryStoreIgnoresDuplicateCandidates() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = GlossaryStore(url: url)
    store.add(GlossaryCandidate(wrong: "Peiperless", correct: "Paperless"))
    store.add(GlossaryCandidate(wrong: "peiperless", correct: "Paperless"))
    #expect(store.entries.count == 1)
}

@Test func plausibilityRejectsDroppedGreeting() {
    // Happened in practice: the model answered with the body only.
    #expect(!Formatter.isPlausible("Danke für die Info.", for: "Hi Max, danke für die Info."))
}
