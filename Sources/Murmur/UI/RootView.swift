import SwiftUI
import MurmurCore

enum AppSection: String, CaseIterable, Identifiable {
    case overview, history, dictionary, snippets, styles, settings, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .settings: return "Settings"
        case .setup: return "Setup"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.bar"
        case .history: return "clock"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.insert"
        case .styles: return "wand.and.stars"
        case .settings: return "slider.horizontal.3"
        case .setup: return "checklist"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "How much you've said instead of typed."
        case .history: return "Everything you've dictated, stored only on this Mac."
        case .dictionary: return "Names and terms Murmur should always get right."
        case .snippets: return "Say a short phrase, get a longer one."
        case .styles: return "How much tidying, and the tone for each app."
        case .settings: return "Key, microphone, models and privacy."
        case .setup: return "Two permissions and a model, then you're done."
        }
    }
}

final class Navigation: ObservableObject {
    @Published var section: AppSection = .overview
}

/// The window takes its colours from the orb: deep navy-black, cool silver, a pale indigo
/// accent. It is always dark, like the orb's pill.
enum Theme {
    /// Pale indigo, the cool end of the chrome.
    static let accent = Color(red: 0.65, green: 0.71, blue: 0.99)
    /// Cool silver, the bright end.
    static let silver = Color(red: 0.80, green: 0.84, blue: 0.88)
    static let card = Color(red: 0.075, green: 0.085, blue: 0.135)
    static let window = Color(red: 0.035, green: 0.040, blue: 0.075)
    static let sidebar = Color(red: 0.027, green: 0.031, blue: 0.060)
    static let hairline = Color.white.opacity(0.075)
    static let good = Color(red: 0.45, green: 0.86, blue: 0.68)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.40)

    /// Brushed-chrome lettering for headings.
    static let chrome = LinearGradient(colors: [.white, Color(red: 0.72, green: 0.77, blue: 0.90)],
                                       startPoint: .top, endPoint: .bottom)
    /// A faint sheen across the top of the window, as if lit from the upper left.
    static let sheen = RadialGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.75).opacity(0.16), .clear],
                                      center: .topLeading, startRadius: 0, endRadius: 620)
}

struct RootView: View {
    @EnvironmentObject private var nav: Navigation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 204)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nav.section.title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.chrome)
                        Text(nav.section.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.sheen)
            .background(Theme.window)
        }
        .background(Theme.window)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 780, minHeight: 520)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch nav.section {
        case .overview: OverviewView()
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .styles: StylesView()
        case .settings: SettingsView()
        case .setup: SetupView()
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var nav: Navigation
    @AppStorage(Prefs.Key.hotkey) private var hotkey = "fn"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StillOrb(flow: 3.1, energy: 0.35, alert: 0)
                    .frame(width: 20, height: 20)
                Text("Murmur")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.chrome)
            }
            .padding(.leading, 10)
            .padding(.top, 44)
            .padding(.bottom, 14)

            ForEach(AppSection.allCases) { section in
                SidebarRow(section: section, selected: nav.section == section) { nav.section = section }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                Text("Hold \(Hotkey.choice(hotkey).label)")
                    .font(.system(size: 11, weight: .medium))
                Text("Double-tap for hands-free")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.085 : (hovering ? 0.04 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(selected ? 0.10 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            // Lit from above, like the rim of the pill.
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct GroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// One settings line: label and explanation on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 9)
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
