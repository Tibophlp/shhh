import AppKit
import SwiftUI

/// The small pill at the bottom of the screen. Only visible while recording or transcribing.
@MainActor
final class RecordingPanel {
    private let model = PillModel()
    private lazy var panel: NSPanel = makePanel()
    /// Bumped on every show so a fade-out that finishes late can't hide a newer pill.
    private var generation = 0
    /// Whether the pill is up (or fading in). False as soon as a fade-out starts.
    private var isShown = false

    func showRecording() {
        model.mode = .recording
        model.levels = Array(repeating: 0, count: PillModel.barCount)
        present()
    }

    func showProcessing() {
        model.mode = .processing
        present() // normally already up; covers a recording pill that missed its cue
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        let hiding = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                guard self.generation == hiding else { return }
                self.panel.orderOut(nil)
                self.model.mode = .idle // the processing dots would keep animating off screen
            }
        }
    }

    private func present() {
        guard !isShown else { return }
        isShown = true
        generation += 1
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// Feed microphone loudness (0...1). Called from the audio thread.
    nonisolated func push(level: Float) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.append(level: level) }
        }
    }

    private func append(level: Float) {
        guard model.mode == .recording else { return }
        model.levels.removeFirst()
        model.levels.append(CGFloat(level))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }

    /// Bottom-centre of the screen the mouse is on.
    private func position() {
        let mouse = NSEvent.mouseLocation
        // NSMouseInRect, not contains: the mouse can sit on a screen's top edge (the menu bar),
        // which contains() leaves out, and the pill would land on another display.
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 18))
    }
}

final class PillModel: ObservableObject {
    enum Mode { case idle, recording, processing }
    static let barCount = 11
    @Published var mode: Mode = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            if model.mode == .recording {
                HStack(spacing: 3) {
                    ForEach(0..<model.levels.count, id: \.self) { i in
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 3, height: 4 + model.levels[i] * 14)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: model.levels)
            } else if model.mode == .processing {
                ProcessingDots()
            }
        }
        .frame(width: 96, height: 30)
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
        }
    }
}
