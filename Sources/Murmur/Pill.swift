import AppKit
import SwiftUI
import Combine

/// The floating capsule shown while dictating. It never takes focus, so typing continues
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            content
                .padding(.horizontal, 6)
                .frame(height: 36)
                .background(
                    Capsule().fill(background)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 12, y: 5)
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 0.5))
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: Color {
        scheme == .dark ? Color(white: 0.11).opacity(0.96) : Color(white: 0.99).opacity(0.97)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            HStack(spacing: 8) {
                PillButton(symbol: "xmark", help: "Cancel (Esc)") { Dictation.shared.cancel() }
                Waveform(levels: model.levels)
                    .frame(width: 96, height: 20)
                Text(model.started, style: .timer)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                PillButton(symbol: handsFree ? "stop.fill" : "checkmark", help: "Finish", prominent: handsFree) {
                    Dictation.shared.finish()
                }
            }
        case .thinking:
            HStack(spacing: 8) {
                ThinkingDots()
                Text("Transcribing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        case .notice(let message, let good):
            HStack(spacing: 7) {
                Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(good ? Theme.accent : Color.secondary)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, message.isEmpty ? 4 : 10)
        }
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
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(hovering ? 0.9 : 0.5))
                .frame(width: 24, height: 24)
                .background(Circle().fill(prominent ? Theme.accent : Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Bars that follow the microphone. Redrawn only when a new level arrives.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for (i, level) in levels.enumerated() {
                // Newer bars are stronger; older ones fade toward the left.
                let age = CGFloat(i) / CGFloat(count - 1)
                let height = max(2.5, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.primary.opacity(0.25 + 0.6 * age)))
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
        .accessibilityHidden(true)
    }
}

private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The timeline exists only while this view is on screen.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.primary.opacity(reduceMotion ? 0.6 : 0.3 + 0.5 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9))))
                        .frame(width: 4.5, height: 4.5)
                }
            }
        }
    }
}
