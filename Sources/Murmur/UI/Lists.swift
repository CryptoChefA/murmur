import SwiftUI
import UniformTypeIdentifiers
import MurmurCore

struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }
}

extension View {
    func fieldBox() -> some View { modifier(FieldBox()) }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject private var store: Store
    @State private var heard = ""
    @State private var write = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Heard as (optional)", text: $heard).fieldBox()
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                        TextField("Write as", text: $write).fieldBox().onSubmit(add)
                        Button("Add", action: add)
                            .keyboardShortcut(.defaultAction)
                            .disabled(write.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Add a word on its own to teach Murmur the spelling. Fill in “heard as” when it keeps writing the wrong thing.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            if store.dictionary.isEmpty {
                Card {
                    EmptyState(symbol: "character.book.closed", title: "No words yet",
                               detail: "Add names, products and jargon. They're given to the speech model as hints and enforced after it.")
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.dictionary.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { RowDivider().padding(.leading, 16) }
                            HStack(spacing: 8) {
                                if entry.heard.isEmpty {
                                    Text(entry.write).font(.system(size: 13, weight: .medium))
                                    Tag(text: "spelling")
                                } else {
                                    Text(entry.heard).font(.system(size: 13)).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Text(entry.write).font(.system(size: 13, weight: .medium))
                                }
                                Spacer()
                                IconButton(symbol: "trash", help: "Remove \(entry.write)") {
                                    store.dictionary.removeAll { $0.id == entry.id }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let w = write.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        store.dictionary.insert(Replacement(heard: heard.trimmingCharacters(in: .whitespaces), write: w), at: 0)
        heard = ""; write = ""
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject private var store: Store
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("When I say…  e.g. my email", text: $trigger).fieldBox()
                    TextField("Write…  e.g. hello@example.com", text: $expansion, axis: .vertical)
                        .lineLimit(2...5)
                        .fieldBox()
                    HStack {
                        Text("Works on its own or in the middle of a sentence.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Snippet", action: add)
                            .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
                    }
                }
            }

            if store.snippets.isEmpty {
                Card {
                    EmptyState(symbol: "text.insert", title: "No snippets yet",
                               detail: "Good for addresses, links, sign-offs and anything you say the same way every time.")
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { RowDivider().padding(.leading, 16) }
                            HStack(alignment: .top, spacing: 12) {
                                Text("“\(snippet.trigger)”")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 150, alignment: .leading)
                                Text(snippet.expansion)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                IconButton(symbol: "trash", help: "Remove \(snippet.trigger)") {
                                    store.snippets.removeAll { $0.id == snippet.id }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !expansion.isEmpty else { return }
        store.snippets.insert(Snippet(trigger: t, expansion: expansion), at: 0)
        trigger = ""; expansion = ""
    }
}

// MARK: - Styles

struct StylesView: View {
    @EnvironmentObject private var store: Store
    @AppStorage(Prefs.Key.cleanupLevel) private var cleanupLevel = CleanupLevel.polished.rawValue
    @AppStorage(Prefs.Key.removeFillers) private var removeFillers = true
    @AppStorage(Prefs.Key.spokenCommands) private var spokenCommands = true

    private var level: CleanupLevel { CleanupLevel(rawValue: cleanupLevel) ?? .polished }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupTitle("Cleanup")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Cleanup level", selection: $cleanupLevel) {
                        ForEach(CleanupLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(level.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Example(level: level)
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    SettingRow(title: "Remove “um” and “uh”", detail: "Applied before the AI, so it works with cleanup off.") {
                        Toggle("Remove “um” and “uh”", isOn: $removeFillers).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    RowDivider()
                    SettingRow(title: "Spoken line breaks", detail: "Say “new line” or “new paragraph”.") {
                        Toggle("Spoken line breaks", isOn: $spokenCommands).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack {
                GroupTitle("Tone by app")
                Spacer()
                Button("Add App…", action: addApp)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Everything else").font(.system(size: 13))
                        Spacer()
                        Text("Neutral").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    ForEach($store.styles) { $rule in
                        RowDivider().padding(.leading, 16)
                        HStack(spacing: 10) {
                            Text(rule.appName).font(.system(size: 13))
                            Spacer()
                            Picker("Tone for \(rule.appName)", selection: $rule.tone) {
                                ForEach(Tone.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .help(rule.tone.blurb)
                            IconButton(symbol: "trash", help: "Remove \(rule.appName)") {
                                let id = rule.id
                                store.styles.removeAll { $0.id == id }
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                    }
                }
            }
            Text("Verbatim skips AI cleanup entirely, which is what you want in terminals and code editors.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !store.styles.contains(where: { $0.bundleID == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        store.styles.append(StyleRule(bundleID: id, appName: name, tone: .neutral))
    }
}

private struct Example: View {
    let level: CleanupLevel

    private var after: String {
        switch level {
        case .off: return "So let's meet at five, no, six on Friday. And bring the the slides."
        case .light: return "So let's meet at five, no, six on Friday, and bring the slides."
        case .polished: return "Let's meet at six on Friday, and bring the slides."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("You say", "um so let's meet at five no six on friday and uh bring the the slides", dim: true)
            line("You get", after, dim: false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func line(_ label: String, _ text: String, dim: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(dim ? Color.secondary : Color.primary)
        }
    }
}
