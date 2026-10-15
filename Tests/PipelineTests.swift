import AVFoundation
import Foundation
import Testing

// MARK: - Tester fixture (Fixture.testerFeedback)

private let fixtureJoined = "guten Morgen Colin, wie besprochen hier mein kurzes Feedback zu Colin Whisper, welches ich mit Colin Wis.per aufnehme. Ich finde die Lösung sehr gut und sehr angenehm im direkten Vergleich mit dem US. Whisper Fällt mir lediglich auf, dass das US Whisper teilweise den Nicht Satzbau, sondern die Art und Weise. Zeilenumbrüche, Bullet Points automatisch gesetzte Fragezeichen umsetzt beziehungsweise. besser umsetzt beziehungsweise Colin Whisper Zeilenumbrüche und Bullet Points nicht macht. Das ist tatsächlich das einzige Feedback. Ich habe das Update Deployed Läuft einwandfrei und smooth as Fuck. MFG Louis W."

@Test func segmentsAreJoinedWithSingleSpaces() {
    #expect(Fixture.testerFeedbackSegments.joined() == Fixture.testerFeedback)  // the 1.3 bug
    #expect(Pipeline.join(Fixture.testerFeedbackSegments) == fixtureJoined)
    #expect(Pipeline.join(["Hallo", " Welt.", "  ", "Bis dann"]) == "Hallo Welt. Bis dann")
}

@Test func tidyFixesSpacingDeterministically() {
    // Glued sentences in one segment, as in the fixture's "aufnehme.Ich" and "Fuck.MFG".
    #expect(Pipeline.tidy("aufnehme.Ich finde. Ist das so?Ja!Gut") == "aufnehme. Ich finde. Ist das so? Ja! Gut")
    #expect(Pipeline.tidy(" Hallo  Max , wie geht's ?  Gut . ") == "Hallo Max, wie geht's? Gut.")
    // Abbreviations, lowercase continuations and names with dots stay.
    for text in ["z.B. Montag", "die U.S.A. und e.V.", "beziehungsweise. besser", "Wis.per", "Version 2.0", "ColinWhisper.app"] {
        #expect(Pipeline.tidy(text) == text)
    }
}

@Test func pipelineJoinsAndTidiesTheTranscript() async throws {
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: Fixture.testerFeedback),
        glossary: FakeGlossary(), formatters: [])
    #expect(result.rawTranscript.contains("aufnehme. Ich"))
    #expect(result.rawTranscript.hasSuffix("Fuck. MFG Louis W."))
}

@Test func builtInGlossaryFixesTheFixtureNames() {
    let text = Glossary.apply(Glossary.builtIn, to: fixtureJoined).text
    #expect(text.contains("Feedback zu Colin Whisper, welches ich mit Colin Whisper aufnehme."))
    #expect(text.contains("im direkten Vergleich mit dem Wispr Flow Fällt"))
    #expect(text.contains("dass das Wispr Flow teilweise"))
    #expect(!text.contains("Wis.per") && !text.contains("US"))
}

@Test func builtInGlossaryCoversKnownMisspellings() {
    let entries = Glossary.builtIn
    #expect(Glossary.apply(entries, to: "mit Wis.per und Whisperflow, Whisper Flow, US Whisper").text
        == "mit Wispr Flow und Wispr Flow, Wispr Flow, Wispr Flow")
    #expect(Glossary.apply(entries, to: "Colin Visper und colin whisper").text == "Colin Whisper und Colin Whisper")
    // OpenAI's Whisper alone stays.
    #expect(Glossary.apply(entries, to: "Whisper von OpenAI").text == "Whisper von OpenAI")
    #expect(Glossary.apply(entries, to: "mit einem API K mache").text == "mit einem API-Key mache")
}

@Test func glossaryStoreAddsBuiltInsToUserEntries() {
    let url = FileManager.default.temporaryDirectory.appending(path: "glossary-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = GlossaryStore(url: url)
    store.entries = [GlossaryEntry(wrong: "", correct: "Paperless")]
    #expect(store.apply(to: "paper less und US Whisper") == "Paperless und Wispr Flow")
    #expect(store.contextualStrings == ["API-Key", "Colin Whisper", "Paperless", "Wispr Flow"])
    #expect(GlossaryStore(url: url).entries.count == 1)  // built-ins are never written to glossary.json
}

// MARK: - Structured formatter output

@Test func textBuilderLaysOutGreetingBlocksAndClosing() {
    let letter = FormattedDictation(
        greeting: "Guten Morgen Colin,",
        blocks: [
            .paragraph("hier mein kurzes Feedback."),
            .list(["Zeilenumbrüche", "- Bullet Points", "• Fragezeichen", "  "]),
            .paragraph("Läuft einwandfrei."),
        ],
        closing: "MFG\nLouis W.")
    #expect(letter.text == """
        Guten Morgen Colin,

        hier mein kurzes Feedback.

        - Zeilenumbrüche
        - Bullet Points
        - Fragezeichen

        Läuft einwandfrei.

        MFG
        Louis W.
        """)
}

@Test func textBuilderCapitalizesPartsAndRepairsTheClosing() {
    // Real structured output: sign-off left in the text, the name alone as closing.
    let output = FormattedDictation(
        greeting: "Hallo Sarah,",
        blocks: [.paragraph("kurze Frage, hast du die Unterlagen?"), .paragraph("und noch was anderes, das Meeting fällt aus."), .paragraph("liebe Grüße\nTom")],
        closing: "Tom")
    #expect(output.withSignOffAsClosing().text
        == "Hallo Sarah,\n\nkurze Frage, hast du die Unterlagen?\n\nUnd noch was anderes, das Meeting fällt aus.\n\nLiebe Grüße\nTom")
    // A last paragraph that isn't a sign-off stays.
    let plain = FormattedDictation(blocks: [.paragraph("Danke dir.")], closing: "Viele Grüße\nTom")
    #expect(plain.withSignOffAsClosing() == plain)
}

@Test func textBuilderNumbersCountedLists() {
    let text = FormattedDictation(blocks: [
        .paragraph("Das würde ich so aufzählen:"),
        .numbered(["Sollte es besser funktionieren", "2. Sollte es schneller funktionieren", "3) Sollte es günstiger funktionieren"]),
    ]).text
    #expect(text == "Das würde ich so aufzählen:\n1. Sollte es besser funktionieren\n2. Sollte es schneller funktionieren\n3. Sollte es günstiger funktionieren")
}

@Test func textBuilderDropsSpokenCountsFromItems() {
    // Real Claude output for the user's dictation.
    let text = FormattedDictation(blocks: [
        .paragraph("Das würde ich so aufzählen:"),
        .numbered(["Sollte das besser funktionieren?", "Zweitens sollte es schneller funktionieren.", "Drittens sollte es günstiger funktionieren."]),
    ]).text
    #expect(text == "Das würde ich so aufzählen:\n1. Sollte das besser funktionieren?\n2. Sollte es schneller funktionieren.\n3. Sollte es günstiger funktionieren.")
}

@Test func questionMarkMayGoWhenTheSentenceBecameAListItem() {
    // The user's real dictation: the transcriber's "?" on a verb-first list item.
    let input = "Das würde ich so aufzählen. Erstens. Sollte das besser funktionieren? Zweitens sollte es schneller funktionieren und drittens sollte es günstiger funktionieren."
    #expect(Formatter.isPlausible(
        "Das würde ich so aufzählen:\n1. Sollte das besser funktionieren\n2. Sollte es schneller funktionieren\n3. Sollte es günstiger funktionieren",
        for: input))
    // Without a list the question still has to stay a question.
    #expect(!Formatter.isPlausible("Das würde ich so aufzählen. Das sollte besser funktionieren.", for: "Das würde ich so aufzählen. Sollte das besser funktionieren?"))
}

@Test func textBuilderKeepsListUnderItsIntro() {
    let text = FormattedDictation(blocks: [.paragraph("Für morgen brauchen wir:"), .list(["Milch", "Eier", "Brot"]), .paragraph("Danke.")]).text
    #expect(text == "Für morgen brauchen wir:\n- Milch\n- Eier\n- Brot\n\nDanke.")
}

@Test func repairDropsInventedFrameButKeepsDictatedOne() {
    // Real output for the first chunk of a long letter: the closing is from the examples.
    let chunk = "Hallo Team, kurzes Update zum Projekt. Das lief gut."
    let output = FormattedDictation(greeting: "Hallo Team,", blocks: [.paragraph("kurzes Update zum Projekt. Das lief gut.")], closing: "Viele Grüße\nColin")
    let repaired = Formatter.repaired(output, for: chunk)
    #expect(repaired.closing == nil && repaired.greeting == "Hallo Team,")
    #expect(Formatter.hasPlausibleFrame(repaired, for: chunk))
    // Partly dictated stays and is judged by the frame check: mostly dictated, so "MFG" spelled out passes.
    let fixture = Pipeline.join(Fixture.testerFeedbackSegments)
    let spelledOut = Formatter.repaired(.init(greeting: "Guten Morgen Colin,", blocks: [], closing: "Mit freundlichen Grüßen\nLouis W."), for: fixture)
    #expect(Formatter.hasPlausibleFrame(spelledOut, for: fixture))
}

@Test func repairSplitsAGreetingThatSwallowedTheFirstSentence() {
    // Real Claude output for the fixture.
    let output = FormattedDictation(
        greeting: "Guten Morgen Colin,\nwie besprochen hier mein kurzes Feedback.\n",
        blocks: [.paragraph("Läuft einwandfrei.")],
        closing: "MFG\nLouis W.")
    #expect(Formatter.repaired(output, for: "guten Morgen Colin, wie besprochen hier mein kurzes Feedback. Läuft einwandfrei. MFG Louis W.").text
        == "Guten Morgen Colin,\n\nwie besprochen hier mein kurzes Feedback.\n\nLäuft einwandfrei.\n\nMFG\nLouis W.")
}

@Test func dictatedGreetingAndClosingMustNotGetLost() {
    let fixture = Pipeline.join(Fixture.testerFeedbackSegments)
    // Real Claude output: "MFG Louis W." left out.
    #expect(!Formatter.hasPlausibleFrame(.init(greeting: "Guten Morgen Colin,", blocks: [.paragraph("Läuft einwandfrei.")]), for: fixture))
    #expect(!Formatter.hasPlausibleFrame(.init(blocks: [.paragraph("Läuft einwandfrei.")], closing: "MFG\nLouis W."), for: fixture))
}

@Test func frameMustBeARealDictatedGreetingAndClosing() {
    let fixture = Pipeline.join(Fixture.testerFeedbackSegments)
    #expect(Formatter.hasPlausibleFrame(.init(greeting: "Guten Morgen Colin,", blocks: [], closing: "MFG\nLouis W."), for: fixture))
    #expect(Formatter.hasPlausibleFrame(.init(blocks: [.paragraph("Wir treffen uns am Dienstag.")]), for: "Wir treffen uns am Dienstag."))
    // Real model outputs: a request filed as greeting, the name alone as closing.
    let request = "Schreib mir eine E-Mail an Herrn Müller, dass das Meeting verschoben wird."
    #expect(!Formatter.hasPlausibleFrame(.init(greeting: "Schreib mir eine E-Mail an Herrn Müller,", blocks: [.paragraph("das Meeting wird verschoben.")]), for: request))
    #expect(!Formatter.hasPlausibleFrame(.init(greeting: "Hallo Sarah,", blocks: [], closing: "Tom"), for: "Hallo Sarah, alles klar. Liebe Grüße Tom"))
    // Invented frames: nothing of it was dictated.
    #expect(!Formatter.hasPlausibleFrame(.init(greeting: "Hallo", blocks: [.paragraph("Wir treffen uns am Dienstag.")], closing: "Viele Grüße\nColin"), for: "Wir treffen uns am Dienstag."))
}

@Test func greetingMayBeANameWithACorrectedWord() throws {
    // The user's real dictation and Claude's real answer, shortened: the frame check used to
    // reject it, and the local fallback failed as well.
    let input = "Louis, mein gutster. Ich möchte dir großartige Neuigkeiten verkünden. Du kannst jetzt Aufzählungen machen, sowas wie Erstens Diese Aufzählung, zweitens die zweite Aufzählung, drittens die dritte Aufzählung."
    let claude = FormattedDictation(
        greeting: "Louis, mein Bester,",
        blocks: [.paragraph("ich möchte dir großartige Neuigkeiten verkünden. Du kannst jetzt Aufzählungen machen, sowas wie:"),
                 .numbered(["Diese Aufzählung", "die zweite Aufzählung", "die dritte Aufzählung"])])
    #expect(try Formatter.verified(claude, for: input).hasPrefix("Louis, mein Bester,\n\nich möchte dir"))
    // A long sentence starting with the first word is still no greeting.
    let request = "Schreib mir eine E-Mail an Herrn Müller, dass das Meeting verschoben wird."
    #expect(!Formatter.hasPlausibleFrame(.init(greeting: "Schreib mir eine E-Mail an Herrn Müller,", blocks: [.paragraph("dass das Meeting verschoben wird.")]), for: request))
}

@Test func repairDropsAClosingCopiedFromTheExamples() {
    // Real local output: "Colin" was dictated (in "Colin Whisper"), "Viele Grüße" wasn't.
    let input = "Louis, mein gutster. Es gibt ein neues Update von Colin Whisper."
    let local = FormattedDictation(greeting: "Louis,", blocks: [.paragraph("mein gutster. Es gibt ein neues Update von Colin Whisper.")], closing: "Viele Grüße\nColin")
    let repaired = Formatter.repaired(local, for: input)
    #expect(repaired.closing == nil)
    #expect(Formatter.hasPlausibleFrame(repaired, for: input))
}

@Test func plausibilityRejectsLostCapitalization() {
    // Real structured output for a long dictation, shortened.
    let input = "Außerdem hat der Kunde nachgefragt, ob wir die Freigabe der Dokumente auch per App machen können. Bitte überlegt euch bis Freitag, wie viel Aufwand das wäre. Ich bin ab übernächster Woche im Urlaub."
    #expect(!Formatter.isPlausible(
        "Außerdem hat der kunde nachgefragt, ob wir die freigabe der dokumente auch per app machen können. bitte überlegt euch bis freitag, wie viel aufwand das wäre. ich bin ab übernächster woche im urlaub.",
        for: input))
    #expect(Formatter.isPlausible(input, for: input.replacingOccurrences(of: "Außerdem", with: "außerdem")))
}

@Test func plausibilityRejectsRepeatedContent() {
    // Real structured output: the closing kept in the text and the name repeated as closing.
    let input = "Hallo Sarah, kurze Frage, hast du die Unterlagen schon bekommen? Liebe Grüße Tom"
    #expect(Formatter.isPlausible("Hallo Sarah,\n\nkurze Frage, hast du die Unterlagen schon bekommen?\n\nLiebe Grüße\nTom", for: input))
    #expect(!Formatter.isPlausible(
        "Hallo Sarah,\n\nkurze Frage, hast du die Unterlagen schon bekommen?\n\nKurze Frage, hast du die Unterlagen schon bekommen?\n\nLiebe Grüße\nTom",
        for: input))
}

@Test func textBuilderSkipsMissingAndEmptyParts() {
    #expect(FormattedDictation(blocks: [.paragraph("  Kurz und knapp. ")]).text == "Kurz und knapp.")
    #expect(FormattedDictation(greeting: " ", blocks: [.paragraph(""), .list([]), .paragraph("Text")], closing: "Viele Grüße\n\n Colin ").text
        == "Text\n\nViele Grüße\nColin")
}

@Test func structureOnlyForLettersAndLists() {
    let structured = [
        Pipeline.join(Fixture.testerFeedbackSegments),
        "Hallo Sarah, kurze Frage, hast du die Unterlagen schon bekommen?",
        "Ähm, hallo Max, das Meeting fällt aus.",
        "Das Meeting fällt aus. Liebe Grüße Tom",
        "Für morgen brauchen wir Milch, Eier, Brot und Butter.",
        "Die Punkte für heute sind erstens das Budget, zweitens die Personalplanung und drittens der Umzug.",
    ]
    for text in structured { #expect(Formatter.wantsStructure(text), "\(text)") }
    let free = [
        "Kannst du mir sagen, wie spät es ist?",
        "Wir treffen uns am Dienstag um drei im Büro.",
        "Hier mein Feedback, das hilft hoffentlich.",  // "hi" is no greeting
        "Ich schick dir die Präsentation heute Abend beziehungsweise morgen früh, je nachdem, wann ich fertig werde.",
        // A long letter: guided generation would be too slow and drift there.
        "Hallo Team, " + String(repeating: "Wir haben die Anbindung an das Archiv fertiggestellt. ", count: 15) + "Viele Grüße Colin",
    ]
    for text in free { #expect(!Formatter.wantsStructure(text), "\(text)") }
}

@Test func examplesAreConsistentWithTheGuards() {
    // Every few-shot answer must pass the checks the real output has to pass.
    for example in Formatter.examples {
        #expect(Formatter.isPlausible(example.formatted.text, for: example.dictation), "\(example.dictation)")
        #expect(Formatter.hasPlausibleFrame(example.formatted, for: example.dictation), "\(example.dictation)")
    }
}

// MARK: - Claude (BYOK)

@Test func claudeRequestSendsExamplesAsTurnsAndCachesThem() throws {
    let body = ClaudeFormatter.body(for: "Hallo Max, alles klar.", terms: ["Wispr Flow"])
    #expect(JSONSerialization.isValidJSONObject(body))
    #expect(body["model"] as? String == "claude-haiku-5-5")
    #expect(body["temperature"] == nil)  // Haiku 5.5 rejects sampling parameters
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    #expect((body["system"] as? String)?.contains("Wispr Flow") == true)

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == Formatter.examples.count * 2 + 1)
    #expect(messages.enumerated().allSatisfy { $1["role"] as? String == ($0.isMultiple(of: 2) ? "user" : "assistant") })
    #expect(messages.last?["content"] as? String == "<diktat>Hallo Max, alles klar.</diktat>")
    let cached = try #require(messages[messages.count - 2]["content"] as? [[String: Any]])
    #expect(cached.first?["cache_control"] != nil)

    // JSON shaped by the examples; the constrained schema made Claude pick empty lists.
    #expect((body["output_config"] as? [String: Any])?["format"] == nil)
    #expect((body["system"] as? String)?.contains("JSON-Objekt im Format der Beispiele") == true)
}

@Test func claudeResponseIsParsedIntoTheSameStructure() throws {
    // Shaped like a real response: an (empty) thinking block may come first.
    func response(_ stopReason: String) -> Data {
        let payload = #"{"greeting":"Hallo Max,","blocks":[{"type":"paragraph","value":"alles klar."},{"type":"list","value":["A","B","C"]},{"type":"numbered","value":["D","E","F"]}],"closing":"LG\nColin"}"#
        let body: [String: Any] = [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": payload]],
            "stop_reason": stopReason,
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
    let parsed = try ClaudeFormatter.parse(response("end_turn"))
    #expect(parsed == FormattedDictation(
        greeting: "Hallo Max,", blocks: [.paragraph("alles klar."), .list(["A", "B", "C"]), .numbered(["D", "E", "F"])], closing: "LG\nColin"))
    #expect(throws: ClaudeError.self) { try ClaudeFormatter.parse(response("refusal")) }
    #expect(throws: ClaudeError.self) { try ClaudeFormatter.parse(response("max_tokens")) }
}

@Test func claudeCostComesFromTheUsageBlock() throws {
    let million = 1_000_000
    let usage: [String: Any] = [
        "usage": ["input_tokens": million, "output_tokens": million,
                  "cache_creation_input_tokens": million, "cache_read_input_tokens": million],
    ]
    // 0,10 + 0,50 + 0,125 + 0,01 = 0,735 $ = 73,5 US-Cent, at 0,86 € per dollar 63,21 Euro-Cent.
    #expect(abs(ClaudeFormatter.cents(try JSONSerialization.data(withJSONObject: usage)) - 63.21) < 0.001)
    #expect(ClaudeFormatter.cents(Data("{}".utf8)) == 0)
}

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

@Test func dictionaryWordFixesNearMisses() {
    let entries = [GlossaryEntry(wrong: "", correct: "Paperless")]
    let result = Glossary.apply(entries, to: "Papeless und Paperess, Paperless und Paperlessness, Paper")
    #expect(result.text == "Paperless und Paperless, Paperless und Paperlessness, Paper")
    #expect(result.hits[entries[0].id] == 2)
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

// MARK: - Questions

@Test func questionsAreMarkedFromSyntax() {
    let questions = [
        // Real transcripts: the last sentence came without punctuation.
        ("Damals hat sich der Kontakt verlaufen. Ist das wieder relevant geworden", "Damals hat sich der Kontakt verlaufen. Ist das wieder relevant geworden?"),
        ("Wie würdest du das pricen", "Wie würdest du das pricen?"),
        // The transcriber's "." is overridden by clear question syntax.
        ("Hallo Max, wie geht es dir. Bis bald.", "Hallo Max, wie geht es dir? Bis bald."),
        ("Kannst du mir sagen, wie spät es ist.", "Kannst du mir sagen, wie spät es ist?"),
        ("Haben Sie schon Gelegenheit gehabt.", "Haben Sie schon Gelegenheit gehabt?"),
        ("Gibt es dazu schon Neuigkeiten.", "Gibt es dazu schon Neuigkeiten?"),
        ("Welche Farbe hat das Auto.", "Welche Farbe hat das Auto?"),
        ("Bis wann brauchst du das.", "Bis wann brauchst du das?"),
        ("Das passt so, oder.", "Das passt so, oder?"),
        ("Und habt ihr morgen Zeit", "Und habt ihr morgen Zeit?"),
        ("Kann ich dir helfen", "Kann ich dir helfen?"),
    ]
    for (input, expected) in questions { #expect(Questions.mark(input) == expected) }

    let statements = [
        "Soll nicht gut für die Gelenke sein.",
        "Auch wenn ich auf Asphalt gehe oder so.",
        "Kann ich verstehen.",
        "Schicken Sie mir bitte die Unterlagen.",
        "Schick die Mail an Max.",
        "Übersetze die Mail auf Englisch.",
        "Sollte das nicht klappen, melde ich mich.",
        "Wer zuerst kommt, mahlt zuerst.",
        "Wie gesagt, das Meeting ist morgen.",
        "Was ich noch sagen wollte, das Budget steht.",
        "Ich verstehe glaube ich nicht genau, was du meinst.",
        "Hallo Sarah, das ist aktuell noch nicht möglich.",
        "Ist das wieder relevant geworden?",
        "Für das Wochenende brauchen wir:\n- Äpfel\n- Birnen",
    ]
    for statement in statements { #expect(Questions.mark(statement) == statement) }
}

// MARK: - Pipeline fallbacks

private struct FakeTranscriber: Transcribing {
    var text: String
    var error: Error?
    func transcribe(_ buffers: [AVAudioPCMBuffer], contextualStrings: [String]) async throws -> [String] {
        if let error { throw error }
        return [text]
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
    var name = "fake"
    func format(_ text: String, terms: [String]) async throws -> String {
        guard let output else { throw FormatterError.implausible }
        return output
    }
}

@Test func pipelineUsesFormatterOutput() async throws {
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless läuft"),
        glossary: FakeGlossary(), formatters: [FakeFormatter(output: "Paperless läuft.")])
    #expect(result.formattedText == "Paperless läuft.")
    #expect(!result.usedFallback)
    #expect(result.rawTranscript == "Peiperless läuft")
    #expect(result.correctedTranscript == "Paperless läuft")
}

@Test func pipelineTriesFormattersInOrder() async throws {
    // Claude offline or implausible → the local model formats.
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless läuft"), glossary: FakeGlossary(),
        formatters: [FakeFormatter(output: nil, name: "claude"), FakeFormatter(output: "Paperless läuft.", name: "lokal")])
    #expect(result.formattedText == "Paperless läuft.")
    #expect(result.formattedBy == "lokal")
    #expect(!result.usedFallback)
}

@Test func pipelineFallsBackToGlossaryTextWhenFormatterFails() async throws {
    for formatters in [[FakeFormatter(output: nil)], []] {
        let result = try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless läuft"),
            glossary: FakeGlossary(), formatters: formatters)
        #expect(result.formattedText == "Paperless läuft")
        #expect(result.usedFallback)
    }
}

@Test func pipelineFallsBackToRawWhenGlossaryFails() async throws {
    let result = try await Pipeline.run(
        buffers: [], duration: 1, transcriber: FakeTranscriber(text: "Peiperless"),
        glossary: FakeGlossary(fails: true), formatters: [])
    #expect(result.correctedTranscript == "Peiperless")
    #expect(result.formattedText == "Peiperless")
}

@Test func pipelineAbortsOnTranscriptionFailureOrSilence() async {
    await #expect(throws: PipelineError.self) {
        try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "", error: CocoaError(.fileReadUnknown)),
            glossary: FakeGlossary(), formatters: [])
    }
    await #expect(throws: PipelineError.self) {
        try await Pipeline.run(
            buffers: [], duration: 1, transcriber: FakeTranscriber(text: "  "),
            glossary: FakeGlossary(), formatters: [])
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

// MARK: - Statistics

@Test func streaksCountConsecutiveDays() {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9))!
    func day(_ offset: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: DateComponents(day: offset, hour: hour - 9), to: today)!
    }
    // Nothing today yet: the streak still runs from yesterday. Two dictations on one day count once.
    let streaks = Usage.streaks(days: [day(-1), day(-2), day(-2, hour: 20), day(-4), day(-5), day(-6), day(-7)], today: today, calendar: calendar)
    #expect(streaks.current == 2)
    #expect(streaks.longest == 4)
    #expect(Usage.streaks(days: [day(-2)], today: today, calendar: calendar).current == 0)
    #expect(Usage.streaks(days: [], today: today, calendar: calendar).longest == 0)
}

@Test func usageStoreRecordsSeedsAndResets() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let result = DictationResult(
        id: UUID(), timestamp: Date(), rawTranscript: "ähm die Rechnung von Peiperless",
        correctedTranscript: "ähm die Rechnung von Paperless", formattedText: "Die Rechnung von Paperless.",
        usedFallback: false, duration: 2)

    let store = UsageStore(url: url, seed: [result])  // no file yet: starts from the history
    store.record(result, appName: "Notizen", bundleID: "com.apple.Notes")
    let reloaded = UsageStore(url: url, seed: [])
    #expect(reloaded.records.count == 2)
    #expect(reloaded.totalWords == 8)
    #expect(reloaded.wordsPerMinute == 120)
    #expect(reloaded.glossaryFixes == 2)    // Peiperless → Paperless
    #expect(reloaded.formatterFixes == 2)   // "ähm" dropped; sentence-start case doesn't count
    #expect(reloaded.nouns["Rechnung"] == 2)
    #expect(reloaded.apps.map(\.name) == ["Notizen"])

    reloaded.reset()
    #expect(UsageStore(url: url, seed: [result]).records.isEmpty)  // a reset isn't undone by seeding
}
