import AppKit
import ApplicationServices
import MurmurCore

/// Reads the text box being typed into, through the same Accessibility permission that lets
/// Murmur paste. Used for two things, both kept in memory only: spotting names already on
/// screen so they are spelled right, and noticing when a dictated word was corrected afterwards.
enum ScreenContext {
    /// The focused text element of the frontmost app, if it exposes one.
    static func focusedElement() -> AXUIElement? {
        guard Permissions.accessibility else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    /// The text in an element, trimmed to its last few thousand characters.
    static func text(of element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return String(string.suffix(4_000))
    }

    /// Capitalised words that are not simply the start of a sentence: mostly names.
    static func names(in text: String, limit: Int = 24) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        var sentenceStart = true
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(raw)
            let word = token.trimmingCharacters(in: CharacterSet.letters.inverted)
            let startsSentence = sentenceStart
            sentenceStart = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?") || token.hasSuffix(":")
            guard word.count >= 3, word.count <= 24, let first = word.unicodeScalars.first,
                  CharacterSet.uppercaseLetters.contains(first),
                  word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
                  word != word.uppercased() || word.count <= 5, !startsSentence else { continue }
            if seen.insert(word.lowercased()).inserted { found.append(word) }
            if found.count >= limit { break }
        }
        return found
    }
}

/// Notices when a word Murmur typed was changed by hand shortly afterwards, and offers the
/// correction as a dictionary entry. Nothing is added without the user saying so.
enum Learner {
    private struct Pasted { let text: String; let before: String; let element: AXUIElement }
    private static var last: Pasted?
    private static var pending: DispatchWorkItem?

    /// Call just before pasting, with the text about to go in.
    static func willPaste(_ text: String) {
        review()
        guard Prefs.learnWords, let element = ScreenContext.focusedElement(),
              let before = ScreenContext.text(of: element) else { last = nil; return }
        last = Pasted(text: text, before: before, element: element)
        let work = DispatchWorkItem { review() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// Compares what was typed with what the text box holds now. Runs once per dictation.
    static func review() {
        pending?.cancel(); pending = nil
        guard let pasted = last else { return }
        last = nil
        guard let now = ScreenContext.text(of: pasted.element) else { return }
        if let suggestion = correction(typed: pasted.text, before: pasted.before, after: now) {
            Store.shared.suggest(suggestion)
        }
    }

    /// One typed word gone and one similar new word in its place means a spelling was fixed.
    static func correction(typed: String, before: String, after: String) -> Replacement? {
        func words(_ s: String) -> [String] {
            s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        }
        let afterWords = Set(words(after)), beforeWords = Set(words(before)), typedWords = words(typed)
        let missing = Array(Set(typedWords.filter { !afterWords.contains($0) }))
        let fresh = afterWords.subtracting(beforeWords).subtracting(typedWords)
        guard missing.count == 1, fresh.count == 1, let was = missing.first, let now = fresh.first,
              was.lowercased() != now.lowercased() else { return nil }
        let allowed = max(2, max(was.count, now.count) / 3)
        guard distance(was.lowercased(), now.lowercased()) <= allowed else { return nil }
        return Replacement(heard: was, write: now)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return x.isEmpty ? y.count : row[y.count]
    }
}
