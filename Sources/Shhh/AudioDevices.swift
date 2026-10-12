import CoreAudio
import IOKit

/// A microphone the user can pick.
struct AudioInput: Equatable {
    enum Kind { case builtIn, external, iPhone }

    let id: AudioDeviceID
    let uid: String
    let name: String
    let kind: Kind
}

/// Lists microphones and picks the right one.
///
/// Automatic mode: headphones or another external mic first (AirPods, USB, headset jack).
/// Otherwise the Mac's own microphone, or, when the lid is closed and that mic is
/// switched off, the iPhone's microphone (Continuity).
enum AudioDevices {
    /// Real microphones, without virtual devices (Teams, Zoom, loopback drivers…).
    static func inputs() -> [AudioInput] {
        deviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            let transport = transportType(id)
            let kind: AudioInput.Kind
            switch transport {
            case "virt", "grup", "fgrp":
                return nil
            case "ccwd", "ccwl", "cctp":
                kind = .iPhone
            case "bltn":
                // The headphone-jack mic is reported as built-in too.
                kind = name(id).localizedCaseInsensitiveContains("external") ? .external : .builtIn
            default:
                kind = .external // Bluetooth (AirPods), USB, webcam, monitor, …
            }
            return AudioInput(id: id, uid: uid(id), name: name(id), kind: kind)
        }
    }

    /// Everything needed to pick a microphone, read from Core Audio in one go.
    /// Core Audio calls can block when a device misbehaves, so never take this on the main thread
    /// without a timeout (see `AppDelegate.refreshMicrophones` and `AudioRecorder`).
    struct Snapshot {
        static let empty = Snapshot(inputs: [], lidClosed: false, systemDefault: 0)

        let inputs: [AudioInput]
        let lidClosed: Bool
        let systemDefault: AudioDeviceID

        func isAvailable(_ input: AudioInput) -> Bool {
            !(input.kind == .builtIn && lidClosed)
        }

        /// The device to record from. `preferredUID` is the user's choice (nil = Automatic).
        func pick(preferredUID: String?) -> AudioInput? {
            if let preferredUID, let chosen = inputs.first(where: { $0.uid == preferredUID }), isAvailable(chosen) {
                return chosen
            }
            let externals = inputs.filter { $0.kind == .external }
            if let external = externals.first(where: { $0.id == systemDefault }) ?? externals.first {
                return external
            }
            if lidClosed {
                return inputs.first { $0.kind == .iPhone }
            }
            return inputs.first { $0.kind == .builtIn } ?? inputs.first
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(inputs: inputs(), lidClosed: isLidClosed, systemDefault: defaultInputID())
    }

    /// The device to record from. `preferredUID` is the user's choice (nil = Automatic).
    static func resolve(preferredUID: String?) -> AudioInput? {
        snapshot().pick(preferredUID: preferredUID)
    }

    /// True when a MacBook's lid is closed (clamshell mode). Its microphone is then switched off.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: - Core Audio

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputID() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        stringProperty(id, kAudioObjectPropertyName) ?? "Microphone"
    }

    private static func uid(_ id: AudioDeviceID) -> String {
        stringProperty(id, kAudioDevicePropertyDeviceUID) ?? String(id)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Four-character transport code, e.g. "bltn" (built-in), "blue" (Bluetooth), "ccwl" (iPhone).
    private static func transportType(_ id: AudioDeviceID) -> String {
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type)
        let bytes = [24, 16, 8, 0].map { UInt8((type >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
