import AudioToolbox
import AVFoundation

/// Records a microphone as 16 kHz mono Float32, the format the speech model expects.
final class AudioRecorder {
    /// Called on the audio thread with a 0...1 loudness value, for the waveform.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Starts recording from `deviceID`, or from the system default microphone when nil.
    func start(deviceID: AudioDeviceID? = nil) throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        converter = nil

        // A fresh engine each time picks up microphone changes (AirPods connected, etc.).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw RecorderError.noMicrophone }
        }
        // Tap in the microphone's own format (after switching devices the node's output format
        // can be stale and the engine refuses to start). Converted to 16 kHz per buffer below.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Seconds of audio received so far.
    var capturedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / targetFormat.sampleRate
    }

    /// Some microphones deliver audio late: the iPhone's (Continuity) starts about 3 s behind but
    /// then sends everything. Keep listening until the audio covers how long the key was held.
    func stop(covering duration: TimeInterval, timeout: TimeInterval = 4) async -> [Float] {
        let deadline = Date().addingTimeInterval(timeout)
        while capturedSeconds < duration - 0.25, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await MainActor.run { stop() }
    }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            onLevel?(min(1, rms * 12))
        }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
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
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        lock.unlock()
    }

    enum RecorderError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone available" }
    }
}
