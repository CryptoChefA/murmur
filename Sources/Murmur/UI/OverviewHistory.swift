import SwiftUI
import MurmurCore

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var downloader: ModelDownloader
    @AppStorage(Prefs.Key.modelID) private var modelID = ModelCatalog.defaultID
    @AppStorage(Prefs.Key.cleanupLevel) private var cleanupLevel = CleanupLevel.polished.rawValue
    @AppStorage(Prefs.Key.cleanupEngine) private var cleanupEngine = CleanupEngine.onDevice.rawValue

    var body: some View {
        let stats = store.stats
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatCard(value: stats.wordsToday.formatted(), label: "words today")
                StatCard(value: stats.wordsThisWeek.formatted(), label: "last 7 days")
                StatCard(value: stats.wordsPerMinute == 0 ? "—" : "\(stats.wordsPerMinute)", label: "words per minute")
                StatCard(value: stats.streak == 0 ? "—" : "\(stats.streak)", label: stats.streak == 1 ? "day streak" : "day streak")
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Last 14 days").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(stats.wordsAllTime.formatted()) words all time · \(Stats.formatDuration(stats.secondsSaved)) saved vs typing")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    ActivityChart(days: stats.days)
                        .frame(height: 120)
                }
            }

            Card(padding: 0) {
                VStack(spacing: 0) {
                    statusRow(symbol: "waveform", title: "Speech", value: ModelCatalog.model(modelID).name,
                              ok: ModelCatalog.isInstalled(modelID), problem: "Not downloaded")
                    RowDivider().padding(.leading, 44)
                    statusRow(symbol: "wand.and.stars", title: "Cleanup", value: cleanupSummary, ok: cleanupProblem == nil, problem: cleanupProblem ?? "")
                    RowDivider().padding(.leading, 44)
                    statusRow(symbol: "lock", title: "Privacy", value: privacySummary, ok: true, problem: "")
                }
            }

            if !store.history.isEmpty {
                HStack {
                    GroupTitle("Recent")
                    Spacer()
                    Button("See all") { nav.section = .history }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.history.prefix(3).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider().padding(.leading, 16) }
                            HistoryRow(entry: entry, compact: true)
                        }
                    }
                }
            } else {
                Card {
                    EmptyState(symbol: "mic", title: "Nothing dictated yet",
                               detail: "Click into any text field, hold the key, and talk. Your words appear when you let go.")
                }
            }
        }
        .id(downloader.revision)
    }

    private var cleanupSummary: String {
        let level = CleanupLevel(rawValue: cleanupLevel) ?? .polished
        if level == .off { return "Off" }
        let engine = CleanupEngine(rawValue: cleanupEngine) ?? .onDevice
        return "\(level.label) · \(engine.label)"
    }

    private var cleanupProblem: String? {
        let level = CleanupLevel(rawValue: cleanupLevel) ?? .polished
        let engine = CleanupEngine(rawValue: cleanupEngine) ?? .onDevice
        if level == .off { return nil }
        if engine == .onDevice { return Cleanup.onDeviceProblem }
        return (Keychain.get(engine.rawValue) ?? "").isEmpty ? "No API key" : nil
    }

    private var privacySummary: String {
        let engine = CleanupEngine(rawValue: cleanupEngine) ?? .onDevice
        let level = CleanupLevel(rawValue: cleanupLevel) ?? .polished
        if engine.isCloud && level != .off { return "Audio stays on this Mac · text goes to \(engine.label) for cleanup" }
        return "Nothing leaves this Mac"
    }

    private func statusRow(symbol: String, title: String, value: String, ok: Bool, problem: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(ok ? value : problem)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Circle().fill(ok ? Theme.good : Theme.warn).frame(width: 7, height: 7)
                .accessibilityLabel(ok ? "OK" : "Needs attention")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

private struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityChart: View {
    let days: [Stats.Day]
    @State private var hovered: Date?

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.words == 0 ? Color.primary.opacity(0.07) : Theme.accent.opacity(hovered == day.date ? 1 : 0.8))
                            .frame(height: barHeight(day.words, peak: peak))
                    }
                    .overlay(alignment: .top) {
                        if hovered == day.date {
                            Text("\(day.words)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    Text(label(day.date))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .onHover { hovered = $0 ? day.date : nil }
                .accessibilityElement()
                .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.words) words")
            }
        }
    }

    private func barHeight(_ words: Int, peak: Int) -> CGFloat {
        if words == 0 { return 3 }
        return max(6, CGFloat(words) / CGFloat(peak) * 84)
    }

    private func label(_ date: Date) -> String {
        String(date.formatted(.dateTime.weekday(.narrow)))
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var store: Store
    @AppStorage(Prefs.Key.retentionDays) private var retentionDays = 0
    @State private var query = ""
    @State private var confirmClear = false

    private var results: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Search dictations", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

                Picker("Keep", selection: $retentionDays) {
                    Text("Keep forever").tag(0)
                    Text("Keep 30 days").tag(30)
                    Text("Keep 7 days").tag(7)
                    Text("Don't keep").tag(-1)
                }
                .labelsHidden()
                .frame(width: 140)

                Button("Clear All…", role: .destructive) { confirmClear = true }
                    .disabled(store.history.isEmpty)
            }
            .confirmationDialog("Delete all \(store.history.count) dictations?", isPresented: $confirmClear) {
                Button("Delete All", role: .destructive) { store.history = [] }
            } message: {
                Text("This also resets your stats. It can't be undone.")
            }

            let entries = results
            if entries.isEmpty {
                Card {
                    EmptyState(symbol: store.history.isEmpty ? "clock" : "magnifyingglass",
                               title: store.history.isEmpty ? "No history yet" : "No matches",
                               detail: store.history.isEmpty
                                   ? (retentionDays < 0 ? "History is off, so dictations aren't saved." : "Dictations show up here as you make them.")
                                   : "Nothing you've dictated contains “\(query)”.")
                }
            } else {
                Card(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.prefix(300).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider().padding(.leading, 16) }
                            HistoryRow(entry: entry, compact: false)
                        }
                    }
                }
                if entries.count > 300 {
                    Text("Showing the newest 300 of \(entries.count). Search to find older ones.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var store: Store
    let entry: HistoryEntry
    let compact: Bool
    @State private var hovering = false
    @State private var showRaw = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .lineLimit(compact ? 2 : 8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                    if !compact {
                        IconButton(symbol: "trash", help: "Delete") { store.history.removeAll { $0.id == entry.id } }
                    }
                }
                .opacity(hovering || copied ? 1 : 0)
            }
            HStack(spacing: 6) {
                Text(entry.date.formatted(.relative(presentation: .named)))
                if !entry.app.isEmpty { Text("·"); Text(entry.app) }
                Text("·"); Text("\(entry.words) words")
                if entry.cleanup != "none" { Tag(text: "cleaned") }
                if !compact, entry.raw != entry.text, !entry.raw.isEmpty {
                    Button(showRaw ? "Hide original" : "Show original") { showRaw.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if showRaw {
                Text(entry.raw)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
