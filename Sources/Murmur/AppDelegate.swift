import AppKit
import SwiftUI
import MurmurCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var pill: PillController!
    private var window: NSWindow?
    private let dictation = Dictation.shared
    static let toggleNotification = Notification.Name("app.murmur.Murmur.toggle")
    static let previewNotification = Notification.Name("app.murmur.Murmur.previewNotice")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        pill = PillController(model: dictation.pill)
        dictation.onStateChange = { [weak self] in self?.updateIcon() }
        dictation.start()
        writeDiagnostics()

        // `Murmur --toggle` from a script or launcher starts or finishes a dictation.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleDictation),
                                                            name: AppDelegate.toggleNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.previewNotification, object: nil, queue: .main) { [weak self] note in
            self?.dictation.previewNotice(note.object as? String ?? "Didn't hear anything")
        }

        // First run, or anything missing: show Setup.
        let quiet = CommandLine.arguments.contains("--background")
        let ready = Permissions.accessibility && Permissions.microphone == .authorized && ModelCatalog.isInstalled(Prefs.modelID)
        if !quiet, !ready || !Prefs.defaults.bool(forKey: Prefs.Key.didOnboard) {
            showWindow(section: .setup)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.cancel(silently: true)
        WhisperEngine.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(section: nil)
        return false
    }

    /// With `debugKeepAudio` set, records what macOS says about this app's event permissions.
    private func writeDiagnostics() {
        guard Prefs.defaults.bool(forKey: "debugKeepAudio") else { return }
        let lines = [
            "date: \(Date())",
            "AXIsProcessTrusted: \(AXIsProcessTrusted())",
            "CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())",
            "CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())",
            "bundle: \(Bundle.main.bundlePath)",
        ]
        try? lines.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("diagnostics.txt"),
                                                  atomically: true, encoding: .utf8)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        writeDiagnostics()
        // Accessibility may have just been granted; global key monitors need re-arming.
        dictation.reloadHotkey()
    }

    /// Shown only while the main window is open. Without an Edit menu, ⌘C/⌘V/⌘A do nothing in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    // MARK: - Menu bar

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name = dictation.isRecording ? "waveform.circle.fill" : (dictation.paused ? "waveform.slash" : "waveform")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        button.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let key = Hotkey.choice(Prefs.hotkey).label

        let toggle = NSMenuItem(title: dictation.isRecording ? "Finish Dictation" : "Start Dictation",
                                action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !dictation.paused
        menu.addItem(toggle)
        let hint = NSMenuItem(title: dictation.paused ? "Paused" : "Or hold \(key) and speak", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let recent = Store.shared.history.prefix(5)
        if !recent.isEmpty {
            let paste = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLast), keyEquivalent: "")
            paste.target = self
            menu.addItem(paste)
            let header = NSMenuItem(title: "Recent — click to copy", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in recent {
                let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
                let title = flat.count > 48 ? String(flat.prefix(48)) + "…" : flat
                let item = NSMenuItem(title: title, action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Murmur…", action: #selector(openMain), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        let pause = NSMenuItem(title: dictation.paused ? "Resume" : "Pause Hotkey", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleDictation() { dictation.toggleFromMenu() }
    @objc private func pasteLast() { dictation.pasteLast() }
    @objc private func openMain() { showWindow(section: nil) }
    @objc private func togglePause() { dictation.paused.toggle(); updateIcon() }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Main window

    func showWindow(section: AppSection?) {
        if window == nil {
            let nav = Navigation()
            if let section { nav.section = section }
            let root = RootView()
                .environmentObject(Store.shared)
                .environmentObject(nav)
                .environmentObject(ModelDownloader.shared)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Murmur"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 780, height: 520)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: root)
            w.center()
            w.setFrameAutosaveName("MurmurMain")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app with no view tree in memory.
        Prefs.defaults.set(true, forKey: Prefs.Key.didOnboard)
        window?.contentView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
        dictation.reloadHotkey()
    }
}
