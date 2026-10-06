import AppKit
import SwiftUI

@Observable
final class OverlayModel {
    var state: DictationState = .idle
    var level: Float = 0
}

/// Never becomes key or main: taking focus would lose the cursor in the target app.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let model = OverlayModel()
    private var visible = false

    private lazy var panel: NSPanel = {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 72),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []  // fixed panel; content centers itself
        panel.contentView = host
        return panel
    }()

    func show(_ state: DictationState) {
        guard state != .idle else { return hide() }
        model.state = state
        guard !visible else { return }
        visible = true
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()  // front without activating or becoming key
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if !self.visible { self.panel.orderOut(nil) }
            }
        }
    }

    /// Bottom center of the screen the user is working on; the capsule (centered in the
    /// 72 pt panel) ends up ~44 pt above the bottom edge / Dock.
    private func position() {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 26))
    }
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .idle:
                EmptyView()
            case .starting:
                ProgressView().controlSize(.small)
                Text("Moment…")
            case .recording(let since):
                LevelBars(level: model.level)
                Text("Aufnahme")
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .processing:
                ProgressView().controlSize(.small)
                Text("Verarbeiten…")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                Text(message).lineLimit(2)
            case .notice(let message):
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.45, 0.7, 0.9, 1, 0.9, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3, height: 4 + 16 * weights[index] * CGFloat(level))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
