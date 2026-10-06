import Accelerate
import AVFoundation

/// Stage 1. The engine runs only while the key is held (no permanent mic indicator).
/// Audio stays in memory, converted to the transcriber's format, and is never written to disk.
nonisolated final class AudioCapture: @unchecked Sendable {
    struct Recording: @unchecked Sendable {  // buffers are never mutated after capture
        let buffers: [AVAudioPCMBuffer]
        let duration: TimeInterval
        let peakRMS: Float
    }

    enum CaptureError: LocalizedError {
        case noInput, unsupportedFormat
        var errorDescription: String? {
            switch self {
            case .noInput: "Kein Mikrofon verfügbar"
            case .unsupportedFormat: "Mikrofonformat wird nicht unterstützt"
            }
        }
    }

    typealias Callback = @MainActor @Sendable () -> Void

    // Engine setup/teardown happens on this queue so starting (which can take a few
    // hundred ms, longer with Bluetooth) never blocks the main thread.
    private let queue = DispatchQueue(label: "com.colinportisch.ColinWhisper.audio")
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var observer: NSObjectProtocol?

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []   // guarded by lock
    private var frames: AVAudioFramePosition = 0   // guarded by lock
    private var peak: Float = 0                    // guarded by lock
    private var targetRate: Double = 16_000        // guarded by lock

    /// Callbacks arrive on the main actor. `onFirstBuffer` fires once audio really flows —
    /// only then may the UI say "recording".
    func start(
        format target: AVAudioFormat,
        onFirstBuffer: @escaping Callback,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        lock.withLock {
            buffers = []
            frames = 0
            peak = 0
            targetRate = target.sampleRate
        }
        queue.async { [self] in
            do {
                try startEngine(target: target, onFirstBuffer: onFirstBuffer, onLevel: onLevel, onFailure: onFailure)
            } catch {
                teardown()
                let message = error.localizedDescription
                Task { @MainActor in onFailure(message) }
            }
        }
    }

    /// Stops the engine and hands over everything captured so far.
    func stop() -> Recording {
        queue.sync { teardown() }
        return lock.withLock {
            let recording = Recording(buffers: buffers, duration: Double(frames) / targetRate, peakRMS: peak)
            buffers = []
            return recording
        }
    }

    private func startEngine(
        target: AVAudioFormat,
        onFirstBuffer: @escaping Callback,
        onLevel: @escaping @MainActor @Sendable (Float) -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw CaptureError.unsupportedFormat }
        converter.downmix = true
        self.converter = converter
        self.engine = engine

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, to: target) else { return }
            let rms = Self.rms(buffer)
            let isFirst = self.lock.withLock {
                self.buffers.append(converted)
                self.frames += AVAudioFramePosition(converted.frameLength)
                self.peak = max(self.peak, rms)
                return self.buffers.count == 1
            }
            let level = Self.normalized(rms)
            Task { @MainActor in
                if isFirst { onFirstBuffer() }
                onLevel(level)
            }
        }

        // Device switched mid-recording → abort cleanly. Changes before the first buffer
        // (e.g. Bluetooth headsets switching profile on start) are left to the start timeout.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, self.lock.withLock({ !self.buffers.isEmpty }) else { return }
            Task { @MainActor in onFailure("Audiogerät hat gewechselt") }
        }

        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine = nil
        converter = nil
        observer = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // The input block is @Sendable in the SDK but runs synchronously inside convert().
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        // .noDataNow (not .endOfStream) keeps the resampler's state across buffers.
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { log.error("audio conversion failed: \(error.localizedDescription)") }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }

    /// Maps −50 dB…−10 dB to 0…1 for the level meter.
    private static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(max((20 * log10(rms) + 50) / 40, 0), 1)
    }
}
