import AppKit

/// Watches the right Command key globally.
///
/// Holding right ⌘ alone fires `onPress`, letting go fires `onRelease`.
/// If another key is pressed while right ⌘ is held (a normal shortcut like ⌘C),
/// `onCancel` fires instead and the release is ignored.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private static let rightCommandKeyCode: UInt16 = 54
    private static let rightCommandDeviceMask: UInt = 0x10 // NX_DEVICERCMDKEYMASK

    private var monitors: [Any] = []
    private var isDown = false
    private var cancelled = false

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == Self.rightCommandKeyCode:
            let down = event.modifierFlags.rawValue & Self.rightCommandDeviceMask != 0
            if down, !isDown {
                isDown = true
                cancelled = false
                onPress()
            } else if !down, isDown {
                isDown = false
                if !cancelled { onRelease() }
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
}
