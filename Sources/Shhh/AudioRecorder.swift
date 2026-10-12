import AudioToolbox
import AVFoundation

/// Records a microphone as 16 kHz mono Float32, the format the speech model expects.
///
/// Every Core Audio / AVAudioEngine call runs on a background queue behind a watchdog. If the
/// audio system hangs (it can, when a device drops out mid-handshake), recording fails with a
/// beep instead of freezing the app, and the next recording starts on a fresh queue.
@MainActor
final class AudioRecorder {
    /// Called on the audio thread with a 0...1 loudness value, for the waveform.
    var onLevel: (@Sendable (Float) -> Void)?

    private var queue = AudioRecorder.makeQueue()
    private var session: RecordingSession?
    private var starting = false

    /// Picks the microphone and starts recording. `preferredUID` nil means Automatic.
    @discardableResult
    func start(preferredUID: String?, timeout: TimeInterval = 2.5) async throws -> AudioInput {
        guard session == nil, !starting else { throw RecorderError.busy }
        starting = true
        defer { starting = false }

        let session = RecordingSession(onLevel: onLevel)
        let queue = self.queue
        do {
            let input = try await runWithWatchdog(on: queue, timeout: timeout) {
                try session.start(preferredUID: preferredUID)
            }
            self.session = session
            return input
        } catch WatchdogError.timedOut {
            // That queue is stuck inside Core Audio. Abandon it; if the call ever returns,
            // the queued stop cleans up the engine it started.
            self.queue = Self.makeQueue()
            queue.async { session.stop() }
            throw WatchdogError.timedOut
        }
    }

    /// Some microphones deliver audio late: the iPhone's (Continuity) starts about 3 s behind but
    /// then sends everything. Keep listening until the audio covers how long the key was held.
    func stop(covering duration: TimeInterval, timeout: TimeInterval = 4) async -> [Float] {
        guard let session else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        while session.capturedSeconds < duration - 0.25, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        self.session = nil
        let samples = session.samples
        queue.async { session.stop() } // never wait on the audio system from here
        return samples
    }

    /// Stops and throws away the recording.
    func cancel() {
        guard let session else { return }
        self.session = nil
        queue.async { session.stop() }
    }

    private static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "shhh.audio", qos: .userInteractive)
    }

    enum RecorderError: LocalizedError {
        case noMicrophone, busy
        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone available"
            case .busy: "Already recording"
            }
        }
    }
}

/// One recording: an engine, its converter and the captured samples.
/// `start` and `stop` run on the recorder's queue; `samples` and `capturedSeconds` are thread-safe.
private final class RecordingSession: @unchecked Sendable {
    private let onLevel: (@Sendable (Float) -> Void)?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(onLevel: (@Sendable (Float) -> Void)?) {
        self.onLevel = onLevel
    }

    var samples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / targetFormat.sampleRate
    }

    func start(preferredUID: String?) throws -> AudioInput {
        guard let input = AudioDevices.resolve(preferredUID: preferredUID) else {
            throw AudioRecorder.RecorderError.noMicrophone
        }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        var deviceID = input.id
        if let unit = node.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioRecorder.RecorderError.noMicrophone }
        }
        // Tap in the microphone's own format (after switching devices the node's output format
        // can be stale and the engine refuses to start). Converted to 16 kHz per buffer below.
        let format = node.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorder.RecorderError.noMicrophone }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        return input
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func process(_ pcm: AVAudioPCMBuffer) {
        if let channel = pcm.floatChannelData?[0], pcm.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(pcm.frameLength) { sum += channel[i] * channel[i] }
            onLevel?(min(1, sqrt(sum / Float(pcm.frameLength)) * 12))
        }

        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        lock.lock()
        buffer.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        lock.unlock()
    }
}
