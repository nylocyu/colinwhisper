import AppKit
import AVFoundation

enum DictationState: Equatable {
    case idle
    case starting
    case recording(since: Date)
    case processing
    case error(String)
    case notice(String)  // brief, non-error hint such as "unformatiert"
}

enum DefaultsKey {
    static let autoOpenCorrection = "autoOpenCorrection"
    static let historyLimit = "historyLimit"
    static let triggerKey = "triggerKey"
}

struct Permissions: Equatable {
    struct Missing: Identifiable {
        let name: String
        let settingsURL: URL
        var id: String { name }
    }

    var microphone: Bool
    var inputMonitoring: Bool
    var accessibility: Bool

    static func current() -> Permissions {
        Permissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted())
    }

    /// Triggers each system prompt once; afterwards the menu links to System Settings.
    static func requestMissing() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    var missing: [Missing] {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        var result: [Missing] = []
        if !microphone { result.append(Missing(name: "Mikrofon", settingsURL: URL(string: base + "Privacy_Microphone")!)) }
        if !inputMonitoring { result.append(Missing(name: "Eingabeüberwachung", settingsURL: URL(string: base + "Privacy_ListenEvent")!)) }
        if !accessibility { result.append(Missing(name: "Bedienungshilfen", settingsURL: URL(string: base + "Privacy_Accessibility")!)) }
        return result
    }
}

@Observable
final class DictationController {
    private(set) var state: DictationState = .idle {
        didSet { overlay.show(state) }
    }
    private(set) var permissions = Permissions.current()
    private(set) var formatterUnavailableReason: String?
    private(set) var history: [DictationResult] = DictationController.loadHistory()
    var lastResult: DictationResult? { history.first }

    let transcriber = Transcriber()
    let glossary = GlossaryStore()
    @ObservationIgnored let candidateMemory = CandidateMemory()
    @ObservationIgnored let windows = WindowManager()

    @ObservationIgnored private let formatter = Formatter()
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private var pressedAt = Date.distantPast
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    static let minimumDuration: TimeInterval = 0.4
    static let maximumDuration: TimeInterval = 120
    static let startTimeout: TimeInterval = 3
    // ponytail: fixed threshold — calibrate if quiet speech gets discarded or noise isn't.
    static let silenceThreshold: Float = 0.006  // peak RMS ≈ −44 dBFS

    func launch() {
        UserDefaults.standard.register(defaults: [DefaultsKey.historyLimit: 20, DefaultsKey.autoOpenCorrection: false])
        hotkey.onPress = { [weak self] in self?.keyDown() }
        hotkey.onRelease = { [weak self] in self?.keyUp() }
        hotkey.onInterrupt = { [weak self] in self?.interrupt() }

        Permissions.requestMissing()
        refresh()
        // Cheap poll: picks up permissions granted in System Settings and the LLM becoming ready.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Task { await transcriber.prepare() }
    }

    private func refresh() {
        let current = Permissions.current()
        if current != permissions { permissions = current }
        if current.inputMonitoring { hotkey.start() }
        let reason = formatter.unavailableReason
        if reason != formatterUnavailableReason { formatterUnavailableReason = reason }
    }

    // MARK: - Hotkey

    private var isCapturing: Bool {
        switch state {
        case .starting, .recording: true
        default: false
        }
    }

    private func keyDown() {
        guard !isCapturing, state != .processing else { return }
        refresh()
        if !permissions.missing.isEmpty {
            let names = permissions.missing.map(\.name).joined(separator: ", ")
            return show(.error("Berechtigung fehlt: \(names)"))
        }
        switch transcriber.status {
        case .ready: break
        case .checking: return show(.error("Sprachmodell wird noch geprüft"))
        case .downloading(let progress): return show(.error("Sprachmodell wird geladen (\(Int(progress * 100)) %)"))
        case .failed(let message): return show(.error("Sprachmodell: \(message)"))
        }

        clearTask?.cancel()
        pressedAt = Date()
        state = .starting
        formatter.prewarm()
        audio.start(
            format: transcriber.audioFormat,
            onFirstBuffer: { [weak self] in
                guard let self, state == .starting else { return }
                state = .recording(since: Date())
            },
            onLevel: { [weak self] level in
                guard let self, isCapturing else { return }
                overlay.model.level = level
            },
            onFailure: { [weak self] message in self?.abort(message) })

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startTimeout))
            guard !Task.isCancelled else { return }
            if self?.state == .starting {
                self?.abort("Mikrofon startet nicht")
                return
            }
            try? await Task.sleep(for: .seconds(Self.maximumDuration - Self.startTimeout))
            guard !Task.isCancelled else { return }
            log.info("maximum duration reached")
            self?.keyUp()
        }
    }

    private func keyUp() {
        guard isCapturing else { return }
        let recording = stopCapture()
        let held = Date().timeIntervalSince(pressedAt)
        // Accidental taps: discard without any feedback.
        guard held >= Self.minimumDuration, recording.duration >= Self.minimumDuration else {
            state = .idle
            return
        }
        // Silence only: no transcription, no LLM — avoids hallucinations on empty audio.
        guard recording.peakRMS >= Self.silenceThreshold else {
            return show(.error("Nichts gehört – ist das richtige Mikrofon aktiv?"))
        }
        state = .processing
        Task { await process(recording) }
    }

    /// Another key while holding the trigger means a shortcut like ⌘C — drop the recording silently.
    private func interrupt() {
        guard isCapturing else { return }
        _ = stopCapture()
        state = .idle
    }

    private func abort(_ message: String) {
        guard isCapturing else { return }
        _ = stopCapture()
        show(.error(message))
    }

    private func stopCapture() -> AudioCapture.Recording {
        watchdog?.cancel()
        overlay.model.level = 0
        return audio.stop()
    }

    // MARK: - Pipeline

    private func process(_ recording: AudioCapture.Recording) async {
        let formatter = formatter.unavailableReason == nil ? self.formatter : nil
        let result: DictationResult
        do {
            result = try await Pipeline.run(
                buffers: recording.buffers, duration: recording.duration,
                transcriber: transcriber, glossary: glossary, formatter: formatter)
        } catch {
            return show(.error(error.localizedDescription))
        }
        addToHistory(result)
        state = .idle

        guard AXIsProcessTrusted() else {
            TextInserter.copy(result.formattedText)
            return show(.error("Einfügen nicht erlaubt (Bedienungshilfen) – Text liegt in der Zwischenablage"))
        }
        await TextInserter.paste(result.formattedText)
        if result.usedFallback, formatter != nil { show(.notice("unformatiert")) }
        if UserDefaults.standard.bool(forKey: DefaultsKey.autoOpenCorrection) { showCorrection() }
    }

    private func show(_ newState: DictationState) {
        state = newState
        clearTask?.cancel()
        let delay: Double = if case .notice = newState { 1.5 } else { 3 }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, state == newState else { return }
            state = .idle
        }
    }

    // MARK: - Menu actions

    func pasteLast() {
        guard let text = lastResult?.formattedText else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(250))  // let the menu close and focus return
            guard AXIsProcessTrusted() else {
                TextInserter.copy(text)
                return show(.error("Einfügen nicht erlaubt (Bedienungshilfen) – Text liegt in der Zwischenablage"))
            }
            await TextInserter.paste(text)
        }
    }

    func copyLast() {
        if let text = lastResult?.formattedText { TextInserter.copy(text) }
    }

    func showCorrection() {
        windows.show("correction", title: "Korrektur") {
            CorrectionView(result: lastResult, glossary: glossary, memory: candidateMemory)
        }
    }

    func showGlossary() {
        windows.show("glossary", title: "Glossar") { GlossaryView(store: glossary) }
    }

    func showSettings() {
        windows.show("settings", title: "Einstellungen") { SettingsView(controller: self) }
    }

    // MARK: - History (local only, capped, audio never stored)

    private static let historyURL = AppFiles.url(for: "history.json")

    private static func loadHistory() -> [DictationResult] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([DictationResult].self, from: data)) ?? []
    }

    private func addToHistory(_ result: DictationResult) {
        history.insert(result, at: 0)
        trimHistory()
    }

    func trimHistory() {
        let limit = max(1, UserDefaults.standard.integer(forKey: DefaultsKey.historyLimit))
        if history.count > limit { history.removeLast(history.count - limit) }
        do {
            try JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
        } catch {
            log.error("saving history failed: \(error.localizedDescription)")
        }
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    // MARK: - Menu bar presentation

    var menuIcon: String {
        if !permissions.missing.isEmpty { return "mic.slash" }
        return switch state {
        case .idle, .notice: "mic"
        case .starting: "ellipsis.circle"
        case .recording: "mic.fill"
        case .processing: "waveform"
        case .error: "exclamationmark.triangle"
        }
    }

    func statusText(trigger: TriggerKey) -> String {
        if !permissions.missing.isEmpty { return "Berechtigung fehlt" }
        return switch transcriber.status {
        case .checking: "Sprachmodell wird geprüft…"
        case .downloading(let progress): "Sprachmodell wird geladen … \(Int(progress * 100)) %"
        case .failed(let message): "Sprachmodell: \(message)"
        case .ready: "Bereit – \(trigger.name) halten"
        }
    }
}
