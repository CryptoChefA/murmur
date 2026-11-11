import Foundation

public struct Stats: Equatable {
    public struct Day: Equatable, Identifiable {
        public var date: Date
        public var words: Int
        public var id: Date { date }
    }

    public var wordsToday = 0
    public var wordsThisWeek = 0
    public var wordsAllTime = 0
    public var dictations = 0
    /// Speaking pace across everything in history.
    public var wordsPerMinute = 0
    /// Seconds saved versus typing the same words.
    public var secondsSaved: Double = 0
    /// Consecutive days with at least one dictation, ending today or yesterday.
    public var streak = 0
    /// Oldest first, always `dayCount` entries.
    public var days: [Day] = []

    public static let typingWordsPerMinute = 40.0

    public static func compute(_ entries: [HistoryEntry], now: Date = Date(),
                               calendar: Calendar = .current, dayCount: Int = 14) -> Stats {
        var s = Stats()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        var perDay: [Date: Int] = [:]
        var speech = 0.0, timedWords = 0

        for e in entries {
            let day = calendar.startOfDay(for: e.date)
            perDay[day, default: 0] += e.words
            s.wordsAllTime += e.words
            if day == today { s.wordsToday += e.words }
            if day >= weekStart { s.wordsThisWeek += e.words }
            if e.duration > 0.5 { speech += e.duration; timedWords += e.words }
        }
        s.dictations = entries.count
        if speech > 0 { s.wordsPerMinute = Int((Double(timedWords) / speech * 60).rounded()) }
        s.secondsSaved = max(0, Double(timedWords) / typingWordsPerMinute * 60 - speech)

        var cursor = perDay[today] != nil ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while perDay[cursor] != nil {
            s.streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        s.days = (0..<dayCount).reversed().map { back in
            let d = calendar.date(byAdding: .day, value: -back, to: today)!
            return Day(date: d, words: perDay[d] ?? 0)
        }
        return s
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(m) min" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h) hr" : "\(h) hr \(rest) min"
    }
}
