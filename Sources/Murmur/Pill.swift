import AppKit
import SwiftUI
import Combine

/// The floating orb shown while dictating. It never takes focus, so typing continues
/// to land in the app underneath.
final class PillController {
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private let model: PillModel

    init(model: PillModel) {
        self.model = model
        subscription = model.$phase.removeDuplicates().sink { [weak self] phase in
            DispatchQueue.main.async { self?.apply(phase) }
        }
    }

    private func apply(_ phase: PillModel.Phase) {
        if phase == .hidden { hide() } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Drop the whole view tree: nothing left to animate or redraw while idle.
            if self?.model.phase == .hidden {
                panel.orderOut(nil)
                self?.panel = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 84),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 36))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The last few microphone readings averaged, so the ripple swells rather than jumps.
    private var level: CGFloat {
        let recent = model.levels.suffix(3)
        return CGFloat(recent.reduce(0, +)) / CGFloat(max(recent.count, 1))
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            HStack(spacing: 10) {
                // Holding the key needs no buttons: letting go is "done", Esc is "cancel".
                if handsFree {
                    PillButton(symbol: "xmark", help: "Cancel (Esc)") { Dictation.shared.cancel() }
                }
                orb(thinking: false)
                if handsFree {
                    PillButton(symbol: "stop.fill", help: "Finish", prominent: true) { Dictation.shared.finish() }
                }
            }
        case .thinking:
            orb(thinking: true)
        case .notice(let message, let good):
            if message.isEmpty {
                orb(thinking: true)
                    .overlay(Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3))
            } else {
                HStack(spacing: 7) {
                    Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(good ? Theme.accent : Color.white.opacity(0.6))
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Color(white: 0.09).opacity(0.96))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 5))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            }
        }
    }

    private func orb(thinking: Bool) -> some View {
        // The timeline exists only while the orb is on screen; hidden, nothing ticks.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            OrbView(level: level, time: reduceMotion ? 0.8 : timeline.date.timeIntervalSinceReferenceDate, thinking: thinking)
        }
        .frame(width: 58, height: 58)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }
}

private struct PillButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(prominent || hovering ? 1 : 0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(prominent ? Theme.accent : Color(white: hovering ? 0.22 : 0.12).opacity(0.95))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
