import AppKit
import AVFoundation
import ServiceManagement

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
    private var lastTranscript: String?

    private var speechStatus = "Loading speech model…"
    private var cleanupStatus: String?

    private enum State { case idle, recording, processing }

    private var aiCleanup: Bool {
        get { UserDefaults.standard.bool(forKey: "aiCleanup") }
        set { UserDefaults.standard.set(newValue, forKey: "aiCleanup") }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Shhh")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        recorder.onLevel = { [weak self] in self?.panel.push(level: $0) }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        waitForAccessibility()
        loadSpeechModel()
        if aiCleanup { loadCleanupModel() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // llama.cpp must release its GPU resources before the process exits.
        Task {
            await cleaner.unload()
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func waitForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            hotkey.start()
            return
        }
        // Keyboard monitoring only works once the permission is granted, so check again until it is.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.hotkey.start()
        }
    }

    private func loadSpeechModel() {
        Task {
            do {
                try await transcriber.load { [weak self] fraction in
                    DispatchQueue.main.async { self?.speechStatus = "Downloading speech model… \(Int(fraction * 100))%" }
                }
                await MainActor.run { speechStatus = "Hold right ⌘ to dictate" }
            } catch {
                await MainActor.run { speechStatus = "Speech model failed to load. Check your connection and relaunch." }
            }
        }
    }

    private func loadCleanupModel() {
        cleanupStatus = TextCleaner.isDownloaded ? "loading…" : "downloading…"
        Task {
            do {
                try await cleaner.load { [weak self] fraction in
                    DispatchQueue.main.async { self?.cleanupStatus = "downloading \(Int(fraction * 100))%" }
                }
                await MainActor.run { cleanupStatus = nil }
            } catch {
                await MainActor.run { cleanupStatus = "failed to load" }
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        guard state == .idle else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSSound.beep()
            return
        }
        do {
            try recorder.start()
        } catch {
            NSSound.beep()
            return
        }
        state = .recording
        pressedAt = Date()
        // Show the pill only for a real hold, not a quick tap of ⌘.
        let work = DispatchWorkItem { [weak self] in
            guard self?.state == .recording else { return }
            self?.panel.showRecording()
        }
        showPanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        _ = recorder.stop()
        panel.hide()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }
        showPanelWork?.cancel()
        let samples = recorder.stop()
        let heldFor = Date().timeIntervalSince(pressedAt)

        guard heldFor >= 0.3, samples.count >= 16_000 / 4 else {
            panel.hide()
            state = .idle
            return
        }

        state = .processing
        panel.showProcessing()
        let useCleanup = aiCleanup

        Task {
            var text = (try? await transcriber.transcribe(samples)) ?? ""
            if useCleanup, !text.isEmpty, await cleaner.isReady {
                text = await cleaner.clean(text)
            }
            let finalText = text
            await MainActor.run {
                let text = finalText
                if !text.isEmpty {
                    lastTranscript = text
                    TextInserter.insert(text)
                }
                panel.hide()
                state = .idle
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility access…", #selector(openAccessibilitySettings)))
        } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Grant Microphone access…", #selector(openMicrophoneSettings)))
        } else {
            let status = NSMenuItem(title: speechStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())

        let cleanupTitle = cleanupStatus.map { "AI cleanup (\($0))" } ?? "AI cleanup"
        let cleanup = item(cleanupTitle, #selector(toggleCleanup))
        cleanup.state = aiCleanup ? .on : .off
        menu.addItem(cleanup)

        let copy = item("Copy last transcript", #selector(copyLastTranscript))
        copy.isEnabled = lastTranscript != nil
        menu.addItem(copy)

        menu.addItem(.separator())
        let login = item("Launch at login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Shhh", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
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
