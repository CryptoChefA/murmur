import AppKit

/// Watches one modifier key system-wide. Modifier presses arrive as flagsChanged events,
/// so nothing here runs while the user is typing ordinary keys.
final class Hotkey {
    struct Choice: Identifiable, Equatable {
        let id: String
        let label: String
        let keyCode: UInt16
        let flag: NSEvent.ModifierFlags
    }

    static let choices: [Choice] = [
        Choice(id: "fn", label: "Fn (Globe)", keyCode: 63, flag: .function),
        Choice(id: "rightOption", label: "Right Option ⌥", keyCode: 61, flag: .option),
        Choice(id: "rightCommand", label: "Right Command ⌘", keyCode: 54, flag: .command),
        Choice(id: "rightControl", label: "Right Control ⌃", keyCode: 62, flag: .control),
    ]

    static func choice(_ id: String) -> Choice { choices.first { $0.id == id } ?? choices[0] }

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var escapeMonitors: [Any] = []
    private var isDown = false
    private var choice = Hotkey.choices[0]

    func start(choiceID: String) {
        stop()
        choice = Hotkey.choice(choiceID)
        let handler: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        watchEscape(false)
        isDown = false
    }

    /// Esc is only watched while a dictation is in progress.
    func watchEscape(_ on: Bool) {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
        guard on else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.onEscape?() }
        }) { escapeMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.onEscape?(); return nil }
            return event
        }) { escapeMonitors.append(m) }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == choice.keyCode else { return }
        let down = event.modifierFlags.contains(choice.flag)
        guard down != isDown else { return }
        isDown = down
        down ? onDown?() : onUp?()
    }
}
