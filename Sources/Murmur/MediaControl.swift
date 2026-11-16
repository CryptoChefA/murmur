import AppKit
import CoreAudio

/// Gets music out of the way while you dictate, then puts it back.
///
/// Spotify and Apple Music are asked directly: only a player that is actually playing is
/// paused, and only a player Murmur paused is resumed, so nothing ever starts on its own.
/// Anything else that is making sound (a browser, a video) can't be paused that safely, so
/// the volume is lowered instead and restored afterwards.
final class MediaControl {
    static let shared = MediaControl()

    enum Mode: String, CaseIterable, Identifiable {
        case pause, lower, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pause: return "Pause music"
            case .lower: return "Lower the volume"
            case .off: return "Leave it playing"
            }
        }
    }

    private static let players: [(bundle: String, name: String)] = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]

    private let queue = DispatchQueue(label: "murmur.media", qos: .userInitiated)
    /// Players Murmur paused and still owes a resume. Kept until they are resumed, so a second
    /// dictation straight after the first can't make Murmur forget it paused them.
    /// Touched only on `queue`.
    private var pausedByUs: [String] = []
    private var lowered: (from: Int, to: Int)?
    private var resumeWork: DispatchWorkItem?

    /// Whether a dictation is in progress, readable from any thread.
    private let activeLock = NSLock()
    private var activeFlag = false
    private var active: Bool {
        get { activeLock.lock(); defer { activeLock.unlock() }; return activeFlag }
        set { activeLock.lock(); activeFlag = newValue; activeLock.unlock() }
    }

    /// Called at key-down, before Murmur's own start sound, so that sound isn't mistaken for music.
    /// The actual pausing waits a moment, so a stray tap of the key doesn't stutter the music.
    func dictationStarted(stillGoing: @escaping () -> Bool) {
        active = true
        resumeWork?.cancel(); resumeWork = nil
        let mode = Mode(rawValue: Prefs.defaults.string(forKey: Prefs.Key.whileDictating) ?? "") ?? .pause
        guard mode != .off else { return }
        guard AudioDevices.outputIsRunning else { MediaControl.log("music: nothing playing"); return }
        let running = MediaControl.players.filter { player in
            NSRunningApplication.runningApplications(withBundleIdentifier: player.bundle).isEmpty == false
        }.map(\.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard stillGoing() else { return }
            self.queue.async { self.quiet(mode: mode, running: running) }
        }
    }

    /// Called when the dictation is over, however it ended.
    func dictationEnded() {
        active = false
        resumeWork?.cancel()
        // A short wait, so dictating again straight away doesn't bounce the music.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.active else { return }
            self.queue.async { self.restore() }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - On the queue

    private func quiet(mode: Mode, running: [String]) {
        if mode == .pause, !running.isEmpty {
            var script = "set out to \"\"\n"
            for name in running {
                script += """
                tell application "\(name)"
                    if player state is playing then
                        pause
                        set out to out & "\(name)" & linefeed
                    end if
                end tell

                """
            }
            script += "return out"
            let newly = MediaControl.run(script).split(separator: "\n").map(String.init)
            for name in newly where !pausedByUs.contains(name) { pausedByUs.append(name) }
            MediaControl.log("music: asked \(running.joined(separator: ", ")), paused [\(newly.joined(separator: ", "))]\(lastError.isEmpty ? "" : ", error: " + lastError)")
            // Asking took long (the first time, macOS asks your permission) and the dictation is
            // already over: resume now rather than wait for a resume that has already passed.
            if !active { restore(); return }
            // Paused now or still paused from a moment ago: nothing more to do.
            if !pausedByUs.isEmpty { return }
        }
        guard lowered == nil else { return }
        // Nothing we can pause is playing, but something is: turn it down instead.
        let settings = MediaControl.run("set s to get volume settings\nreturn ((output volume of s) as text) & \" \" & ((output muted of s) as text)")
            .split(separator: " ")
        guard settings.count == 2, settings[1] == "false", let volume = Int(settings[0]), volume > 4 else {
            MediaControl.log("music: couldn't lower the volume (\(settings.joined(separator: " ")))")
            return
        }
        guard active else { return }
        let target = max(2, volume / 5)
        _ = MediaControl.run("set volume output volume \(target)")
        lowered = (volume, target)
        MediaControl.log("music: volume \(volume) lowered to \(target)")
    }

    private func restore() {
        guard !active else { return }
        if !pausedByUs.isEmpty {
            var script = ""
            for name in pausedByUs where MediaControl.players.contains(where: { $0.name == name }) {
                // Spotify can take a moment to report a pause; give it up to a second.
                script += """
                if application "\(name)" is running then
                    tell application "\(name)"
                        repeat 10 times
                            if player state is paused then
                                play
                                exit repeat
                            end if
                            delay 0.1
                        end repeat
                    end tell
                end if

                """
            }
            _ = MediaControl.run(script)
            MediaControl.log("music: resumed [\(pausedByUs.joined(separator: ", "))]\(lastError.isEmpty ? "" : ", error: " + lastError)")
            pausedByUs = []
        }
        if let lowered {
            // Only if the volume is still where Murmur left it.
            let now = Int(MediaControl.run("return output volume of (get volume settings)")) ?? -1
            if abs(now - lowered.to) <= 1 { _ = MediaControl.run("set volume output volume \(lowered.from)") }
            MediaControl.log("music: volume put back to \(lowered.from)")
            self.lowered = nil
        }
    }

    /// The last thing osascript complained about, for the activity log.
    private static var lastErrorText = ""
    private var lastError: String { MediaControl.lastErrorText }

    /// A line in activity.txt alongside the dictation lines: what was done to the music.
    static func log(_ what: String) {
        let url = Paths.support.appendingPathComponent("activity.txt")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(ISO8601DateFormatter().string(from: Date())) \(what)")
        try? lines.suffix(60).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs a short AppleScript with osascript and returns what it printed.
    @discardableResult
    private static func run(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { lastErrorText = "couldn't run osascript"; return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lastErrorText = String(decoding: complaint, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AudioDevices {
    /// Whether anything is playing through the current output right now.
    static var outputIsRunning: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
