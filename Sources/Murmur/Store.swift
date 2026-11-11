import Foundation
import Combine
import MurmurCore

/// Settings, read straight from UserDefaults so views can bind with @AppStorage.
enum Prefs {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            Key.hotkey: "fn",
            Key.handsFree: true,
            Key.modelID: ModelCatalog.defaultID,
            Key.language: "en",
            Key.cleanupLevel: CleanupLevel.polished.rawValue,
            Key.cleanupEngine: CleanupEngine.onDevice.rawValue,
            Key.idleMinutes: 5.0,
            Key.sounds: true,
            Key.spokenCommands: true,
            Key.removeFillers: true,
            Key.retentionDays: 0,
            Key.micUID: "",
            Key.streaming: true,
        ])
    }

    enum Key {
        static let hotkey = "hotkey"
        static let handsFree = "handsFree"
        static let modelID = "modelID"
        static let language = "language"
        static let cleanupLevel = "cleanupLevel"
        static let cleanupEngine = "cleanupEngine"
        static let idleMinutes = "idleMinutes"
        static let sounds = "sounds"
        static let spokenCommands = "spokenCommands"
        static let removeFillers = "removeFillers"
        /// 0 keeps history forever, -1 keeps none, otherwise days.
        static let retentionDays = "retentionDays"
        static let micUID = "micUID"
        /// Transcribe finished phrases while the user is still speaking.
        static let streaming = "streaming"
        static let didOnboard = "didOnboard"
    }

    static var hotkey: String { defaults.string(forKey: Key.hotkey) ?? "fn" }
    static var handsFree: Bool { defaults.bool(forKey: Key.handsFree) }
    static var modelID: String { defaults.string(forKey: Key.modelID) ?? ModelCatalog.defaultID }
    static var cleanupLevel: CleanupLevel { CleanupLevel(rawValue: defaults.string(forKey: Key.cleanupLevel) ?? "") ?? .polished }
    static var cleanupEngine: CleanupEngine { CleanupEngine(rawValue: defaults.string(forKey: Key.cleanupEngine) ?? "") ?? .onDevice }
    static var idleMinutes: Double { defaults.double(forKey: Key.idleMinutes) }
    static var sounds: Bool { defaults.bool(forKey: Key.sounds) }
    static var spokenCommands: Bool { defaults.bool(forKey: Key.spokenCommands) }
    static var removeFillers: Bool { defaults.bool(forKey: Key.removeFillers) }
    static var retentionDays: Int { defaults.integer(forKey: Key.retentionDays) }
    static var streaming: Bool { defaults.bool(forKey: Key.streaming) }
    static var micUID: String { defaults.string(forKey: Key.micUID) ?? "" }

    /// English-only models can't be asked for anything else.
    static var language: String {
        if ModelCatalog.model(modelID).englishOnly { return "en" }
        return defaults.string(forKey: Key.language) ?? "en"
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("hi", "Hindi"), ("ur", "Urdu"), ("ar", "Arabic"),
        ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"), ("tr", "Turkish"), ("pl", "Polish"),
        ("sv", "Swedish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"), ("id", "Indonesian"),
    ]
}

/// The user's lists. Each is one small JSON file in Application Support.
final class Store: ObservableObject {
    static let shared = Store(directory: Paths.support)

    @Published var history: [HistoryEntry] { didSet { persist(history, "history.json") } }
    @Published var dictionary: [Replacement] { didSet { persist(dictionary, "dictionary.json") } }
    @Published var snippets: [Snippet] { didSet { persist(snippets, "snippets.json") } }
    @Published var styles: [StyleRule] { didSet { persist(styles, "styles.json") } }

    private let directory: URL?

    /// Pass nil for an in-memory store (screenshots, previews).
    init(directory: URL?) {
        self.directory = directory
        if let directory {
            history = JSONFile.load(directory.appendingPathComponent("history.json"), default: [])
            dictionary = JSONFile.load(directory.appendingPathComponent("dictionary.json"), default: [])
            snippets = JSONFile.load(directory.appendingPathComponent("snippets.json"), default: [])
            styles = JSONFile.load(directory.appendingPathComponent("styles.json"), default: StyleRule.defaults)
        } else {
            history = []; dictionary = []; snippets = []; styles = StyleRule.defaults
        }
    }

    private func persist<T: Encodable>(_ value: T, _ name: String) {
        guard let directory else { return }
        JSONFile.save(value, to: directory.appendingPathComponent(name))
    }

    var stats: Stats { Stats.compute(history) }

    func add(_ entry: HistoryEntry) {
        let days = Prefs.retentionDays
        guard days >= 0 else { return }
        var next = history
        next.insert(entry, at: 0)
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            next.removeAll { $0.date < cutoff }
        }
        if next.count > 5_000 { next.removeLast(next.count - 5_000) }
        history = next
    }

    func tone(for bundleID: String) -> Tone {
        styles.first { $0.bundleID == bundleID }?.tone ?? .neutral
    }

    var vocabulary: [String] {
        dictionary.map(\.write).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

extension Store {
    /// Sample data for screenshots.
    static func demo() -> Store {
        let s = Store(directory: nil)
        let now = Date()
        let samples: [(String, String, String, Double, Double)] = [
            ("Can we move the design review to Thursday at four? I'd like Priya to walk through the new onboarding flow before we lock the sprint.",
             "um so can we move the design review to thursday at three no wait four i'd like priya to walk through the new onboarding flow before we lock the sprint", "Mail", 0.2, 11),
            ("Running ten minutes late, order me a flat white?", "running ten minutes late uh order me a flat white", "Messages", 1.5, 4),
            ("The cache invalidation bug only shows up when two writers race on the same key. I think the fix is a version check on write rather than another lock.",
             "the cache invalidation bug only shows up when two writers race on the same key i think the fix is a version check on write rather than another lock", "Notes", 3, 12),
            ("Shipping list:\n- Update the changelog\n- Tag the release\n- Post in the channel", "shipping list update the changelog tag the release post in the channel", "Slack", 26, 7),
            ("git rebase --onto main feature", "git rebase onto main feature", "Terminal", 30, 3),
        ]
        for (text, raw, app, hoursAgo, seconds) in samples {
            s.history.append(HistoryEntry(date: now.addingTimeInterval(-hoursAgo * 3_600), text: text, raw: raw, app: app,
                                          duration: seconds, cleanup: app == "Terminal" ? "none" : "on-device"))
        }
        let filler = [420, 180, 0, 610, 350, 90, 0, 240, 530, 300, 120, 0]
        for (i, words) in filler.enumerated() where words > 0 {
            let text = Array(repeating: "word", count: words).joined(separator: " ")
            s.history.append(HistoryEntry(date: now.addingTimeInterval(-Double(i + 2) * 86_400), text: text, raw: text,
                                          app: "Notes", duration: Double(words) / 2.6))
        }
        s.dictionary = [Replacement(write: "Kubernetes"), Replacement(write: "Priya"),
                        Replacement(heard: "post gress", write: "Postgres"), Replacement(heard: "eta", write: "ETA")]
        s.snippets = [Snippet(trigger: "my email", expansion: "hello@example.com"),
                      Snippet(trigger: "sign off", expansion: "Thanks,\nAlex"),
                      Snippet(trigger: "calendar link", expansion: "https://cal.example.com/alex")]
        return s
    }
}
