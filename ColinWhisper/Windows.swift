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
