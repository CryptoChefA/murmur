import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    /// What was inserted.
    public var text: String
    /// What Whisper heard, before rules and cleanup.
    public var raw: String
    public var app: String
    public var bundleID: String
    /// Seconds of speech.
    public var duration: Double
    public var words: Int
    /// Which cleanup ran: "none", "on-device", "anthropic", ...
    public var cleanup: String

    public init(id: UUID = UUID(), date: Date = Date(), text: String, raw: String, app: String = "",
                bundleID: String = "", duration: Double = 0, cleanup: String = "none") {
        self.id = id; self.date = date; self.text = text; self.raw = raw; self.app = app
        self.bundleID = bundleID; self.duration = duration; self.cleanup = cleanup
        self.words = TextRules.wordCount(text)
    }
}

/// A dictionary entry. With `heard` empty it is just a word Murmur should know how to spell;
/// with `heard` set, every occurrence of `heard` is rewritten as `write`.
public struct Replacement: Codable, Identifiable, Equatable {
    public var id: UUID
    public var heard: String
    public var write: String
    public init(id: UUID = UUID(), heard: String = "", write: String) {
        self.id = id; self.heard = heard; self.write = write
    }
}

public struct Snippet: Codable, Identifiable, Equatable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id; self.trigger = trigger; self.expansion = expansion
    }
}

public enum Tone: String, Codable, CaseIterable, Identifiable {
    case neutral, formal, casual, verbatim
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .verbatim: return "Verbatim"
        }
    }
    public var blurb: String {
        switch self {
        case .neutral: return "Clean sentences, your wording."
        case .formal: return "Full sentences, no slang, careful punctuation."
        case .casual: return "Relaxed, short, light punctuation."
        case .verbatim: return "Exactly what you said. No AI cleanup."
        }
    }
}

public struct StyleRule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var bundleID: String
    public var appName: String
    public var tone: Tone
    public init(id: UUID = UUID(), bundleID: String, appName: String, tone: Tone) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.tone = tone
    }

    public static let defaults: [StyleRule] = [
        StyleRule(bundleID: "com.apple.mail", appName: "Mail", tone: .formal),
        StyleRule(bundleID: "com.apple.MobileSMS", appName: "Messages", tone: .casual),
        StyleRule(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .casual),
        StyleRule(bundleID: "com.apple.Terminal", appName: "Terminal", tone: .verbatim),
        StyleRule(bundleID: "com.googlecode.iterm2", appName: "iTerm", tone: .verbatim),
        StyleRule(bundleID: "com.microsoft.VSCode", appName: "VS Code", tone: .verbatim),
        StyleRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", tone: .verbatim),
    ]
}

public enum CleanupLevel: String, CaseIterable, Identifiable {
    case off, light, polished
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .polished: return "Polished"
        }
    }
    public var blurb: String {
        switch self {
        case .off: return "Whisper's transcript with your dictionary and snippets applied."
        case .light: return "Removes fillers and fixes punctuation. Your words stay as spoken."
        case .polished: return "Also drops false starts, applies self-corrections and formats lists."
        }
    }
}

public enum CleanupEngine: String, CaseIterable, Identifiable {
    case onDevice, anthropic, openai, groq
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .onDevice: return "On this Mac"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }
    public var isCloud: Bool { self != .onDevice }
}

public enum JSONFile {
    public static func load<T: Decodable>(_ url: URL, default fallback: T) -> T {
        guard let data = try? Data(contentsOf: url) else { return fallback }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(T.self, from: data)) ?? fallback
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
