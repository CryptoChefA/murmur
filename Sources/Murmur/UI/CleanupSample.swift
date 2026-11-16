import SwiftUI
import MurmurCore

/// One spoken sentence and what each cleanup level makes of it, so the setting explains itself.
struct CleanupSample: View {
    let level: CleanupLevel

    static let said = "well um I, I think we should you know meet at five no six on friday and uh bring the the slides"

    static func result(_ level: CleanupLevel) -> String {
        switch level {
        case .off: return "Well, um, I, I think we should, you know, meet at five, no, six on Friday and, uh, bring the the slides."
        case .light: return "Well, I think we should, you know, meet at five, no, six on Friday and bring the slides."
        case .polished: return "Well, I think we should, you know, meet at six on Friday and bring the slides."
        case .thorough: return "I think we should meet at six on Friday and bring the slides."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line("You say", CleanupSample.said, dim: true)
            line("You get", CleanupSample.result(level), dim: false)
                .id(level)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .animation(.easeOut(duration: 0.25), value: level)
        .accessibilityElement(children: .combine)
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
