import Foundation
import MurmurCore

// A plain executable instead of XCTest, so the checks run with Command Line Tools alone.

var passed = 0, failed = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() { passed += 1 } else { failed += 1; print("FAIL  \(name)") }
}

func eq(_ name: String, _ got: String, _ want: String) {
    if got == want { passed += 1 } else { failed += 1; print("FAIL  \(name)\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)") }
}

// MARK: Text rules

eq("fillers go", TextRules.tidy(TextRules.removeFillers("Um, so I think, uh, we should go.")), "So I think, we should go.")
eq("fillers keep real words", TextRules.removeFillers("The umbrella hummed, uhuh"), "The umbrella hummed, uhuh")
eq("filler at end", TextRules.tidy(TextRules.removeFillers("Let me think, um.")), "Let me think.")
eq("non-speech tags", TextRules.stripNonSpeech("[BLANK_AUDIO] hello (music)"), "hello")
check("hallucination: thank you", TextRules.isHallucination("Thank you."))
check("hallucination: empty", TextRules.isHallucination("  "))
check("not hallucination", !TextRules.isHallucination("Thank you for sending the report over."))

let reps = [
    Replacement(heard: "acme", write: "Acme."),
    Replacement(heard: "new york", write: "NYC"),
    Replacement(heard: "new york city", write: "New York City"),
    Replacement(write: "Kubernetes"),
]
eq("replacement whole word", TextRules.applyReplacements("I love acme and Acme watches, not acmes", reps),
   "I love Acme. and Acme. watches, not acmes")
eq("replacement longest first", TextRules.applyReplacements("from new york city to New York", reps),
   "from New York City to NYC")
eq("replacement with $", TextRules.applyReplacements("costs five bucks", [Replacement(heard: "five bucks", write: "$5")]), "costs $5")
eq("vocabulary prompt", TextRules.vocabularyPrompt(reps), "Glossary: Acme., NYC, New York City, Kubernetes.")
eq("vocabulary prompt empty", TextRules.vocabularyPrompt([]), "")

let snippets = [Snippet(trigger: "my address", expansion: "1 Infinite Loop\nCupertino")]
eq("snippet alone", TextRules.applySnippets("My address.", snippets), "1 Infinite Loop\nCupertino")
eq("snippet inline", TextRules.applySnippets("Send it to my address please", snippets), "Send it to 1 Infinite Loop\nCupertino please")
eq("snippet no partial", TextRules.applySnippets("my addresses", snippets), "my addresses")

eq("new line", TextRules.tidy(TextRules.applySpokenCommands("Hello there. New line. how are you")), "Hello there.\nHow are you")
eq("new paragraph", TextRules.tidy(TextRules.applySpokenCommands("First point, new paragraph, second point")), "First point\n\nSecond point")
eq("newline not inside words", TextRules.applySpokenCommands("a brand-new linen shirt"), "a brand-new linen shirt")
eq("tidy spacing", TextRules.tidy("hello  ,  world .  ok"), "Hello, world. ok")
eq("word count", String(TextRules.wordCount("Hello, world — it's 5 o'clock.")), "5")

eq("pipeline", TextRules.process(" [BLANK_AUDIO] um, meet me in new york, new line thanks",
                                 replacements: reps, snippets: snippets), "Meet me in NYC\nThanks")
eq("pipeline options off", TextRules.process("um, new line",
                                             replacements: [], snippets: [],
                                             options: .init(removeFillers: false, spokenCommands: false)), "Um, new line")

// MARK: Cleanup guard

let said = "um so can you send me the the report by friday no wait by thursday"
eq("accept normal", CleanupPrompt.accept(original: said, cleaned: "Can you send me the report by Thursday?") ?? "nil",
   "Can you send me the report by Thursday?")
eq("accept strips tags", CleanupPrompt.accept(original: said, cleaned: "<transcript>\nCan you send me the report by Thursday?\n</transcript>") ?? "nil",
   "Can you send me the report by Thursday?")
eq("accept strips preface", CleanupPrompt.accept(original: said, cleaned: "Here is the cleaned text: Can you send me the report by Thursday?") ?? "nil",
   "Can you send me the report by Thursday?")
eq("accept strips quotes", CleanupPrompt.accept(original: said, cleaned: "\"Can you send me the report by Thursday?\"") ?? "nil",
   "Can you send me the report by Thursday?")
eq("accept trims line ends", CleanupPrompt.accept(original: "list milk eggs", cleaned: "List:  \n- Milk  \n- Eggs") ?? "nil", "List:\n- Milk\n- Eggs")
check("reject an answer", CleanupPrompt.accept(original: "what is the capital of france",
      cleaned: "The capital of France is Paris, a city known for the Eiffel Tower and its museums.") == nil)
check("reject a refusal", CleanupPrompt.accept(original: said, cleaned: "I'm sorry, but I can't help with that request.") == nil)
check("reject a summary", CleanupPrompt.accept(
      original: "so today we talked about the budget and then we went through every single line item and after that we agreed to meet again next week on tuesday",
      cleaned: "Budget meeting recap.") == nil)
check("reject empty", CleanupPrompt.accept(original: said, cleaned: "  ") == nil)
check("short question kept", CleanupPrompt.accept(original: "what time is it", cleaned: "What time is it?") == "What time is it?")
check("instructions mention vocabulary",
      CleanupPrompt.instructions(level: .polished, tone: .formal, vocabulary: ["Kubernetes"]).contains("Kubernetes"))
check("light has no list rule", !CleanupPrompt.instructions(level: .light, tone: .neutral, vocabulary: []).contains("list"))

check("doubled text detected", TextRules.isDoubled("Hello world. Hello world."))
check("normal text not doubled", !TextRules.isDoubled("Hello world. Hello there."))
check("single word not doubled", !TextRules.isDoubled("Hello."))

// MARK: Skipping the model

func needs(_ raw: String, level: CleanupLevel = .polished, tone: Tone = .neutral) -> Bool {
    CleanupPrompt.needsModel(raw: raw, ruled: TextRules.process(raw, replacements: [], snippets: []), level: level, tone: tone)
}
check("clean sentence skips", !needs("Can you send me the report by Thursday?"))
check("clean two sentences skip", !needs("I'll be there at six. Save me a seat."))
check("fillers need polish", needs("Um, can you send me the report by Thursday?"))
check("fillers fine for light", !needs("Um, can you send me the report by Thursday?", level: .light))
check("self-correction needs model", needs("Let's meet at five, no wait, six on Friday."))
check("bare no-comma correction", needs("Let's meet at five. No, six on Friday."))
check("list needs model", needs("Shopping list. First, oat milk. Second, avocados."))
check("stutter needs model", needs("Bring the the slides to the meeting.", level: .light))
check("unpunctuated needs model", needs("so can you send me the report by thursday please", level: .light))
check("missing end punctuation needs model", needs("Can you send me the report by Thursday", level: .light))
check("formal always needs model", needs("See you at six.", tone: .formal))
check("verbatim never", !needs("um the the thing", tone: .verbatim))
check("off never", !needs("um the the thing", level: .off))
check("two words skip", !needs("Sounds good."))
check("long ramble needs polish", needs(Array(repeating: "This is a clean sentence.", count: 30).joined(separator: " ")))
check("medium clean passage skips", !needs("I wanted to follow up on the launch plan. Marketing would like it to go out on the second Tuesday of next month. Let me know if that works."))
check("actual word 'like' alone is fine", !needs("I like the new design a lot."))

// MARK: Pause detection

func runDetector(_ pattern: [(Float, Double)]) -> [Int] {
    var detector = PauseDetector(), cuts: [Int] = []
    let block = 683   // one microphone buffer at 16 kHz
    for (level, seconds) in pattern {
        for _ in 0..<Int(seconds * 16_000 / Double(block)) {
            if let cut = detector.feed(level: level, count: block) { cuts.append(cut) }
        }
    }
    return cuts
}
let twoPhrases = runDetector([(0.2, 0.3), (0.6, 5), (0.2, 0.9), (0.6, 5), (0.2, 0.9), (0.6, 2)])
check("two pauses found", twoPhrases.count == 2)
check("first cut inside first pause", twoPhrases.first.map { $0 > Int(5.3 * 16_000) && $0 < Int(6.2 * 16_000) } ?? false)
let shortPhrases = runDetector([(0.6, 2), (0.2, 0.9), (0.6, 1.5), (0.2, 0.9), (0.6, 1)])
check("no cut before four seconds", shortPhrases.allSatisfy { $0 > 4 * 16_000 } && shortPhrases.count == 1)
check("brief dips are not pauses", runDetector([(0.6, 5), (0.2, 0.2), (0.6, 5)]).isEmpty)
check("steady noise never cuts", runDetector([(0.4, 20)]).isEmpty)
check("one cut per pause", runDetector([(0.6, 5), (0.2, 4), (0.6, 1)]).count == 1)
check("noisy room still finds pause", runDetector([(0.35, 0.3), (0.7, 6), (0.4, 0.8), (0.7, 3)]).count == 1)

// MARK: Stats

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!
let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!
func entry(_ daysAgo: Int, words: Int, seconds: Double) -> HistoryEntry {
    HistoryEntry(date: cal.date(byAdding: .day, value: -daysAgo, to: now)!,
                 text: Array(repeating: "word", count: words).joined(separator: " "), raw: "", duration: seconds)
}
let stats = Stats.compute([entry(0, words: 150, seconds: 60), entry(1, words: 150, seconds: 60),
                           entry(2, words: 100, seconds: 40), entry(4, words: 10, seconds: 4), entry(30, words: 90, seconds: 36)],
                          now: now, calendar: cal)
check("stats today", stats.wordsToday == 150)
check("stats week", stats.wordsThisWeek == 410)
check("stats all", stats.wordsAllTime == 500)
check("stats wpm", stats.wordsPerMinute == 150)
check("stats streak", stats.streak == 3)
check("stats days", stats.days.count == 14 && stats.days.last?.words == 150 && stats.days[9].words == 10)
check("stats saved", abs(stats.secondsSaved - (500.0 / 40 * 60 - 200)) < 0.01)
check("stats empty", Stats.compute([], now: now, calendar: cal).streak == 0)
check("streak counts from yesterday", Stats.compute([entry(1, words: 5, seconds: 2), entry(2, words: 5, seconds: 2)], now: now, calendar: cal).streak == 2)
eq("duration format", Stats.formatDuration(3900), "1 hr 5 min")

// MARK: Storage

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-check-\(UUID().uuidString)/history.json")
let original = [entry(0, words: 3, seconds: 1)]
JSONFile.save(original, to: tmp)
let loaded: [HistoryEntry] = JSONFile.load(tmp, default: [])
check("json round trip", loaded.count == 1 && loaded[0].id == original[0].id && loaded[0].words == 3)
check("json missing file", (JSONFile.load(tmp.appendingPathExtension("nope"), default: [Snippet]()) as [Snippet]).isEmpty)
try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

print("\(passed + failed) checks, \(failed) failures")
exit(failed == 0 ? 0 : 1)
