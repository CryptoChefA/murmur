import AppKit
import SwiftUI
import MurmurCore

/// `Murmur --render-screens <dir>` draws every screen, the pill and the app icon to PNG
/// files using sample data. Used for the README and for checking layouts without a display.
@MainActor
enum ScreenRenderer {
    static func render(into directory: URL) {
        _ = NSApplication.shared
        Prefs.register()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for section in AppSection.allCases {
                let nav = Navigation()
                nav.section = section
                let view = RootView()
                    .environmentObject(Store.demo())
                    .environmentObject(nav)
                    .environmentObject(ModelDownloader.shared)
                snapshot(view, size: NSSize(width: 900, height: 660), appearance: appearance,
                         to: directory.appendingPathComponent("\(section.rawValue)-\(suffix).png"))
            }

            let phases: [(String, PillModel.Phase)] = [
                ("listening", .listening(handsFree: false)), ("handsfree", .listening(handsFree: true)),
                ("thinking", .thinking), ("done", .notice("Copied — press ⌘V to paste", good: true)),
                ("problem", .notice("Didn't hear anything", good: false)),
            ]
            for (name, phase) in phases {
                let model = PillModel()
                model.phase = phase
                model.started = Date().addingTimeInterval(-7)
                model.voice = 0.6
                model.levels = (0..<PillModel.barCount).map { i in
                    Float(0.25 + 0.6 * abs(sin(Double(i) * 0.9)) * abs(cos(Double(i) * 0.37)))
                }
                snapshot(PillView(model: model).environment(\.staticRender, true).background(Theme.window), size: NSSize(width: 460, height: 84),
                         appearance: appearance, to: directory.appendingPathComponent("pill-\(name)-\(suffix).png"))
            }
        }

        // One spoken syllable, sampled along the way, to judge how the orb moves rather than how it poses.
        let motion = OrbMotion()
        var frames: [(Double, CGFloat)] = []
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for tick in 0..<96 {
            let t = Double(tick) / 60
            let target: CGFloat = (t > 0.15 && t < 0.75) ? 0.9 : (t > 1.0 && t < 1.25 ? 0.5 : 0)
            motion.step(toward: target, at: start.addingTimeInterval(t), thinking: false)
            if tick % 12 == 6 { frames.append((motion.flow, motion.energy)) }
        }
        let strip = HStack(spacing: 0) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                StillOrb(flow: frame.0, energy: frame.1, alert: 0).frame(width: 150, height: 150)
            }
            StillOrb(flow: 2.0, energy: 0.2, alert: 1).frame(width: 150, height: 150)
        }
        .padding(.vertical, 20)
        .background(Color(red: 0.05, green: 0.05, blue: 0.08))
        snapshot(strip, size: NSSize(width: CGFloat(frames.count + 1) * 150, height: 190), appearance: .darkAqua,
                 to: directory.appendingPathComponent("orb-preview.png"))

        renderIcon(to: directory.appendingPathComponent("icon-1024.png"))
    }

    static func renderIcon(to url: URL) {
        _ = NSApplication.shared
        let icon = ImageRenderer(content: AppIcon().frame(width: 1024, height: 1024))
        icon.scale = 1
        if let image = icon.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private static func snapshot<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }
}

/// The app icon, drawn in code so the repo needs no binary artwork.
struct AppIcon: View {
    private let bars: [CGFloat] = [0.22, 0.42, 0.7, 0.36, 0.56, 0.26]

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.47, green: 0.43, blue: 0.98), Color(red: 0.22, green: 0.18, blue: 0.62)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(side * 0.098)
                    .shadow(color: .black.opacity(0.25), radius: side * 0.02, y: side * 0.012)
                HStack(spacing: side * 0.042) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                        Capsule().fill(Color.white.opacity(0.96))
                            .frame(width: side * 0.058, height: side * 0.62 * height)
                    }
                }
            }
        }
    }
}
