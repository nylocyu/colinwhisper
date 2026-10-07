import Foundation
import Observation

struct GlossaryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var wrong: String        // how the transcriber hears it
    var correct: String      // how it should be written
    var caseSensitive: Bool
    var createdAt: Date
    var hitCount: Int        // how often applied — helps cleaning up

    init(wrong: String, correct: String, caseSensitive: Bool = false) {
        self.id = UUID()
        self.wrong = wrong
        self.correct = correct
        self.caseSensitive = caseSensitive
        self.createdAt = Date()
        self.hitCount = 0
    }
}

struct GlossaryCandidate: Hashable {
    let wrong: String
    let correct: String
}

enum Glossary {
    // MARK: Application (stage 3)

    /// Plain string replacement on word boundaries, longest entries first so multi-word
    /// entries aren't split up by shorter ones. Then every target spelling is enforced
    /// regardless of case, spaces and hyphens — that's all a word-only entry (empty
    /// `wrong`) does. Returns the hit count per entry id.
    static func apply(_ entries: [GlossaryEntry], to text: String) -> (text: String, hits: [UUID: Int]) {
        var text = text
        var hits: [UUID: Int] = [:]
        for entry in entries.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            let wrong = entry.wrong.trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !entry.correct.isEmpty else { continue }
            let changed = replace(NSRegularExpression.escapedPattern(for: wrong), caseSensitive: entry.caseSensitive, with: entry.correct, in: &text)
            if changed > 0 { hits[entry.id, default: 0] += changed }
        }
        // ponytail: case-insensitive, so a word that is also a common word (e.g. "ES") is rewritten
        // everywhere — make this pass switchable per entry if that bites.
        for entry in entries.sorted(by: { $0.correct.count > $1.correct.count }) {
            let changed = replace(spellingPattern(entry.correct), caseSensitive: false, with: entry.correct, in: &text)
            if changed > 0 { hits[entry.id, default: 0] += changed }
        }
        return (text, hits)
    }

    /// Replaces matches of `pattern` on word boundaries; returns how many actually changed.
    private static func replace(_ pattern: String, caseSensitive: Bool, with replacement: String, in text: inout String) -> Int {
        guard !pattern.isEmpty, !replacement.isEmpty else { return 0 }
        // Unicode-aware word boundary: "Ei" must not match inside "Eiweiß".
        let bounded = "(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: bounded, options: caseSensitive ? [] : [.caseInsensitive]) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        let changed = regex.matches(in: text, range: range)
            .filter { Range($0.range, in: text).map { text[$0] != replacement } ?? false }
            .count
        if changed > 0 {
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return changed
    }

    /// "QES-Addon" also matches "qes add-on" and "QESAddon": an optional space or hyphen between any two characters.
    private static func spellingPattern(_ word: String) -> String {
        word.filter { !$0.isWhitespace && $0 != "-" }
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s-]?")
    }

    // MARK: Learning from corrections

    /// Diffs the raw transcript (never the LLM output) against the user's corrected text
    /// and keeps only short, similar replacements — everything else is style, not a
    /// recognition error.
    static func candidates(raw: String, corrected: String, existing: [GlossaryEntry]) -> [GlossaryCandidate] {
        let old = tokens(raw)
        let new = tokens(corrected)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.map(key).difference(from: old.map(key)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        let known = Set(existing.map { $0.wrong.lowercased() })
        var result: [GlossaryCandidate] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1; j += 1
                continue
            }
            var wrong: [String] = [], right: [String] = []
            while i < old.count, removed.contains(i) { wrong.append(old[i]); i += 1 }
            while j < new.count, inserted.contains(j) { right.append(new[j]); j += 1 }
            if wrong.isEmpty, right.isEmpty { break }  // can't happen for a valid diff; guards the loop

            // Pure deletions (fillers) and pure insertions are never glossary cases.
            guard (1...3).contains(wrong.count), (1...3).contains(right.count) else { continue }
            let candidate = GlossaryCandidate(wrong: wrong.joined(separator: " "), correct: right.joined(separator: " "))
            guard isSimilar(candidate.wrong, candidate.correct),
                  !known.contains(candidate.wrong.lowercased()),
                  apply(existing, to: candidate.wrong).text != candidate.correct,  // already handled, e.g. by a word entry
                  !result.contains(candidate) else { continue }
            result.append(candidate)
        }
        return result
    }

    /// Words with surrounding punctuation stripped; pure-punctuation tokens (list dashes) dropped.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    /// Comparison key: ignores sentence-start capitalization the formatter adds,
    /// but keeps real case changes like "Eidas" → "eIDAS".
    static func key(_ token: String) -> String {
        token.prefix(1).lowercased() + token.dropFirst()
    }

    private static func isSimilar(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a.first == b.first { return true }
        return Double(levenshtein(a, b)) / Double(max(a.count, b.count)) < 0.5
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Persistence

@Observable
final class GlossaryStore: GlossaryProcessing {
    var entries: [GlossaryEntry] {
        didSet { save() }
    }

    @ObservationIgnored private let url: URL

    init(url: URL = AppFiles.url(for: "glossary.json")) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            do {
                entries = try decoder.decode([GlossaryEntry].self, from: data)
            } catch {
                // Don't overwrite a hand-edited file that failed to parse — keep it aside.
                let backup = url.appendingPathExtension("broken")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
                log.error("glossary.json unreadable, moved to \(backup.path): \(error.localizedDescription)")
                entries = []
            }
        } else {
            entries = []
        }
    }

    /// Target spellings, used to bias the transcriber.
    var contextualStrings: [String] {
        Array(Set(entries.map(\.correct).filter { !$0.isEmpty })).sorted()
    }

    func apply(to text: String) -> String {
        let (result, hits) = Glossary.apply(entries, to: text)
        if !hits.isEmpty {
            var updated = entries
            for index in updated.indices { updated[index].hitCount += hits[updated[index].id] ?? 0 }
            entries = updated
        }
        return result
    }

    func add(_ candidate: GlossaryCandidate) {
        guard !entries.contains(where: { $0.wrong.lowercased() == candidate.wrong.lowercased() }) else { return }
        entries.append(GlossaryEntry(wrong: candidate.wrong, correct: candidate.correct))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            log.error("saving glossary failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Learning without confirmation

/// Remembers candidates across dictations. A candidate is only promoted into the
/// glossary once the same correction shows up in `threshold` *different* dictations —
/// a single slip of the finger never changes future transcripts.
@Observable
final class CandidateMemory {
    struct Pending: Codable, Equatable {
        var wrong: String
        var correct: String
        var count: Int
        var lastResultID: UUID
    }

    static let threshold = 2
    private static let capacity = 200

    private(set) var pending: [Pending]
    @ObservationIgnored private let url: URL

    init(url: URL = AppFiles.url(for: "pending-candidates.json")) {
        self.url = url
        let data = (try? Data(contentsOf: url)) ?? Data()
        pending = (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    /// Counts the candidates of one dictation and returns which ones are ready for the
    /// glossary and which were only remembered.
    func record(_ candidates: [GlossaryCandidate], from resultID: UUID)
        -> (promoted: [GlossaryCandidate], remembered: [GlossaryCandidate]) {
        var promoted: [GlossaryCandidate] = []
        var remembered: [GlossaryCandidate] = []
        for candidate in candidates {
            guard let index = pending.firstIndex(where: { $0.matches(candidate) }) else {
                pending.append(Pending(wrong: candidate.wrong, correct: candidate.correct, count: 1, lastResultID: resultID))
                remembered.append(candidate)
                continue
            }
            // Re-applying the same dictation must not count twice.
            guard pending[index].lastResultID != resultID else { continue }
            pending[index].count += 1
            pending[index].lastResultID = resultID
            if pending[index].count >= Self.threshold {
                promoted.append(candidate)
                pending.remove(at: index)
            } else {
                remembered.append(candidate)
            }
        }
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        save()
        return (promoted, remembered)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(pending).write(to: url, options: .atomic)
        } catch {
            log.error("saving candidate memory failed: \(error.localizedDescription)")
        }
    }
}

private extension CandidateMemory.Pending {
    func matches(_ candidate: GlossaryCandidate) -> Bool {
        wrong.lowercased() == candidate.wrong.lowercased() && correct.lowercased() == candidate.correct.lowercased()
    }
}
