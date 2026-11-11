import SwiftUI
import ServiceManagement
import MurmurCore

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var downloader: ModelDownloader
    @AppStorage(Prefs.Key.hotkey) private var hotkey = "fn"
    @AppStorage(Prefs.Key.handsFree) private var handsFree = true
    @AppStorage(Prefs.Key.micUID) private var micUID = ""
    @AppStorage(Prefs.Key.language) private var language = "en"
    @AppStorage(Prefs.Key.sounds) private var sounds = true
    @AppStorage(Prefs.Key.modelID) private var modelID = ModelCatalog.defaultID
    @AppStorage(Prefs.Key.cleanupEngine) private var cleanupEngine = CleanupEngine.onDevice.rawValue
    @AppStorage(Prefs.Key.idleMinutes) private var idleMinutes = 5.0
    @State private var microphones: [AudioDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var apiKey = ""
    @State private var cloudModel = ""

    private var engine: CleanupEngine { CleanupEngine(rawValue: cleanupEngine) ?? .onDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("Dictation")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(title: "Dictation key", detail: "Hold to talk, release to insert.") {
                        Picker("Dictation key", selection: $hotkey) {
                            ForEach(Hotkey.choices) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().fixedSize().frame(width: 190, alignment: .trailing)
                    }
                    RowDivider()
                    SettingRow(title: "Hands-free", detail: "Double-tap the key to keep listening; tap once more to finish.") {
                        Toggle("", isOn: $handsFree).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    RowDivider()
                    SettingRow(title: "Microphone") {
                        Picker("Microphone", selection: $micUID) {
                            Text("System default").tag("")
                            ForEach(microphones) { Text($0.name).tag($0.uid) }
                        }
                        .labelsHidden().fixedSize().frame(width: 190, alignment: .trailing)
                    }
                    RowDivider()
                    SettingRow(title: "Language", detail: ModelCatalog.model(modelID).englishOnly ? "The selected model is English-only." : "") {
                        Picker("Language", selection: $language) {
                            ForEach(Prefs.languages, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden().fixedSize().frame(width: 190, alignment: .trailing)
                        .disabled(ModelCatalog.model(modelID).englishOnly)
                    }
                    RowDivider()
                    SettingRow(title: "Sounds", detail: "A soft tick when listening starts and stops.") {
                        Toggle("", isOn: $sounds).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
            }

            GroupTitle("Speech model")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(ModelCatalog.all.enumerated()), id: \.element.id) { index, model in
                        if index > 0 { RowDivider().padding(.leading, 16) }
                        ModelRow(model: model, selectedID: $modelID)
                    }
                }
            }
            .id(downloader.revision)

            GroupTitle("AI cleanup")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(title: "Engine", detail: engineDetail) {
                        Picker("Cleanup engine", selection: $cleanupEngine) {
                            ForEach(CleanupEngine.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize().frame(width: 190, alignment: .trailing)
                    }
                    if engine.isCloud {
                        RowDivider()
                        SettingRow(title: "\(engine.label) API key", detail: "Stored in your Keychain. Only the transcript text is sent, never audio.") {
                            SecureField("Paste key", text: $apiKey)
                                .fieldBox().frame(width: 190)
                                .onSubmit(saveKey)
                                .onChange(of: apiKey) { _, _ in saveKey() }
                        }
                        RowDivider()
                        SettingRow(title: "Model", detail: "Leave empty for \(Cleanup.defaultModel(for: engine)).") {
                            TextField(Cleanup.defaultModel(for: engine), text: $cloudModel)
                                .fieldBox().frame(width: 190)
                                .onChange(of: cloudModel) { _, value in
                                    Prefs.defaults.set(value, forKey: "cloudModel.\(engine.rawValue)")
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            GroupTitle("System")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(title: "Release the model after", detail: "The speech model uses memory only while loaded. It reloads in about a second.") {
                        Picker("Release the model after", selection: $idleMinutes) {
                            Text("Each dictation").tag(0.0)
                            Text("1 minute").tag(1.0)
                            Text("5 minutes").tag(5.0)
                            Text("30 minutes").tag(30.0)
                            Text("Never").tag(100_000.0)
                        }
                        .labelsHidden().fixedSize().frame(width: 190, alignment: .trailing)
                    }
                    RowDivider()
                    SettingRow(title: "Open at login") {
                        Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .onChange(of: launchAtLogin) { _, on in
                                do {
                                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }

            Text("Murmur \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · No telemetry, no account, no update checks.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .onAppear {
            microphones = AudioDevices.inputs()
            loadCloudFields()
        }
        .onChange(of: hotkey) { _, _ in Dictation.shared.reloadHotkey() }
        .onChange(of: cleanupEngine) { _, _ in loadCloudFields() }
        .onChange(of: idleMinutes) { _, value in WhisperEngine.shared.idleMinutes = value }
    }

    private var engineDetail: String {
        if engine == .onDevice {
            return Cleanup.onDeviceProblem ?? "Apple's built-in model. Private, free, nothing to download."
        }
        return "Sharper on long, rambling speech. Uses your own \(engine.label) account."
    }

    private func loadCloudFields() {
        guard engine.isCloud else { return }
        apiKey = Keychain.get(engine.rawValue) ?? ""
        cloudModel = Prefs.defaults.string(forKey: "cloudModel.\(engine.rawValue)") ?? ""
    }

    private func saveKey() {
        guard engine.isCloud else { return }
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: engine.rawValue)
    }
}

private struct ModelRow: View {
    @EnvironmentObject private var downloader: ModelDownloader
    let model: SpeechModel
    @Binding var selectedID: String

    var body: some View {
        let installed = ModelCatalog.isInstalled(model.id)
        let selected = selectedID == model.id
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(installed ? 0.7 : 0.3))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).font(.system(size: 13, weight: selected ? .medium : .regular))
                    Tag(text: model.megabytes >= 1000 ? String(format: "%.1f GB", Double(model.megabytes) / 1000) : "\(model.megabytes) MB")
                }
                Text(downloader.failed[model.id] ?? model.blurb)
                    .font(.system(size: 11.5))
                    .foregroundStyle(downloader.failed[model.id] == nil ? Color.secondary : Theme.warn)
            }
            Spacer()
            if let fraction = downloader.progress[model.id] {
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 32)
                IconButton(symbol: "xmark", help: "Cancel download") { downloader.cancel(model) }
            } else if installed {
                if !selected {
                    Button("Use") { selectedID = model.id }
                    IconButton(symbol: "trash", help: "Delete \(model.name)") { downloader.delete(model) }
                } else {
                    Text("In use").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else {
                Button("Download") { downloader.download(model) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if installed { selectedID = model.id } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject private var downloader: ModelDownloader
    @AppStorage(Prefs.Key.hotkey) private var hotkey = "fn"
    @AppStorage(Prefs.Key.modelID) private var modelID = ModelCatalog.defaultID
    @State private var micOK = Permissions.microphone == .authorized
    @State private var axOK = Permissions.accessibility
    @State private var globeFree = Permissions.globeKeyIsFree
    @State private var scratch = ""

    // Only ticks while this screen is open.
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let model = ModelCatalog.model(modelID)
        let installed = ModelCatalog.isInstalled(modelID)
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    step(done: micOK, title: "Microphone", detail: "So Murmur can hear you. Audio is processed on this Mac and never saved.") {
                        Button(Permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                            if Permissions.microphone == .notDetermined {
                                Permissions.requestMicrophone { micOK = $0 }
                            } else {
                                Permissions.openSettings("Privacy_Microphone")
                            }
                        }
                    }
                    RowDivider().padding(.leading, 50)
                    step(done: axOK, title: "Accessibility", detail: "So Murmur can notice the dictation key and type the result. Switch Murmur on in the list that opens.") {
                        Button("Grant Access") {
                            // macOS shows its own prompt only once, so always open the list as well.
                            Permissions.promptAccessibility()
                            Permissions.openSettings("Privacy_Accessibility")
                        }
                    }
                    RowDivider().padding(.leading, 50)
                    step(done: installed, title: "Speech model",
                         detail: downloader.failed[modelID] ?? "\(model.name), \(model.megabytes) MB, downloaded once from Hugging Face.") {
                        if let fraction = downloader.progress[modelID] {
                            ProgressView(value: fraction).frame(width: 110)
                        } else {
                            Button("Download") { downloader.download(model) }
                        }
                    }
                    if hotkey == "fn" && !globeFree {
                        RowDivider().padding(.leading, 50)
                        step(done: false, optional: true, title: "Free up the Globe key",
                             detail: "macOS also uses Fn. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”, or pick another key in Settings.") {
                            Button("Open Keyboard") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
            }
            .id(downloader.revision)

            GroupTitle("Try it")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(micOK && axOK && installed
                         ? "Click in the box, hold \(Hotkey.choice(hotkey).label), say a sentence, and let go."
                         : "Finish the steps above, then test here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $scratch)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 96)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
        }
        .onReceive(refresh) { _ in
            micOK = Permissions.microphone == .authorized
            globeFree = Permissions.globeKeyIsFree
            let trusted = Permissions.accessibility
            if trusted && !axOK { Dictation.shared.reloadHotkey() }
            axOK = trusted
        }
    }

    private func step<Action: View>(done: Bool, optional: Bool = false, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "info.circle" : "circle"))
                .font(.system(size: 18))
                .foregroundStyle(done ? Theme.good : Color.secondary.opacity(0.6))
                .frame(width: 20)
                .accessibilityLabel(done ? "Done" : "To do")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !done { action() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
