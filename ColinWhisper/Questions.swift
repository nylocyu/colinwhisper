import Foundation
import NaturalLanguage

/// Stage 3b: a dictated question gets its "?" from German syntax. The transcriber often ends
/// one with "." or nothing, and the formatter doesn't always notice (and doesn't run in
/// fallback). Only ever adds question marks; the formatter's plausibility check keeps them.
enum Questions {
    static func mark(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            var end = range.upperBound
            while end > range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            let sentence = text[range.lowerBound..<end]
            guard let last = sentence.last, !sentence.hasSuffix("..") else { return }
            let punctuated = last == "."
            guard punctuated || last.isLetter || last.isNumber,
                  isQuestion(String(sentence), punctuated: punctuated) else { return }
            output += text[cursor..<(punctuated ? text.index(before: end) : end)] + "?"
            cursor = end
        }
        return output + text[cursor...]
    }

    /// `punctuated`: the transcriber ended the sentence with "." — it heard falling intonation.
    static func isQuestion(_ sentence: String, punctuated: Bool) -> Bool {
        let tokens = tokenize(sentence)
        let words = tokens.filter(\.isWord).map(\.lower)

        // Tag questions: "…, oder?", "…, oder nicht?", "…, nicht wahr?", "…, gell?", "…, ne?"
        let tail = Array(words.suffix(2))
        if words.last == "oder" || tail == ["oder", "nicht"] || tail == ["nicht", "wahr"] || ["gell", "gelle"].contains(words.last ?? "") {
            return true
        }
        if let i = tokens.lastIndex(where: \.isWord), i > 0, ["ne", "nicht"].contains(tokens[i].lower), tokens[i - 1].text == "," {
            return true
        }

        // The first clause with a verb decides, so a greeting in front doesn't count: "Hallo Max, wie geht's".
        let clauses = tokens.split { [",", ";", ":"].contains($0.text) }
            .map { Array($0.drop { ["und", "aber", "oder"].contains($0.lower) }) }
        guard let index = clauses.firstIndex(where: { $0.contains { $0.tag == .verb } }) else { return false }
        // A verb right after the comma means the clause was conditional or relative:
        // "Sollte das nicht klappen, melde ich mich", "Wer zuerst kommt, mahlt zuerst".
        if clauses.dropFirst(index + 1).first?.first?.tag == .verb { return false }
        return isWQuestion(clauses[index]) || isVerbFirstQuestion(clauses[index], punctuated: punctuated)
    }

    /// "Wie würdest du …", "Mit wem …", "Wie viel kostet …": the verb follows the W-word directly.
    /// In "Was ich meine …" a pronoun comes first — that's a subordinate clause.
    private static func isWQuestion(_ clause: [Token]) -> Bool {
        var rest = clause[...]
        if rest.first?.tag == .preposition { rest = rest.dropFirst() }
        guard let w = rest.first, interrogatives.contains(w.lower) else { return false }
        rest = rest.dropFirst()
        if w.lower == "wie", let next = rest.first, wieIdioms.contains(next.lower) { return false }
        for token in rest.prefix(3) {
            if token.tag == .verb { return true }
            if token.tag == .pronoun || token.tag == .determiner { return false }
        }
        return false
    }

    /// "Ist das …", "Kannst du …", "Haben Sie …". The subject has to fit the verb form,
    /// which keeps imperatives out: "Schick die Mail", "Schicken Sie mir …", "Gib mir …".
    private static func isVerbFirstQuestion(_ clause: [Token], punctuated: Bool) -> Bool {
        guard clause.count >= 2, clause[0].tag == .verb else { return false }
        let verb = clause[0].lower, subject = clause[1].lower
        switch subject {
        case "du": return verb.hasSuffix("st")
        case "ihr": return verb.hasSuffix("t") || verb == "seid"
        // "Kann ich verstehen.", "Machen wir so.", "Kann man machen." are statements without a topic.
        // Only without the transcriber's "." (no falling intonation heard) are they questions.
        case "ich", "wir", "man": return !punctuated
        case "sie" where clause[1].text == "Sie": return formalVerbs.contains(verb)
        default:
            guard thirdPerson.contains(subject) || possessives.contains(where: { subject.hasPrefix($0) }) else { return false }
            return modals.contains(verb) || verb.hasSuffix("t") || verb.hasSuffix("en")
        }
    }

    private struct Token {
        let text: String
        let tag: NLTag?
        var lower: String { text.lowercased() }
        var isWord: Bool { text.first.map { $0.isLetter || $0.isNumber } ?? false }
    }

    private static func tokenize(_ text: String) -> [Token] {
        let range = text.startIndex..<text.endIndex
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.german, range: range)
        var tokens: [Token] = []
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, word in
            tokens.append(Token(text: String(text[word]), tag: tag))
            return true
        }
        return tokens
    }

    // ponytail: hand-made word lists, the calibration knobs — extend them from real misses.
    private static let interrogatives: Set<String> = [
        "wer", "wen", "wem", "wessen", "was", "wann", "wo", "wie", "warum", "wieso", "weshalb", "weswegen",
        "woher", "wohin", "womit", "wofür", "wozu", "worüber", "worum", "woran", "worauf", "wovon", "wodurch",
        "wobei", "woraus", "worin", "welche", "welcher", "welches", "welchen", "welchem", "inwiefern", "inwieweit",
    ]
    /// "Wie gesagt, …", "Wie besprochen …", "Wie immer …" open statements.
    private static let wieIdioms: Set<String> = [
        "gesagt", "besprochen", "vereinbart", "abgesprochen", "erwähnt", "angekündigt", "versprochen", "gewünscht",
        "gewohnt", "erwartet", "geplant", "beschrieben", "geschrieben", "erklärt", "angesprochen", "telefonisch",
        "folgt", "immer", "schon", "bereits", "auch", "oben", "unten", "gestern", "heute", "üblich", "bekannt",
    ]
    private static let formalVerbs: Set<String> = [
        "haben", "hätten", "hatten", "sind", "wären", "waren", "können", "könnten", "konnten", "wollen", "wollten",
        "würden", "werden", "möchten", "müssen", "müssten", "dürfen", "sollen", "sollten", "wissen", "kennen", "brauchen",
    ]
    /// Finite forms not ending in -t/-en.
    private static let modals: Set<String> = [
        "kann", "soll", "muss", "darf", "will", "mag", "möchte", "könnte", "sollte", "müsste", "dürfte", "wollte",
        "würde", "hätte", "wäre", "war", "weiß", "sind", "wird", "gab",
    ]
    private static let thirdPerson: Set<String> = [
        "er", "sie", "es", "das", "dies", "diese", "dieser", "dieses", "diesen", "der", "die", "den", "dem", "des",
        "ein", "eine", "einer", "eines", "einen", "einem", "kein", "keine", "keiner", "keinen", "keinem",
        "jemand", "irgendwer", "irgendjemand", "alle", "alles",
    ]
    private static let possessives = ["mein", "dein", "sein", "ihre", "unser", "euer", "eure"]
}
