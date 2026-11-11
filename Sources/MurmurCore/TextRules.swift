import Foundation

/// Everything that happens to a transcript without a language model.
public enum TextRules {

    public struct Options {
        public var removeFillers: Bool
        public var spokenCommands: Bool
        public init(removeFillers: Bool = true, spokenCommands: Bool = true) {
            self.removeFillers = removeFillers; self.spokenCommands = spokenCommands
        }
    }

    public static func process(_ raw: String, replacements: [Replacement], snippets: [Snippet],
                               options: Options = Options()) -> String {
        var t = stripNonSpeech(raw)
        if options.removeFillers { t = removeFillers(t) }
        t = applyReplacements(t, replacements)
        if options.spokenCommands { t = applySpokenCommands(t) }
        t = tidy(t)
        t = applySnippets(t, snippets)
        return t
    }

    // MARK: - Pieces

    public static func wordCount(_ s: String) -> Int {
        var count = 0
        for word in s.split(whereSeparator: { $0.isWhitespace }) {
            if word.contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
        }
        return count
    }

    /// Whisper labels silence and noise with tags like [BLANK_AUDIO] or (music).
    public static func stripNonSpeech(_ s: String) -> String {
        var t = replace(s, #"\[[A-Za-z_ ]+\]"#, "")
        t = replace(t, #"\((?:music|silence|applause|laughs|laughter|sighs|coughs|inaudible|blank audio|wind blowing|keyboard clicking|typing)\)"#, "")
        t = replace(t, #"[♪♫]+"#, "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases Whisper invents when handed near-silence.
    public static func isHallucination(_ s: String) -> Bool {
        let n = normalise(s)
        if n.isEmpty { return true }
        let known: Set<String> = [
            "thank you", "thanks for watching", "thank you for watching", "you", "bye",
            "thanks", "thank you very much", "please subscribe", "subtitles by the amara org community",
            "so", "okay", "the end",
        ]
        return known.contains(n) && s.count < 40
    }

    public static func removeFillers(_ s: String) -> String {
        // The filler, plus the comma or pause that came with it.
        var t = replace(s, #"(?<![\p{L}\p{N}'])(?:u+m+|u+h+m*|e+r+m+|h+m+)(?![\p{L}\p{N}'])[,…]*\s*"#, "")
        t = replace(t, #"^\s*[,.]\s*"#, "")
        return t
    }

    public static func applyReplacements(_ s: String, _ reps: [Replacement]) -> String {
        var pairs: [(String, String)] = []
        for r in reps where !r.heard.trimmed.isEmpty && !r.write.trimmed.isEmpty {
            pairs.append((r.heard.trimmed, r.write.trimmed))
        }
        return replacePhrases(s, pairs)
    }

    public static func applySnippets(_ s: String, _ snippets: [Snippet]) -> String {
        var pairs: [(String, String)] = []
        for sn in snippets where !sn.trigger.trimmed.isEmpty && !sn.expansion.isEmpty {
            // Said on its own: the expansion replaces the whole thing, punctuation included.
            if normalise(s) == normalise(sn.trigger) { return sn.expansion }
            pairs.append((sn.trigger.trimmed, sn.expansion))
        }
        return replacePhrases(s, pairs)
    }

    public static func applySpokenCommands(_ s: String) -> String {
        var t = replace(s, #"[,;]?[ \t]*(?<![\p{L}\p{N}])new paragraph(?![\p{L}\p{N}])[.,!?]?[ \t]*"#, "\n\n")
        t = replace(t, #"[,;]?[ \t]*(?<![\p{L}\p{N}])new ?line(?![\p{L}\p{N}])[.,!?]?[ \t]*"#, "\n")
        return t
    }

    /// Spacing and capitalisation, without touching the words.
    public static func tidy(_ s: String) -> String {
        var t = replace(s, #"[ \t]{2,}"#, " ")
        t = replace(t, #"[ \t]+([,.;:!?])"#, "$1")
        t = replace(t, #"[ \t]+\n"#, "\n")
        t = replace(t, #"\n{3,}"#, "\n\n")
        t = replace(t, #",\s*([.!?])"#, "$1")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitaliseSentenceStarts(t)
    }

    /// The words Murmur should know, as a Whisper prompt. Whisper reads at most ~220 tokens of it.
    public static func vocabularyPrompt(_ reps: [Replacement]) -> String {
        var seen = Set<String>(), words: [String] = [], length = 0
        for r in reps {
            let w = r.write.trimmed
            guard !w.isEmpty, w.count <= 40, seen.insert(w.lowercased()).inserted else { continue }
            if length + w.count + 2 > 600 { break }
            words.append(w); length += w.count + 2
        }
        return words.isEmpty ? "" : "Glossary: " + words.joined(separator: ", ") + "."
    }

    // MARK: - Helpers

    static func normalise(_ s: String) -> String {
        var flat = ""
        for scalar in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                flat.unicodeScalars.append(scalar)
            } else {
                flat.append(" ")
            }
        }
        let parts: [Substring] = flat.split(separator: " ")
        return parts.joined(separator: " ")
    }

    static func capitaliseSentenceStarts(_ s: String) -> String {
        var out = "", capitaliseNext = true
        for ch in s {
            if capitaliseNext, ch.isLetter {
                out += ch.uppercased(); capitaliseNext = false
            } else {
                out.append(ch)
                if ch == "\n" { capitaliseNext = true }
                else if !ch.isWhitespace { capitaliseNext = false }
            }
        }
        return out
    }

    /// Replaces every phrase in one pass, longest phrase first, so one replacement's
    /// output is never rewritten by another ("new york city" beats "new york").
    static func replacePhrases(_ s: String, _ pairs: [(String, String)]) -> String {
        let sorted = pairs.sorted { $0.0.count > $1.0.count }
        guard !sorted.isEmpty else { return s }
        var groups: [String] = []
        for (phrase, _) in sorted {
            var words: [String] = []
            for w in phrase.split(whereSeparator: { $0.isWhitespace }) {
                words.append(NSRegularExpression.escapedPattern(for: String(w)))
            }
            groups.append("(" + words.joined(separator: "\\s+") + ")")
        }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + groups.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = "", cursor = 0
        for match in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var replacement = ns.substring(with: match.range)
            for i in 0..<sorted.count where match.range(at: i + 1).location != NSNotFound {
                replacement = sorted[i].1
                break
            }
            out += replacement
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
