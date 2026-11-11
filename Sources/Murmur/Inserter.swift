import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Shows the system prompt that deep-links to the Accessibility list.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// What the Globe key is set to do in System Settings › Keyboard. 0 means "Do Nothing".
    static var globeKeyIsFree: Bool {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value == 0
    }
}

/// Puts text at the cursor of whatever app is in front, by pasting.
enum Inserter {
    enum Outcome { case pasted, copiedOnly }

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        guard Permissions.accessibility else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        // Either the dictation stays on the clipboard (the user's choice in Settings), or what was
        // there before is kept and put back, so dictating doesn't cost the user their copy.
        let keep = Prefs.keepOnClipboard
        let saved: [[NSPasteboard.PasteboardType: Data]] = keep ? [] : (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { contents[type] = data } }
            return contents
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Asks clipboard managers not to record this. Not when it is meant to stay.
        if !keep { pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        let marker = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        if UserDefaults.standard.bool(forKey: "debugKeepAudio") {
            let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            let line = "paste posted: events=\(down != nil && up != nil) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") keyWindowResponder=\(responder)\n"
            let url = Paths.support.appendingPathComponent("paste-log.txt")
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
        }

        if keep { return .pasted }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // If something else has been copied since, leave it alone.
            guard pasteboard.changeCount == marker else { return }
            pasteboard.clearContents()
            guard !saved.isEmpty else { return }
            let items: [NSPasteboardItem] = saved.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        return .pasted
    }
}
