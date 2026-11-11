import AppKit
import Combine
import MurmurCore

/// What the pill shows.
final class PillModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case thinking
        case notice(String, good: Bool)
    }

    @Published var phase: Phase = .hidden
    /// Recent microphone levels, newest last.
    @Published var levels: [Float] = Array(repeating: 0, count: PillModel.barCount)
    @Published var started = Date()

    static let barCount = 22

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    func resetLevels() { levels = Array(repeating: 0, count: PillModel.barCount) }
}

/// The dictation state machine: key events in, text at the cursor out.
final class Dictation {
    static let shared = Dictation()

    let pill = PillModel()
    let hotkey = Hotkey()
    var onStateChange: (() -> Void)?

    private let recorder = Recorder()
    private let store = Store.shared

    private enum State { case idle, holding, armed, handsFree, working }
    private var state: State = .idle { didSet { onStateChange?() } }
    private var pressedAt = Date()
    private var armedTimeout: DispatchWorkItem?
    private var limit: DispatchWorkItem?
    private var noticeTimeout: DispatchWorkItem?
    private var target: NSRunningApplication?
    private var job: Task<Void, Never>?
    /// Phrases already handed to Whisper during this recording, in order.
    private var phraseTasks: [Task<String, Never>] = []
    private var phraseStart = 0
    private var releasedAt = Date()

    var isRecording: Bool { state == .holding || state == .armed || state == .handsFree }
    var isBusy: Bool { state != .idle }
    var paused = false { didSet { paused ? hotkey.stop() : hotkey.start(choiceID: Prefs.hotkey) } }

    private init() {
        recorder.onLevel = { [weak self] level in
            guard let self, self.isRecording else { return }
            self.pill.push(level)
        }
        recorder.onPause = { [weak self] cut in self?.phraseEnded(at: cut) }
        hotkey.onDown = { [weak self] in self?.keyDown() }
        hotkey.onUp = { [weak self] in self?.keyUp() }
        hotkey.onEscape = { [weak self] in self?.cancel() }
    }

    func start() {
        hotkey.start(choiceID: Prefs.hotkey)
    }

    /// Re-reads the hotkey after a settings change or a newly granted permission.
    func reloadHotkey() {
        guard !paused, !isBusy else { return }
        hotkey.start(choiceID: Prefs.hotkey)
    }

    // MARK: - Keys

    private func keyDown() {
        switch state {
        case .idle:
            pressedAt = Date()
            begin(handsFree: false)
        case .armed:
            // Second tap: stay on without holding.
            armedTimeout?.cancel()
            state = .handsFree
            pill.phase = .listening(handsFree: true)
        case .handsFree:
            finish()
        case .holding, .working:
            break
        }
    }

    private func keyUp() {
        guard state == .holding else { return }
        let held = Date().timeIntervalSince(pressedAt)
        if held < 0.3, Prefs.handsFree {
            // A tap, not a hold. Wait briefly for a second tap before giving up.
            state = .armed
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .armed else { return }
                self.cancel(silently: true)
            }
            armedTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else if held < 0.3 {
            cancel(silently: true)
        } else {
            finish()
        }
    }

    /// Menu-bar toggle: starts hands-free, or finishes whatever is running.
    func toggleFromMenu() {
        if isRecording { finish() } else if state == .idle { begin(handsFree: true) }
    }

    // MARK: - Recording

    private func begin(handsFree: Bool) {
        guard ModelCatalog.isInstalled(Prefs.modelID) else {
            notice("Download a speech model in Murmur first", good: false)
            return
        }
        if Permissions.microphone == .notDetermined {
            Permissions.requestMicrophone { _ in }
            return
        }
        target = NSWorkspace.shared.frontmostApplication
        do {
            try recorder.start(deviceUID: Prefs.micUID)
        } catch {
            notice(error.localizedDescription, good: false)
            return
        }
        noticeTimeout?.cancel()
        phraseTasks = []
        phraseStart = 0
        state = handsFree ? .handsFree : .holding
        pill.resetLevels()
        pill.started = Date()
        pill.phase = .listening(handsFree: handsFree)
        hotkey.watchEscape(true)
        if Prefs.sounds { NSSound(named: "Tink")?.play() }

        // Load the model while the user is still talking.
        WhisperEngine.shared.idleMinutes = Prefs.idleMinutes
        WhisperEngine.shared.preload(modelPath: ModelCatalog.path(for: Prefs.modelID))
        Cleanup.prewarm(level: Prefs.cleanupLevel, tone: store.tone(for: target?.bundleIdentifier ?? ""),
                        vocabulary: store.vocabulary, engine: Prefs.cleanupEngine)

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.finish()
        }
        limit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
    }

    /// The speaker paused: transcribe what they've said so far while they carry on.
    private func phraseEnded(at cut: Int) {
        guard isRecording, Prefs.streaming, cut > phraseStart else { return }
        let samples = recorder.slice(phraseStart..<cut)
        phraseStart = cut
        if !samples.isEmpty { phraseTasks.append(transcribePhrase(samples, after: phraseTasks.last)) }
    }

    private func transcribePhrase(_ samples: [Float], after previous: Task<String, Never>?) -> Task<String, Never> {
        let glossary = TextRules.vocabularyPrompt(store.dictionary)
        let model = ModelCatalog.path(for: Prefs.modelID), language = Prefs.language
        return Task {
            // The end of the previous phrase keeps spelling and punctuation consistent across the cut.
            let before = await previous?.value ?? ""
            let prompt = [glossary, String(before.suffix(200))].filter { !$0.isEmpty }.joined(separator: " ")
            return (try? await WhisperEngine.shared.transcribe(samples: samples, modelPath: model,
                                                               language: language, prompt: prompt)) ?? ""
        }
    }

    func cancel(silently: Bool = false) {
        armedTimeout?.cancel(); limit?.cancel()
        job?.cancel(); job = nil
        phraseTasks.forEach { $0.cancel() }
        phraseTasks = []
        if recorder.isRecording { _ = recorder.stop() }
        hotkey.watchEscape(false)
        let wasBusy = state != .idle
        state = .idle
        if silently || !wasBusy { pill.phase = .hidden } else { notice("Cancelled", good: false, seconds: 0.8) }
    }

    func finish() {
        guard isRecording else { return }
        armedTimeout?.cancel(); limit?.cancel()
        let captured = recorder.stop()
        let seconds = Double(captured.samples.count) / 16_000
        guard seconds >= 0.35, captured.peak > 0.12 else {
            state = .idle
            hotkey.watchEscape(false)
            notice(seconds < 0.35 ? "Hold the key while you speak" : "Didn't hear anything", good: false)
            return
        }
        // `defaults write app.murmur.Murmur debugKeepAudio -bool YES` keeps the last recording for inspection.
        if Prefs.defaults.bool(forKey: "debugKeepAudio") {
            AudioFileLoader.write(captured.samples, to: Paths.support.appendingPathComponent("last-recording.wav"))
        }
        releasedAt = Date()
        state = .working
        pill.phase = .thinking
        if Prefs.sounds { NSSound(named: "Pop")?.play() }

        let app = target
        let bundleID = app?.bundleIdentifier ?? ""
        let tone = store.tone(for: bundleID)
        let replacements = store.dictionary, snippets = store.snippets, vocabulary = store.vocabulary
        let quiet = captured.peak < 0.3

        // Whatever was said after the last pause still needs transcribing.
        var pending = phraseTasks
        phraseTasks = []
        let earlier = pending.count
        let tail = Array(captured.samples[min(phraseStart, captured.samples.count)...])
        let tailIsSpeech = tail.count >= 4_800 && tail.contains { abs($0) > 0.02 }
        if earlier > 0, tailIsSpeech { pending.append(transcribePhrase(tail, after: pending.last)) }
        let phrases = pending
        let level = Prefs.cleanupLevel

        job = Task { [weak self] in
            do {
                let raw: String
                if phrases.isEmpty {
                    raw = try await WhisperEngine.shared.transcribe(
                        samples: captured.samples, modelPath: ModelCatalog.path(for: Prefs.modelID),
                        language: Prefs.language, prompt: TextRules.vocabularyPrompt(replacements))
                } else {
                    var parts: [String] = []
                    for phrase in phrases {
                        let text = await phrase.value
                        if !text.isEmpty { parts.append(text) }
                    }
                    raw = parts.joined(separator: " ")
                }
                if Task.isCancelled { return }

                let ruled = TextRules.process(raw, replacements: replacements, snippets: snippets,
                                              options: .init(removeFillers: Prefs.removeFillers, spokenCommands: Prefs.spokenCommands))
                // Whisper invents stock phrases for near-silence; only trust them from clear audio.
                if ruled.isEmpty || (quiet && TextRules.isHallucination(ruled)) {
                    await MainActor.run { [weak self] in self?.complete(nil, raw: raw, app: app, seconds: seconds, engine: "none") }
                    return
                }
                // Already clean? Paste now rather than wait a second for the model to agree.
                let cleaned: Cleanup.Result
                if CleanupPrompt.needsModel(raw: raw, ruled: ruled, level: level, tone: tone) {
                    cleaned = await Cleanup.run(ruled, level: level, tone: tone, vocabulary: vocabulary, engine: Prefs.cleanupEngine)
                } else {
                    cleaned = Cleanup.Result(text: ruled, engine: "none")
                }
                self?.logTiming(seconds: seconds, phrases: max(phrases.count, 1), early: earlier, engine: cleaned.engine)
                if Task.isCancelled { return }
                // The model may have re-spelled a dictionary word; apply replacements once more.
                let final = cleaned.engine == "none" ? cleaned.text : TextRules.applyReplacements(cleaned.text, replacements)
                await MainActor.run { [weak self] in self?.complete(final, raw: raw, app: app, seconds: seconds, engine: cleaned.engine) }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .idle
                    self?.hotkey.watchEscape(false)
                    self?.notice(error.localizedDescription, good: false)
                }
            }
        }
    }

    /// With `debugKeepAudio` set, appends how long release-to-text took.
    private func logTiming(seconds: Double, phrases: Int, early: Int, engine: String) {
        guard Prefs.defaults.bool(forKey: "debugKeepAudio") else { return }
        let line = String(format: "audio=%.1fs phrases=%d early=%d cleanup=%@ release-to-text=%.2fs\n",
                          seconds, phrases, early, engine, Date().timeIntervalSince(releasedAt))
        let url = Paths.support.appendingPathComponent("timing-log.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
    }

    private func complete(_ text: String?, raw: String, app: NSRunningApplication?, seconds: Double, engine: String) {
        state = .idle
        job = nil
        hotkey.watchEscape(false)
        guard let text, !text.isEmpty else {
            notice("Didn't catch that", good: false)
            return
        }
        // Terminals and chat boxes send on Return; a trailing space is the safer join.
        let outcome = Inserter.insert(text.hasSuffix("\n") ? text : text + " ")
        store.add(HistoryEntry(text: text, raw: raw, app: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "",
                               duration: seconds, cleanup: engine))
        switch outcome {
        case .pasted: notice("", good: true, seconds: 0.7)
        case .copiedOnly: notice("Copied — press ⌘V to paste", good: true, seconds: 2.5)
        }
    }

    private func notice(_ message: String, good: Bool, seconds: Double = 1.8) {
        noticeTimeout?.cancel()
        pill.phase = .notice(message, good: good)
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .notice = self.pill.phase else { return }
            self.pill.phase = .hidden
        }
        noticeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Runs the same pipeline on typed text, for the "try it" box in Setup.
    func pasteLast() {
        guard let last = store.history.first else { return }
        Inserter.insert(last.text)
    }
}
