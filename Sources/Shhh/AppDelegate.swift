import AppKit
import AVFoundation
import ServiceManagement

/// Owns the menu-bar item and runs the dictation flow:
/// hold right ⌘ → record → transcribe → (cleanup) → writing style → paste.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let cleaner = TextCleaner()
    private let panel = RecordingPanel()

    private var statusItem: NSStatusItem!
    private var state: State = .idle
    private var pressedAt = Date()
    private var showPanelWork: DispatchWorkItem?
    private var startTask: Task<Bool, Never>?

    // Last known microphones, for the menu. Read off the main thread (see refreshMicrophones).
    private var microphones = AudioDevices.Snapshot.empty
    private var deviceQueue = DispatchQueue(label: "shhh.devices")
    private var deviceQueryStarted: Date?
    private var lastTranscript: String?

    private var speechReady = false
    private var speechStatus = "Loading speech model…"
    private var cleanupStatus: String?

    private enum State { case idle, recording, processing }

    // MARK: - Settings

    private var aiCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: "aiCleanup") }
        set { UserDefaults.standard.set(newValue, forKey: "aiCleanup") }
    }

    private var writingStyle: WritingStyle {
        get { WritingStyle(rawValue: UserDefaults.standard.string(forKey: "writingStyle") ?? "") ?? .casual }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "writingStyle") }
    }

    /// The microphone the user picked, or nil for Automatic.
    private var microphoneUID: String? {
        get { UserDefaults.standard.string(forKey: "microphoneUID") }
        set { UserDefaults.standard.set(newValue, forKey: "microphoneUID") }
    }

    // MARK: - Launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Shhh")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        recorder.onLevel = { [panel] in panel.push(level: $0) }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        startHotkeyWhenTrusted()
        refreshMicrophones(wait: 0)
        loadSpeechModel()
        if aiCleanup { loadCleanupModel() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // llama.cpp must release its GPU resources before the process exits.
        Task {
            await cleaner.unload()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Keyboard monitoring only works once Accessibility is granted, so keep checking until it is.
    private func startHotkeyWhenTrusted() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            hotkey.start()
            return
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.hotkey.start() }
        }
    }

    private func loadSpeechModel() {
        Task {
            do {
                try await transcriber.load { fraction in
                    Task { @MainActor in self.speechStatus = "Downloading speech model… \(Int(fraction * 100))%" }
                }
                speechReady = true
                speechStatus = "Hold right ⌘ to dictate"
            } catch {
                speechStatus = "Speech model failed to load. Check your connection and relaunch."
            }
        }
    }

    private func loadCleanupModel() {
        cleanupStatus = TextCleaner.isDownloaded ? "loading…" : "downloading…"
        Task {
            do {
                try await cleaner.load { fraction in
                    Task { @MainActor in
                        guard self.cleanupStatus != nil else { return }
                        self.cleanupStatus = "downloading \(Int(fraction * 100))%"
                    }
                }
                cleanupStatus = nil
                // Turned off while it was loading: free the memory again.
                if !aiCleanup { await cleaner.unload() }
            } catch {
                cleanupStatus = aiCleanup ? "failed to load" : nil
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        guard state == .idle else { return }
        guard speechReady, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSSound.beep() // the menu explains what's missing
            return
        }
        state = .recording
        pressedAt = Date()

        // The microphone starts on a background queue so the app never freezes on Core Audio.
        let preferredUID = microphoneUID
        startTask = Task {
            do {
                try await recorder.start(preferredUID: preferredUID)
                return true
            } catch {
                NSSound.beep() // no microphone, or the audio system didn't respond
                if state == .recording {
                    showPanelWork?.cancel()
                    panel.hide()
                    state = .idle
                }
                return false
            }
        }
        // Show the pill only for a real hold, not a quick tap of ⌘.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.panel.showRecording()
            }
        }
        showPanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        panel.hide()
        state = .idle
        let start = startTask
        Task { if await start?.value == true { recorder.cancel() } }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        let heldFor = Date().timeIntervalSince(pressedAt)

        guard heldFor >= 0.3 else {
            cancelRecording()
            return
        }

        state = .processing
        panel.showProcessing()
        let useCleanup = aiCleanup
        let style = writingStyle
        let start = startTask

        Task {
            defer {
                panel.hide()
                state = .idle
            }
            guard await start?.value == true else { return }
            let samples = await recorder.stop(covering: heldFor)
            guard samples.count >= 16_000 / 4 else { return }

            var text: String
            do {
                text = try await transcriber.transcribe(samples)
            } catch {
                NSSound.beep()
                return
            }
            if useCleanup, !text.isEmpty, await cleaner.isReady {
                text = await cleaner.clean(text)
            }
            text = style.apply(text)
            guard !text.isEmpty else { return }
            lastTranscript = text
            TextInserter.insert(text)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMicrophones(wait: 0.25)
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility access…", #selector(openAccessibilitySettings)))
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Grant Microphone access…", #selector(openMicrophoneSettings)))
        } else {
            let noMicrophone = speechReady && microphones.pick(preferredUID: microphoneUID) == nil
            let status = NSMenuItem(title: noMicrophone ? "No microphone available" : speechStatus,
                                    action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Writing style", items: WritingStyle.allCases.map { style in
            let item = item(style.title, #selector(selectWritingStyle(_:)))
            item.representedObject = style.rawValue
            item.state = style == writingStyle ? .on : .off
            return item
        }))
        menu.addItem(microphoneMenu())

        let cleanup = item(cleanupStatus.map { "AI cleanup (\($0))" } ?? "AI cleanup", #selector(toggleCleanup))
        cleanup.state = aiCleanup ? .on : .off
        menu.addItem(cleanup)

        let copy = item("Copy last transcript", #selector(copyLastTranscript))
        copy.isEnabled = lastTranscript != nil
        menu.addItem(copy)

        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit Shhh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// "Automatic (AirPods Pro)" followed by every connected microphone.
    private func microphoneMenu() -> NSMenuItem {
        let inputs = microphones.inputs
        let active = microphones.pick(preferredUID: microphoneUID)
        let chosenIsAvailable = inputs.contains { $0.uid == microphoneUID && microphones.isAvailable($0) }

        let automatic = item("Automatic (\(active?.name ?? "no microphone"))", #selector(selectMicrophone(_:)))
        automatic.state = chosenIsAvailable ? .off : .on

        var items = [automatic, .separator()]
        for input in inputs {
            let unavailable = !microphones.isAvailable(input)
            let item = item(unavailable ? "\(input.name) (lid closed)" : input.name, #selector(selectMicrophone(_:)))
            item.representedObject = input.uid
            item.isEnabled = !unavailable
            item.state = chosenIsAvailable && input.uid == microphoneUID ? .on : .off
            items.append(item)
        }
        return submenu("Microphone", items: items)
    }

    /// Reads the microphone list on a background queue and waits at most `wait` for it, so a
    /// misbehaving audio device can never freeze the menu. Falls back to the last known list.
    private func refreshMicrophones(wait: TimeInterval) {
        if let started = deviceQueryStarted {
            guard Date().timeIntervalSince(started) > 5 else { return } // a read is already running
            deviceQueue = DispatchQueue(label: "shhh.devices") // that one is stuck: start over
        }
        deviceQueryStarted = Date()
        let result = SnapshotBox()
        let done = DispatchSemaphore(value: 0)
        deviceQueue.async {
            result.set(AudioDevices.snapshot())
            done.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let snapshot = result.get() { self.microphones = snapshot }
                    self.deviceQueryStarted = nil
                }
            }
        }
        if done.wait(timeout: .now() + wait) == .success, let snapshot = result.get() {
            microphones = snapshot
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    // MARK: - Menu actions

    @objc private func selectWritingStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = WritingStyle(rawValue: raw) {
            writingStyle = style
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        microphoneUID = sender.representedObject as? String
    }

    @objc private func toggleCleanup() {
        aiCleanup.toggle()
        if aiCleanup {
            loadCleanupModel()
        } else {
            cleanupStatus = nil
            Task { await cleaner.unload() } // free the memory while it's off
        }
    }

    @objc private func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

/// Hands a snapshot from the device queue to the main thread.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AudioDevices.Snapshot?

    func set(_ snapshot: AudioDevices.Snapshot) { lock.lock(); value = snapshot; lock.unlock() }
    func get() -> AudioDevices.Snapshot? { lock.lock(); defer { lock.unlock() }; return value }
}
