import AppKit
import Combine

/// Looks for a newer Murmur on GitHub and, for a copy built from source, rebuilds it in place.
/// The check is one request to GitHub's public API. It sends nothing about the user, and it can
/// be switched off in Settings. There is no repeating timer: it runs at launch and when the
/// menu is opened, at most once a day.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "CryptoChefA/murmur"

    enum Status: Equatable { case unknown, checking, current, available(Int), failed(String), installing }
    @Published var status: Status = .unknown

    /// The commit this copy was built from, written into the bundle by build.sh.
    var commit: String { Bundle.main.object(forInfoDictionaryKey: "MurmurCommit") as? String ?? "" }
    /// Where the source lives on this Mac, if it was built here.
    var source: String { Bundle.main.object(forInfoDictionaryKey: "MurmurSource") as? String ?? "" }
    var canInstall: Bool { !source.isEmpty && FileManager.default.fileExists(atPath: source + "/build.sh") }

    var summary: String {
        switch status {
        case .unknown: return commit.isEmpty ? "This copy doesn't know its version." : "Version \(commit.prefix(7))"
        case .checking: return "Checking…"
        case .current: return "Up to date (\(commit.prefix(7)))"
        case .available(let n): return n == 1 ? "1 update is waiting" : "\(n) updates are waiting"
        case .failed(let why): return why
        case .installing: return "Updating. Murmur will reopen when it's done."
        }
    }

    func checkIfDue() {
        guard Prefs.defaults.bool(forKey: Prefs.Key.updateChecks) else { return }
        let last = Prefs.defaults.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check()
    }

    func check() {
        guard !commit.isEmpty, status != .checking, status != .installing,
              let url = URL(string: "https://api.github.com/repos/\(Updater.repository)/compare/\(commit)...main") else {
            if commit.isEmpty { status = .failed("This copy doesn't know its version. Rebuild it once with build.sh.") }
            return
        }
        status = .checking
        Prefs.defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Murmur", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ahead = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["ahead_by"] as? Int
            DispatchQueue.main.async {
                if let ahead { self.status = ahead > 0 ? .available(ahead) : .current }
                // A commit GitHub has never seen is a local build ahead of the published one.
                else if code == 404 { self.status = .current }
                else { self.status = .failed("Couldn't reach GitHub.") }
            }
        }.resume()
    }

    /// Pulls the new source and rebuilds, then reopens. Only ever run from a click.
    func install() {
        guard canInstall else {
            if let url = URL(string: "https://github.com/\(Updater.repository)") { NSWorkspace.shared.open(url) }
            return
        }
        status = .installing
        let log = Paths.support.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "git pull --ff-only && ./build.sh --install"]
        process.currentDirectoryURL = URL(fileURLWithPath: source)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                guard finished.terminationStatus == 0 else {
                    self.status = .failed("The update didn't build. Details are in update.log in Murmur's support folder.")
                    return
                }
                let reopen = Process()
                reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
                reopen.arguments = ["-c", "sleep 1; open -a /Applications/Murmur.app --args --background"]
                try? reopen.run()
                NSApp.terminate(nil)
            }
        }
        do { try process.run() } catch { status = .failed("Couldn't start the update.") }
    }
}
