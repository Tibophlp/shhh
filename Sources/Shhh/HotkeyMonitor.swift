import AppKit

/// Watches the right Command key globally.
///
/// Holding right ⌘ alone fires `onPress`, letting go fires `onRelease`.
/// If another key is pressed while right ⌘ is held (a normal shortcut like ⌘C),
/// `onCancel` fires instead and the release is ignored.
@MainActor
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private static let rightCommandKeyCode: UInt16 = 54
    private static let rightCommandDeviceMask: UInt = 0x10 // NX_DEVICERCMDKEYMASK

    private var monitors: [Any] = []
    private var isDown = false
    private var cancelled = false
    private var releaseCheck: Timer?

    var isRunning: Bool { !monitors.isEmpty }

    /// Needs the Accessibility permission to see keys pressed in other apps.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Removes the monitors, e.g. when the Accessibility permission is withdrawn: they stop
    /// receiving keys and have to be set up again once it's back.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if isDown, !cancelled {
            cancelled = true
            onCancel()
        }
        release()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == Self.rightCommandKeyCode:
            let down = event.modifierFlags.rawValue & Self.rightCommandDeviceMask != 0
            if down, !isDown {
                isDown = true
                cancelled = false
                watchForMissedRelease()
                onPress()
            } else if !down {
                release()
            }
        case .flagsChanged, .keyDown:
            // Any other key while right ⌘ is held means the user is doing a shortcut.
            if isDown, !cancelled {
                cancelled = true
                onCancel()
            }
        default:
            break
        }
    }

    private func release() {
        releaseCheck?.invalidate()
        releaseCheck = nil
        guard isDown else { return }
        isDown = false
        if !cancelled { onRelease() }
    }

    /// The release event can go missing (the Mac sleeping mid-hold, the keyboard grabbed by
    /// another app). Without this the microphone would stay on and the next press be ignored.
    private func watchForMissedRelease() {
        releaseCheck?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !NSEvent.modifierFlags.contains(.command) { self?.release() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseCheck = timer
    }
}
