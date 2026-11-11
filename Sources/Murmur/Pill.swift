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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 112),
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
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 22))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()

    var body: some View {
        ZStack {
            content
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            HStack(spacing: -4) {
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
                // Success needs no badge: the text appearing is the confirmation. The orb just settles and fades.
                orb(thinking: true)
            } else {
                // Words only, on dark glass. No icon: the message is short enough to read at a glance.
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .modifier(DarkGlass(shape: Capsule()))
                    .accessibilityLabel(good ? message : "Problem: \(message)")
            }
        }
    }

    private func orb(thinking: Bool) -> some View {
        // Redrawn every display frame while visible. Hidden, the timeline does not exist.
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let _ = motion.step(toward: model.voice, at: timeline.date, thinking: thinking)
            OrbView(energy: reduceMotion ? (thinking ? 0.2 : model.voice) : motion.energy, phases: motion.phases)
        }
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
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
                .modifier(ButtonSurface(prominent: prominent, hovering: hovering))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ButtonSurface: ViewModifier {
    let prominent: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        if prominent {
            content
                .background(Circle().fill(Theme.accent).shadow(color: .black.opacity(0.35), radius: 6, y: 3))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        } else {
            content
                .background(Circle().fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .modifier(DarkGlass(shape: Circle()))
        }
    }
}

/// Dark, slightly translucent glass: Apple's Liquid Glass where the system has it (macOS 26+),
/// a blurred HUD material with a hairline edge everywhere else.
struct DarkGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(Color.black.opacity(0.62)), in: shape)
            } else {
                content
                    .background(HUDMaterial().clipShape(shape))
                    .background(shape.fill(Color.black.opacity(0.35)))
                    .overlay(shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.6))
            }
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
