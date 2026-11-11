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
        // Already up, possibly mid-fade from the last dictation: bring it back rather than restart.
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            // A slow, easing fade: the orb keeps moving and sinks away rather than blinking off.
            context.duration = 0.55
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 124),
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
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 4))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()
    /// What was last on screen, kept drawn while the panel fades out.
    @State private var lastShown: PillModel.Phase = .hidden
    @AppStorage(Prefs.Key.orbStyle) private var styleName = OrbStyle.mercury.rawValue

    private var shown: PillModel.Phase { model.phase == .hidden ? lastShown : model.phase }

    private var handsFree: Bool { if case .listening(true) = shown { return true } else { return false } }
    private var listening: Bool { if case .listening = shown { return true } else { return false } }
    private var problem: Bool { if case .notice(_, false) = shown { return true } else { return false } }

    private var label: String {
        switch shown {
        case .hidden: return ""
        case .listening: return "Listening"
        case .thinking: return "Transcribing"
        case .notice(let message, _): return message.isEmpty ? "Done" : message
        }
    }

    var body: some View {
        Group {
            if OrbStyle(rawValue: styleName) == .halftone { halftone } else { mercury }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: shown)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { lastShown = model.phase }
        .onChange(of: model.phase) { _, phase in
            if phase != .hidden { lastShown = phase }
        }
    }

    /// The halftone globe never moves: it stays in the centre and a quiet line beneath it says
    /// what is happening. A problem turns it red and breaks it in two.
    private var halftone: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if handsFree {
                    PillButton(symbol: "xmark", help: "Cancel (Esc)") { Dictation.shared.cancel() }
                        .transition(.opacity)
                }
                MercuryOrb(motion: motion, model: model, thinking: !listening, alert: problem, still: reduceMotion, style: .halftone)
                    .frame(width: 92, height: 92)
                if handsFree {
                    PillButton(symbol: "stop.fill", help: "Finish", prominent: true) { Dictation.shared.finish() }
                        .transition(.opacity)
                }
            }
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(problem ? 0.96 : 0.78))
                .shadow(color: .black.opacity(0.9), radius: 2.5, y: 1)
                .shadow(color: .black.opacity(0.55), radius: 9)
                .lineLimit(1)
                .fixedSize()
                .id(label)
                .transition(.opacity)
                .offset(y: -4)
                .accessibilityLabel(problem ? "Problem: \(label)" : label)
        }
    }

    private var mercury: some View {
        // While you speak the orb stands alone in the centre. When you finish it shrinks and slides
        // to the left as a dark glass capsule opens beside it, saying what is happening.
        HStack(spacing: listening ? 8 : 10) {
            if handsFree {
                PillButton(symbol: "xmark", help: "Cancel (Esc)") { Dictation.shared.cancel() }
                    .transition(.opacity)
            }

            MercuryOrb(motion: motion, model: model, thinking: !listening, alert: problem, still: reduceMotion)
                .frame(width: listening ? 76 : 40, height: listening ? 76 : 40)
                .background(Circle().fill(.black.opacity(0.5)).blur(radius: 5).offset(y: 3))

            if !listening {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(problem ? 0.92 : 0.62))
                    .lineLimit(1)
                    .fixedSize()
                    .id(label)
                    .transition(.opacity)
                    .accessibilityLabel(problem ? "Problem: \(label)" : label)
            }

            // Holding the key needs no buttons: letting go is "done", Esc is "cancel".
            if handsFree {
                PillButton(symbol: "stop.fill", help: "Finish", prominent: true) { Dictation.shared.finish() }
                    .transition(.opacity)
            }
        }
        .padding(.leading, listening ? 0 : 5)
        .padding(.trailing, listening ? 0 : 18)
        .frame(height: listening ? 76 : 50)
        .background {
            Color.clear
                .modifier(DarkGlass(shape: Capsule()))
                .opacity(listening ? 0 : 1)
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
    @Environment(\.staticRender) private var staticRender

    func body(content: Content) -> some View {
        Group {
            if staticRender {
                content
                    .background(shape.fill(Color(red: 0.10, green: 0.10, blue: 0.13)))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            } else if #available(macOS 26.0, *) {
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
