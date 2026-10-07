import AppKit
import ServiceManagement
import SwiftUI

/// Plain AppKit windows so they can be opened from anywhere (menu, after a dictation).
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    func show(_ id: String, title: String, @ViewBuilder content: () -> some View) {
        let window = windows[id] ?? {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            windows[id] = window
            return window
        }()
        let isNew = !window.isVisible
        window.contentViewController = NSHostingController(rootView: content())  // fresh state each time
        if isNew { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Glossary

struct GlossaryView: View {
    let store: GlossaryStore
    @State private var wrong = ""
    @State private var correct = ""
    @State private var sortByHits = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Erkannt als (optional)", text: $wrong)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Richtige Schreibweise", text: $correct)
                Button("Hinzufügen", action: add)
                    .disabled(trimmed(correct).isEmpty)
            }
            .onSubmit(add)

            Picker("Sortieren nach", selection: $sortByHits) {
                Text("Treffer").tag(true)
                Text("Erstellt").tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            List {
                ForEach(sortedEntries) { entry in
                    HStack {
                        TextField("Erkannt als", text: binding(entry.id, \.wrong))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Richtig", text: binding(entry.id, \.correct))
                        Toggle("Aa", isOn: binding(entry.id, \.caseSensitive))
                            .toggleStyle(.button)
                            .help("Groß-/Kleinschreibung beachten")
                            .disabled(entry.wrong.isEmpty)
                        Text("\(entry.hitCount)×")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Button {
                            store.entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    Text("Noch keine Einträge. Trag oben ein Wort ein, z. B. Paperless, oder eine Korrektur wie PayPal → Paperless.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 380)
    }

    private var sortedEntries: [GlossaryEntry] {
        store.entries.sorted { sortByHits ? $0.hitCount > $1.hitCount : $0.createdAt > $1.createdAt }
    }

    private func add() {
        guard !trimmed(correct).isEmpty else { return }
        store.entries.append(GlossaryEntry(wrong: trimmed(wrong), correct: trimmed(correct)))
        wrong = ""
        correct = ""
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }

    /// Looks entries up by id, so deleting a row can't leave a stale index binding behind.
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<GlossaryEntry, Value>) -> Binding<Value> {
        Binding(
            get: { store.entries.first { $0.id == id }.map { $0[keyPath: keyPath] } ?? GlossaryEntry(wrong: "", correct: "")[keyPath: keyPath] },
            set: { value in
                if let index = store.entries.firstIndex(where: { $0.id == id }) { store.entries[index][keyPath: keyPath] = value }
            })
    }
}

// MARK: - Correction

struct CorrectionView: View {
    let result: DictationResult?
    let glossary: GlossaryStore
    let memory: CandidateMemory
    @State private var text: String
    @State private var learned: (promoted: [GlossaryCandidate], remembered: [GlossaryCandidate])?

    init(result: DictationResult?, glossary: GlossaryStore, memory: CandidateMemory) {
        self.result = result
        self.glossary = glossary
        self.memory = memory
        _text = State(initialValue: result?.formattedText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                Text("Eingefügter Text").font(.headline)
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 140)
                Text("Rohtranskript: \(result.rawTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Übernehmen") { learn(from: result) }
                        .keyboardShortcut(.defaultAction)
                }
                if let learned { outcome(learned) }
            } else {
                Text("Noch kein Diktat vorhanden.").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 320, alignment: .topLeading)
    }

    private func learn(from result: DictationResult) {
        // Diff against the raw transcript, not the LLM output.
        let candidates = Glossary.candidates(raw: result.rawTranscript, corrected: text, existing: glossary.entries)
        let outcome = memory.record(candidates, from: result.id)
        outcome.promoted.forEach(glossary.add)
        learned = outcome
    }

    @ViewBuilder
    private func outcome(_ learned: (promoted: [GlossaryCandidate], remembered: [GlossaryCandidate])) -> some View {
        Divider()
        if learned.promoted.isEmpty, learned.remembered.isEmpty {
            Text("Keine Glossar-Kandidaten – die Änderungen sehen nach Stil aus, nicht nach Erkennungsfehlern.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(learned.promoted, id: \.self) { candidate in
                Label("‚\(candidate.wrong)‘ wird künftig als ‚\(candidate.correct)‘ korrigiert.", systemImage: "checkmark.circle")
            }
            ForEach(learned.remembered, id: \.self) { candidate in
                Label("‚\(candidate.wrong)‘ → ‚\(candidate.correct)‘ gemerkt. Beim nächsten Mal wandert es ins Glossar.",
                      systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Statistics

private let german = Locale(identifier: "de_DE")

struct StatsView: View {
    let usage: UsageStore

    var body: some View {
        ScrollView {
            if usage.records.isEmpty {
                Text("Noch keine Diktate – die Statistik füllt sich mit jedem Diktat.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            } else {
                VStack(spacing: 16) {
                    row {
                        Tile {
                            big(usage.wordsPerMinute)
                            caption("Wörter pro Minute")
                        }
                        Tile {
                            big(usage.formatterFixes + usage.glossaryFixes)
                            caption("Korrekturen durch ColinWhisper")
                            Divider()
                            line(usage.formatterFixes, "Wörter vom Formatierer korrigiert")
                            line(usage.glossaryFixes, "Glossar-Korrekturen")
                        }
                        Tile {
                            big(usage.totalWords)
                            caption("Wörter diktiert")
                            Divider()
                            line(usage.records.count, "Diktate")
                        }
                    }
                    row {
                        appsTile
                        streakTile
                    }
                    row {
                        Tile {
                            Text(usage.topNoun.map { "„\($0.word)“" } ?? "–").font(.system(.title, design: .serif).italic())
                            caption("Häufigstes Wort")
                            if let noun = usage.topNoun { Text("\(noun.count)× diktiert").foregroundStyle(.secondary) }
                        }
                        Tile {
                            Text(peakText).font(.system(.title, design: .serif))
                            caption("Deine Hauptzeit")
                            Text("Wochentag und Stunde mit den meisten Diktaten").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    private var appsTile: some View {
        let apps = usage.apps
        let known = apps.reduce(0) { $0 + $1.count }
        return Tile {
            header("Nutzung nach App", detail: "Apps insgesamt | \(apps.count)")
            if apps.isEmpty {
                Text("Wird ab dem nächsten Diktat erfasst.").foregroundStyle(.secondary)
            }
            ForEach(apps.prefix(6)) { app in
                HStack(spacing: 10) {
                    appIcon(app.bundleID)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text("\(Double(app.count) / Double(known), format: .percent.precision(.fractionLength(0)).locale(german)) · \(app.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(app.count), total: Double(known)).tint(.teal)
                    }
                }
            }
        }
    }

    private var streakTile: some View {
        let perDay = usage.wordsPerDay
        let streaks = Usage.streaks(days: Set(perDay.keys), today: .now, calendar: .current)
        return Tile {
            header("\(days(streaks.current)) in Folge", detail: "Längste Serie | \(days(streaks.longest))")
            Heatmap(wordsPerDay: perDay)
        }
    }

    private var peakText: String {
        guard let peak = usage.peakSlot else { return "–" }
        return "\(Heatmap.calendar.weekdaySymbols[peak.weekday - 1]), \(peak.hour) Uhr"
    }

    private func days(_ count: Int) -> String { count == 1 ? "1 Tag" : "\(count) Tage" }

    /// Tiles side by side with equal heights.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) { content() }.fixedSize(horizontal: false, vertical: true)
    }

    private func big(_ value: Int) -> some View {
        Text(value, format: .number.locale(german)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption).tracking(0.8).foregroundStyle(.secondary)
    }

    private func line(_ value: Int, _ label: String) -> some View {
        Text("\(Text(value, format: .number.locale(german)).bold()) \(label)")
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.semibold))
            Spacer()
            caption(detail)
        }
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: "app").frame(width: 24, height: 24)
        }
    }
}

private struct Tile<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quinary, in: .rect(cornerRadius: 12))
    }
}

/// GitHub-style calendar of the last weeks, Monday on top.
private struct Heatmap: View {
    let wordsPerDay: [Date: Int]

    static let weeks = 20
    static let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.locale = german
        calendar.firstWeekday = 2
        return calendar
    }()
    private static let cell: CGFloat = 12
    private static let shades = [0.35, 0.55, 0.78, 1]

    var body: some View {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: .now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: 1 - Self.weeks, to: thisWeek)!
        let weekStarts = (0..<Self.weeks).map { calendar.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }
        let most = max(1, wordsPerDay.values.max() ?? 1)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(" ").font(.caption2)
                    ForEach(["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"], id: \.self) { name in
                        Text(name).font(.caption2).foregroundStyle(.secondary).frame(height: Self.cell)
                    }
                }
                .padding(.trailing, 4)
                ForEach(weekStarts.indices, id: \.self) { index in
                    let start = weekStarts[index]
                    VStack(spacing: 3) {
                        // Label a column when its month differs from the previous one; may overflow into the next column.
                        Text(index > 0 && calendar.component(.month, from: start) != calendar.component(.month, from: weekStarts[index - 1])
                             ? start.formatted(.dateTime.month(.abbreviated).locale(german)) : " ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: Self.cell, alignment: .leading)
                        ForEach(0..<7, id: \.self) { offset in
                            let day = calendar.date(byAdding: .day, value: offset, to: start)!
                            square(day: day, today: today, most: most)
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Text("Mehr")
                ForEach(Self.shades.reversed(), id: \.self) { shade in
                    RoundedRectangle(cornerRadius: 3).fill(Color.teal.opacity(shade)).frame(width: Self.cell, height: Self.cell)
                }
                Text("Weniger")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func square(day: Date, today: Date, most: Int) -> some View {
        let words = wordsPerDay[day] ?? 0
        let style: AnyShapeStyle = if day > today {
            AnyShapeStyle(.quinary)
        } else if words == 0 {
            AnyShapeStyle(.quaternary)
        } else {
            AnyShapeStyle(Color.teal.opacity(Self.shades[Int((4 * Double(words) / Double(most)).rounded(.up)) - 1]))
        }
        return RoundedRectangle(cornerRadius: 3)
            .fill(style)
            .frame(width: Self.cell, height: Self.cell)
            .help("\(day.formatted(.dateTime.day().month().locale(german))): \(words) Wörter")
    }
}

// MARK: - Settings

struct SettingsView: View {
    let controller: DictationController
    @AppStorage(DefaultsKey.autoOpenCorrection) private var autoOpenCorrection = false
    @AppStorage(DefaultsKey.historyLimit) private var historyLimit = 20
    @AppStorage(DefaultsKey.triggerKey) private var trigger = TriggerKey.rightCommand
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Bei Anmeldung automatisch starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Korrekturfenster nach jedem Diktat öffnen", isOn: $autoOpenCorrection)
            }
            Section {
                Picker("Auslösetaste", selection: $trigger) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.name.prefix(1).uppercased() + key.name.dropFirst())
                    }
                }
                if trigger == .fn {
                    Text("Damit die Taste nichts anderes auslöst: Systemeinstellungen → Tastatur → „🌐-Taste drücken für“ auf „Keine Aktion“ stellen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Verlauf") {
                Stepper("\(historyLimit) Diktate aufbewahren", value: $historyLimit, in: 1...200)
                    .onChange(of: historyLimit) { controller.trimHistory() }
                LabeledContent("Gespeichert", value: "\(controller.history.count)")
                Button("Verlauf löschen", role: .destructive) { controller.clearHistory() }
                Button("Statistik zurücksetzen", role: .destructive) { controller.usage.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
