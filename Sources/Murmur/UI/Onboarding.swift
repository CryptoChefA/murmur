import SwiftUI
import MurmurCore

/// The first-run walk-through: what Murmur is, which speech model to use, the two permissions,
/// the key and its gestures, and a place to try it. Shown in the main window until finished.
struct OnboardingView: View {
    @EnvironmentObject private var downloader: ModelDownloader
    @AppStorage(Prefs.Key.didOnboard) private var didOnboard = false
    @AppStorage(Prefs.Key.modelID) private var modelID = ModelCatalog.defaultID
    @AppStorage(Prefs.Key.hotkey) private var hotkey = "fn"
    @State var step = 0

    static let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { didOnboard = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("You can finish setting up later from the Setup page")
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)

            Spacer(minLength: 12)
            Group {
                switch step {
                case 0: welcome
                case 1: ModelStep(modelID: $modelID)
                case 2: PermissionStep()
                case 3: KeyStep(hotkey: $hotkey)
                default: TryStep(hotkey: hotkey, modelID: modelID)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            Spacer(minLength: 12)

            HStack(spacing: 14) {
                Button("Back") { step -= 1 }
                    .buttonStyle(QuietButton())
                    .opacity(step == 0 ? 0 : 1)
                    .disabled(step == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<OnboardingView.stepCount, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? Theme.silver : Color.white.opacity(0.16))
                            .frame(width: index == step ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(OnboardingView.stepCount)")
                Spacer()
                Button(step == 0 ? "Get started" : (step == OnboardingView.stepCount - 1 ? "Finish" : "Continue")) { advance() }
                    .buttonStyle(ChromeButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sheen)
        .background(Theme.window)
        .animation(.easeInOut(duration: 0.22), value: step)
        .onChange(of: hotkey) { _, _ in Dictation.shared.reloadHotkey() }
    }

    private func advance() {
        // Leaving the model page starts the download, so it runs while the rest is read.
        if step == 1, !ModelCatalog.isInstalled(modelID), downloader.progress[modelID] == nil {
            downloader.download(ModelCatalog.model(modelID))
        }
        if step == OnboardingView.stepCount - 1 { didOnboard = true } else { step += 1 }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            StillOrb(flow: 3.1, energy: 0.45, alert: 0)
                .frame(width: 150, height: 150)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            Text("Talk. It types.")
                .font(.system(size: 44, weight: .bold))
                .kerning(-1.2)
                .foregroundStyle(Theme.chrome)
                .padding(.top, 26)
            Text("Hold a key, say what you mean, and let go. Murmur types it into whatever app you're using. Everything runs on this Mac.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 430)
                .padding(.top, 12)
            Text("Setting up takes about two minutes.")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
    }
}

private struct StepHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .kerning(-0.6)
                .foregroundStyle(Theme.chrome)
            Text(detail)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }
}

// MARK: - Model

private struct ModelStep: View {
    @EnvironmentObject private var downloader: ModelDownloader
    @Binding var modelID: String

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(title: "Choose a speech model",
                        detail: "This is the part that turns your voice into text. It's downloaded once and runs on your Mac. You can switch at any time in Settings.")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(ModelCatalog.all.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { RowDivider().padding(.leading, 46) }
                        row(model)
                    }
                }
            }
            .id(downloader.revision)
        }
    }

    private func row(_ model: SpeechModel) -> some View {
        let selected = modelID == model.id
        let installed = ModelCatalog.isInstalled(model.id)
        return Button { modelID = model.id } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Tag(text: model.megabytes >= 1000 ? String(format: "%.1f GB", Double(model.megabytes) / 1000) : "\(model.megabytes) MB")
                    }
                    Text(downloader.failed[model.id] ?? model.blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(downloader.failed[model.id] == nil ? Color.secondary : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let fraction = downloader.progress[model.id] {
                    ProgressView(value: fraction).frame(width: 70)
                    Text("\(Int(fraction * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                } else if installed {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.good)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Permissions

private struct PermissionStep: View {
    @State private var micOK = Permissions.microphone == .authorized
    @State private var axOK = Permissions.accessibility
    // Only ticks while this page is open.
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(title: "Two permissions",
                        detail: "macOS asks before any app can use the microphone or type for you. Murmur needs both and nothing else.")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    row(done: micOK, symbol: "mic", title: "Microphone",
                        detail: "To hear you. Audio is used for the transcription and then discarded. It is never saved.") {
                        Button(Permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                            if Permissions.microphone == .notDetermined {
                                Permissions.requestMicrophone { micOK = $0 }
                            } else {
                                Permissions.openSettings("Privacy_Microphone")
                            }
                        }
                    }
                    RowDivider().padding(.leading, 52)
                    row(done: axOK, symbol: "keyboard", title: "Accessibility",
                        detail: "To notice the dictation key and type the result into other apps. Switch Murmur on in the list that opens.") {
                        Button("Grant Access") {
                            Permissions.promptAccessibility()
                            Permissions.openSettings("Privacy_Accessibility")
                        }
                    }
                }
            }
        }
        .onReceive(refresh) { _ in
            micOK = Permissions.microphone == .authorized
            let trusted = Permissions.accessibility
            if trusted && !axOK { Dictation.shared.reloadHotkey() }
            axOK = trusted
        }
    }

    private func row<Action: View>(done: Bool, symbol: String, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 17))
                .foregroundStyle(done ? Theme.good : Theme.silver)
                .frame(width: 22)
                .accessibilityLabel(done ? "Done" : "To do")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if done {
                Text("Allowed").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                action()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - Key

private struct KeyStep: View {
    @Binding var hotkey: String
    @State private var globeFree = Permissions.globeKeyIsFree

    private var keyName: String {
        switch hotkey {
        case "fn": return "fn"
        case "rightOption": return "⌥"
        case "rightCommand": return "⌘"
        default: return "⌃"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeading(title: "One key does everything",
                        detail: "Pick the key you'll hold to dictate. It works in every app, whether or not Murmur's window is open.")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Dictation key").font(.system(size: 13))
                        Spacer()
                        Picker("Dictation key", selection: $hotkey) {
                            ForEach(Hotkey.choices) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    RowDivider()
                    gesture(keys: [keyName], title: "Hold, talk, let go", detail: "The orb appears while you hold the key. Your words are typed when you release it.")
                    RowDivider().padding(.leading, 104)
                    gesture(keys: [keyName, keyName], title: "Double-tap to go hands-free", detail: "Murmur keeps listening without the key held. Tap once more to finish.")
                    RowDivider().padding(.leading, 104)
                    gesture(keys: ["esc"], title: "Change your mind", detail: "Escape cancels a dictation. Nothing is typed.")
                }
            }
            if hotkey == "fn" && !globeFree {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.warn)
                    Text("macOS also uses the Fn key. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”, or pick another key above.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Keyboard") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                        globeFree = Permissions.globeKeyIsFree
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private func gesture(keys: [String], title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.silver)
                        .frame(width: 34, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                }
            }
            .frame(width: 74, alignment: .leading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Try it

private struct TryStep: View {
    @EnvironmentObject private var downloader: ModelDownloader
    let hotkey: String
    let modelID: String
    @State private var scratch = ""
    @State private var ready = Permissions.accessibility && Permissions.microphone == .authorized
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let installed = ModelCatalog.isInstalled(modelID)
        VStack(spacing: 0) {
            StepHeading(title: "Try it",
                        detail: "Click in the box, hold \(Hotkey.choice(hotkey).label), say a sentence, and let go.")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $scratch)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
                        .accessibilityLabel("Practice box")
                    status(installed: installed)
                }
            }
            .id(downloader.revision)
            Text("After this, Murmur lives in the menu bar. Open this window from there to see your history, teach it words, or change settings.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        }
        .onReceive(refresh) { _ in ready = Permissions.accessibility && Permissions.microphone == .authorized }
    }

    @ViewBuilder private func status(installed: Bool) -> some View {
        if let fraction = downloader.progress[modelID] {
            HStack(spacing: 10) {
                ProgressView(value: fraction).frame(width: 140)
                Text("Downloading the speech model, \(Int(fraction * 100))%").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        } else if let problem = downloader.failed[modelID] {
            Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
        } else if !installed {
            HStack(spacing: 10) {
                Text("The speech model isn't downloaded yet.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Download") { downloader.download(ModelCatalog.model(modelID)) }
            }
        } else if !ready {
            Label("A permission is still missing. Go back two steps to allow it.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
        } else {
            Label("Ready. Hold the key and speak.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5)).foregroundStyle(Theme.good)
        }
    }
}

// MARK: - Buttons

/// The main action: a chrome capsule, like the page's "Install" button.
struct ChromeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.04, green: 0.05, blue: 0.10))
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(Capsule().fill(LinearGradient(colors: [.white, Color(red: 0.80, green: 0.84, blue: 0.93)], startPoint: .top, endPoint: .bottom)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.silver)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().strokeBorder(Color.white.opacity(configuration.isPressed ? 0.4 : 0.18), lineWidth: 1))
    }
}
