import Foundation
import NaturalLanguage
import Observation

/// One dictation without its text — what the statistics window is built from.
struct UsageRecord: Codable, Equatable {
    let date: Date
    let words: Int
    let duration: TimeInterval
    let appName: String?   // target app of the paste; nil for entries seeded from the history
    let bundleID: String?
    let glossaryFixes: Int
    let formatterFixes: Int
}

enum Usage {
    /// Word count plus the nouns, so "most used word" isn't "die".
    static func analyze(_ text: String) -> (words: Int, nouns: [String]) {
        guard !text.isEmpty else { return (0, []) }
        let range = text.startIndex..<text.endIndex
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.german, range: range)
        var words = 0
        var nouns: [String] = []
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, word in
            words += 1
            if tag == .noun, text[word].count >= 2 { nouns.append(String(text[word])) }
            return true
        }
        return (words, nouns)
    }

    /// Words removed or replaced on the way from `old` to `new`; punctuation and sentence-start case don't count.
    static func changedWords(from old: String, to new: String) -> Int {
        Glossary.tokens(new).map(Glossary.key).difference(from: Glossary.tokens(old).map(Glossary.key)).removals.count
    }

    /// Runs of consecutive days. The current streak survives a day without dictation until midnight.
    static func streaks(days: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let days = Set(days.map(calendar.startOfDay))
        func previous(_ day: Date) -> Date { calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: day)!) }

        var day = calendar.startOfDay(for: today)
        if !days.contains(day) { day = previous(day) }
        var current = 0
        while days.contains(day) {
            current += 1
            day = previous(day)
        }

        var longest = 0, run = 0
        var last: Date?
        for day in days.sorted() {
            run = last == previous(day) ? run + 1 : 1
            longest = max(longest, run)
            last = day
        }
        return (current, longest)
    }
}

// MARK: - Persistence

@Observable
final class UsageStore {
    struct AppUsage: Identifiable {
        let bundleID: String
        let name: String
        let count: Int
        var id: String { bundleID }
    }

    private struct Stored: Codable {
        var records: [UsageRecord] = []
        var nouns: [String: Int] = [:]
    }

    private(set) var records: [UsageRecord]
    private(set) var nouns: [String: Int]
    @ObservationIgnored private let url: URL

    /// Without a file yet, starts from the dictation history so the window isn't empty on first open.
    init(url: URL = AppFiles.url(for: "usage.json"), seed: [DictationResult]) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let stored = (try? JSONDecoder().decode(Stored.self, from: data)) ?? Stored()
            records = stored.records
            nouns = stored.nouns
        } else {
            records = []
            nouns = [:]
            for result in seed.reversed() { add(result, appName: nil, bundleID: nil) }  // history is newest first
            save()
        }
    }

    func record(_ result: DictationResult, appName: String?, bundleID: String?) {
        add(result, appName: appName, bundleID: bundleID)
        save()
    }

    func reset() {
        records = []
        nouns = [:]
        save()  // an empty file, not none — otherwise the next launch seeds from the history again
    }

    private func add(_ result: DictationResult, appName: String?, bundleID: String?) {
        let (words, found) = Usage.analyze(result.formattedText)
        records.append(UsageRecord(
            date: result.timestamp, words: words, duration: result.duration, appName: appName, bundleID: bundleID,
            glossaryFixes: Usage.changedWords(from: result.rawTranscript, to: result.correctedTranscript),
            formatterFixes: Usage.changedWords(from: result.correctedTranscript, to: result.formattedText)))
        for noun in found { nouns[noun, default: 0] += 1 }
    }

    private func save() {
        do {
            try JSONEncoder().encode(Stored(records: records, nouns: nouns)).write(to: url, options: .atomic)
        } catch {
            log.error("saving usage failed: \(error.localizedDescription)")
        }
    }

    // MARK: Figures

    var totalWords: Int { records.reduce(0) { $0 + $1.words } }
    var glossaryFixes: Int { records.reduce(0) { $0 + $1.glossaryFixes } }
    var formatterFixes: Int { records.reduce(0) { $0 + $1.formatterFixes } }

    var wordsPerMinute: Int {
        let minutes = records.reduce(0) { $0 + $1.duration } / 60
        return minutes > 0 ? Int((Double(totalWords) / minutes).rounded()) : 0
    }

    /// Most used first; dictations with unknown app are left out.
    var apps: [AppUsage] {
        Dictionary(grouping: records, by: \.bundleID)
            .compactMap { id, records in
                id.map { AppUsage(bundleID: $0, name: records.last?.appName ?? $0, count: records.count) }
            }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    var wordsPerDay: [Date: Int] {
        records.reduce(into: [:]) { $0[Calendar.current.startOfDay(for: $1.date), default: 0] += $1.words }
    }

    /// Weekday (1 = Sunday, as in `Calendar`) and hour with the most dictations.
    var peakSlot: (weekday: Int, hour: Int)? {
        let counts = records.reduce(into: [Int: Int]()) { counts, record in
            let parts = Calendar.current.dateComponents([.weekday, .hour], from: record.date)
            counts[parts.weekday! * 100 + parts.hour!, default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ($0.key / 100, $0.key % 100) }
    }

    var topNoun: (word: String, count: Int)? {
        nouns.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }
}
