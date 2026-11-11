import AppKit
import MurmurCore

// `Murmur --transcribe file.wav` exercises the speech path without a microphone or any UI.
let arguments = CommandLine.arguments
if arguments.contains("--toggle") {
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.toggleNotification, object: nil,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
} else if let i = arguments.firstIndex(of: "--preview-notice") {
    let text = i + 1 < arguments.count ? arguments[i + 1] : "Didn't hear anything"
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.previewNotification, object: text,
                                                                 userInfo: nil, deliverImmediately: true)
    exit(0)
} else if arguments.contains("--transcribe") || arguments.contains("--render-screens") || arguments.contains("--render-icon") || arguments.contains("--render-demo") {
    CommandLineMode.run(arguments)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
