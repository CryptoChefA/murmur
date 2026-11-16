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
    /// Phrases already transcribed during this recording, shown under the orb.
    @Published var live = ""
    /// True while the edit key is driving: the words spoken are an instruction, not text.
    @Published var editing = false
    /// How far above the room a voice must rise to count as full. Lower in whisper mode.
    var reach: Float = 0.30

    static let barCount = 22

    /// 0...1 loudness of the voice above the room's background. Deliberately not @Published:
    /// the orb reads it every display frame and does its own smoothing, so publishing it would
    /// only add redraws.
    var voice: CGFloat = 0
    private var floor: Float = 1

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next

        // The quietest recent level is the room. It follows drops at once and creeps up slowly.
        floor = min(floor + 0.003, level)
        let above = CGFloat(max(0, level - floor - (reach < 0.2 ? 0.02 : 0.04)) / reach)
        voice = min(1, above)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: PillModel.barCount)
        voice = 0
        floor = 1
    }
}

/// The dictation state machine: key events in, text at the cursor out.
final class Dictation {
    static let shared = Dictation()

    let pill = PillModel()
    let hotkey = Hotkey()
    /// A second key: hold it with text selected and say how to change it.
    let editHotkey = Hotkey()
    var onStateChange: (() -> Void)?

    private let recorder = Recorder()
    private let store = Store.shared

    private enum State { case idle, holding, armed, handsFree, working }
    private var state: State = .idle {
        didSet {
            if state == .idle {
                editing = false; pill.editing = false
                if oldValue != .idle { WhisperEngine.shared.end(); MediaControl.shared.dictationEnded() }
            }
            onStateChange?()
        }
    }
    private var editing = false
    private var micUsed = ""
    private var selection = ""
    /// Names read from the text box in front, for this dictation only.
    private var screenNames: [String] = []
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
    /// When a recording was last thrown away (cancelled, or too short to be speech).
    private var discardedAt = Date.distantPast

    var isRecording: Bool { state == .holding || state == .armed || state == .handsFree }
    var isBusy: Bool { state != .idle }
    var paused = false {
        didSet {
            if paused { hotkey.stop(); editHotkey.stop() } else { hotkey.start(choiceID: Prefs.hotkey); startEditKey() }
        }
    }

    private init() {
        recorder.onLevel = { [weak self] level in
            guard let self, self.isRecording else { return }
            self.pill.push(level)
        }
        recorder.onPause = { [weak self] cut in self?.phraseEnded(at: cut) }
        hotkey.onDown = { [weak self] in self?.keyDown() }
        hotkey.onUp = { [weak self] in self?.keyUp() }
        hotkey.onEscape = { [weak self] in self?.cancel() }
        editHotkey.onDown = { [weak self] in self?.editDown() }
        editHotkey.onUp = { [weak self] in self?.editUp() }
    }

    func start() {
        hotkey.start(choiceID: Prefs.hotkey)
        startEditKey()
    }

    private func startEditKey() {
        let key = Prefs.editKey
        // The same key cannot do both jobs.
        if key == "none" || key == Prefs.hotkey { editHotkey.stop() } else { editHotkey.start(choiceID: key) }
    }

    /// Re-reads the hotkey after a settings change or a newly granted permission.
    func reloadHotkey() {
        guard !paused, !isBusy else { return }
        hotkey.start(choiceID: Prefs.hotkey)
        startEditKey()
    }

    // MARK: - Keys

    // MARK: - Edit by voice

    private func editDown() {
        guard state == .idle, Date().timeIntervalSince(discardedAt) > 0.3 else { return }
        pressedAt = Date()
        selection = ""
        // Copy the selection now, while the app still has it.
        Inserter.selection { [weak self] text in self?.selection = text }
        editing = true
        begin(handsFree: false)
        if state == .holding { pill.editing = true } else { editing = false }
    }

    private func editUp() {
        guard state == .holding, editing else { return }
        if Date().timeIntervalSince(pressedAt) < 0.3 { cancel(silently: true) } else { finish() }
    }

    private func finishEdit(instruction: String) {
        let text = selection
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .idle
            hotkey.watchEscape(false)
            notice("Select some text first", good: false)
            return
        }
        let engine = Prefs.cleanupEngine
        job = Task { [weak self] in
            let rewritten = await Cleanup.rewrite(text, instruction: instruction, engine: engine)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.state = .idle
                self.job = nil
                self.hotkey.watchEscape(false)
                guard let rewritten else {
                    self.notice(Cleanup.onDeviceProblem ?? "Couldn't rewrite that", good: false)
                    return
                }
                // Pasting over the selection replaces it.
                switch Inserter.insert(rewritten) {
                case .pasted: self.notice("", good: true, seconds: 0.35)
                case .copiedOnly: self.notice("Copied. Press ⌘V to paste", good: true, seconds: 2.5)
                }
            }
        }
    }

    private func keyDown() {
        guard !editing else { return }
        switch state {
        case .idle:
            // Hammering the key should not start and tear down the microphone many times a second.
            guard Date().timeIntervalSince(discardedAt) > 0.3 else { return }
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
        guard state == .holding, !editing else { return }
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
        // Before the start sound, so that sound isn't taken for music playing.
        MediaControl.shared.dictationStarted { [weak self] in self?.isRecording ?? false }
        do {
            try recorder.start(deviceUID: Prefs.micUID)
            micUsed = recorder.deviceName
        } catch {
            notice(error.localizedDescription, good: false)
            return
        }
        noticeTimeout?.cancel()
        phraseTasks = []
        phraseStart = 0
        pill.live = ""
        pill.reach = Prefs.whisperMode ? 0.14 : 0.30
        // A correction made since the last dictation is noticed now, before anything new is typed.
        Learner.review()
        screenNames = []
        if Prefs.contextNames, !editing {
            let element = ScreenContext.focusedElement()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let names = ScreenContext.names(in: ScreenContext.text(of: element) ?? "")
                DispatchQueue.main.async { self?.screenNames = names }
            }
        }
        state = handsFree ? .handsFree : .holding
        pill.resetLevels()
        pill.started = Date()
        pill.phase = .listening(handsFree: handsFree)
        hotkey.watchEscape(true)
        if Prefs.sounds { NSSound(named: "Tink")?.play() }

        // Load the model while the user is still talking.
        WhisperEngine.shared.idleMinutes = Prefs.idleMinutes
        WhisperEngine.shared.begin(modelPath: ModelCatalog.path(for: Prefs.modelID))
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
        guard !samples.isEmpty else { return }
        let task = transcribePhrase(samples, after: phraseTasks.last)
        phraseTasks.append(task)
        guard Prefs.livePreview, !editing else { return }
        Task { [weak self] in
            let text = await task.value
            await MainActor.run { [weak self] in
                guard let self, self.isRecording, !text.isEmpty else { return }
                self.pill.live = String((self.pill.live + " " + text).trimmingCharacters(in: .whitespaces).suffix(64))
            }
        }
    }

    /// Quiet speech is lifted to a normal level before the speech model hears it.
    private func prepared(_ samples: [Float]) -> [Float] {
        guard Prefs.whisperMode else { return samples }
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        guard peak > 0.000_5, peak < 0.5 else { return samples }
        let gain = min(30, 0.6 / peak)
        return samples.map { $0 * gain }
    }

    /// The dictionary's hints plus any names on screen.
    private var glossary: String {
        let names = screenNames.joined(separator: ", ")
        return [TextRules.vocabularyPrompt(store.dictionary), names].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func transcribePhrase(_ samples: [Float], after previous: Task<String, Never>?) -> Task<String, Never> {
        let glossary = self.glossary
        let samples = prepared(samples)
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
        if wasBusy { discardedAt = Date() }
        state = .idle
        if silently || !wasBusy { pill.phase = .hidden } else { notice("Cancelled", good: false, seconds: 0.8) }
    }

    func finish() {
        guard isRecording else { return }
        armedTimeout?.cancel(); limit?.cancel()
        let captured = recorder.stop()
        let seconds = Double(captured.samples.count) / 16_000
        guard seconds >= 0.35, captured.peak > (Prefs.whisperMode ? 0.04 : 0.12) else {
            state = .idle
            hotkey.watchEscape(false)
            discardedAt = Date()
            note(String(format: "discarded %.1f s of audio, peak %.2f, mic %@", seconds, captured.peak, micUsed))
            // Under a second is a stray tap, not an attempt to speak: go away quietly. Only a
            // real try that picked up nothing gets told so.
            if seconds < 1.0 { pill.phase = .hidden } else { notice("Didn't hear anything", good: false) }
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
        let quiet = captured.peak < (Prefs.whisperMode ? 0.12 : 0.3)
        let isEdit = editing
        let hints = glossary
        // Names from the screen go to the on-device model only. They are never sent to a cloud engine.
        let cleanupWords = Prefs.cleanupEngine == .onDevice ? vocabulary + screenNames : vocabulary
        let whole = prepared(captured.samples)

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
                        samples: whole, modelPath: ModelCatalog.path(for: Prefs.modelID),
                        language: Prefs.language, prompt: hints)
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
                                              options: .init(removeFillers: Prefs.removeFillers, spokenCommands: Prefs.spokenCommands,
                                                             removeHabits: level == .thorough && !isEdit))
                // Whisper invents stock phrases for near-silence; only trust them from clear audio.
                if ruled.isEmpty || (quiet && TextRules.isHallucination(ruled)) {
                    await MainActor.run { [weak self] in self?.complete(nil, raw: raw, app: app, seconds: seconds, engine: "none") }
                    return
                }
                if isEdit {
                    await MainActor.run { [weak self] in self?.finishEdit(instruction: ruled) }
                    return
                }
                // Already clean? Paste now rather than wait a second for the model to agree.
                let cleaned: Cleanup.Result
                if CleanupPrompt.needsModel(raw: raw, ruled: ruled, level: level, tone: tone) {
                    cleaned = await Cleanup.run(ruled, level: level, tone: tone, vocabulary: cleanupWords, engine: Prefs.cleanupEngine)
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
            note("nothing usable from \(Int(seconds)) s of audio in \(app?.localizedName ?? "unknown")")
            notice("Didn't catch that", good: false)
            return
        }
        // Terminals and chat boxes send on Return; a trailing space is the safer join.
        Learner.willPaste(text)
        let outcome = Inserter.insert(text.hasSuffix("\n") ? text : text + " ")
        store.add(HistoryEntry(text: text, raw: raw, app: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "",
                               duration: seconds, cleanup: engine))
        note("typed \(TextRules.wordCount(text)) words into \(app?.localizedName ?? "unknown"), cleanup \(engine), mic \(micUsed), history now \(store.history.count)")
        switch outcome {
        case .pasted: notice("", good: true, seconds: 0.35)
        case .copiedOnly: notice("Copied. Press ⌘V to paste", good: true, seconds: 2.5)
        }
    }

    /// One line per dictation in activity.txt: when, how many words, where, and whether it was
    /// logged. Never the words themselves. Kept to the last 50 lines.
    private func note(_ what: String) {
        let url = Paths.support.appendingPathComponent("activity.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(stamp) \(what)")
        try? lines.suffix(50).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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

    /// `Murmur --preview-notice "text"` walks the pill through a pretend dictation that ends in
    /// this message, for checking its look. Nothing is recorded.
    func previewNotice(_ text: String) {
        guard state == .idle, pill.phase == .hidden else { return }
        pill.phase = .listening(handsFree: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.state == .idle, self.pill.phase == .listening(handsFree: false) else { return }
            self.pill.phase = .thinking
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.state == .idle, self.pill.phase == .thinking else { return }
                self.notice(text, good: false, seconds: 3)
            }
        }
    }

    /// Runs the same pipeline on typed text, for the "try it" box in Setup.
    func pasteLast() {
        guard let last = store.history.first else { return }
        Inserter.insert(last.text)
    }

    /// Takes back the last dictation with the front app's own Undo.
    func undoLast() {
        guard state == .idle else { return }
        Inserter.undo()
    }
}
