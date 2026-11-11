import AppKit
import SwiftUI

/// `Murmur --render-demo <dir>` draws a short scripted dictation, frame by frame, as PNG files.
/// The README's animation is assembled from them. Nothing is recorded: the words are scripted.
@MainActor
enum DemoRenderer {
    static let fps = 15.0
    static let length = 7.2
    static let said = "um so can we move the design review to thursday at three no wait four".split(separator: " ").map(String.init)
    static let typed = "Can we move the design review to Thursday at four?"

    static func render(into directory: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let motion = OrbMotion()
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var clock = 0.0
        let frames = Int(length * fps)
        for index in 0..<frames {
            let t = Double(index) / fps
            // Advance the orb at display rate so its motion matches the real app.
            while clock < t {
                let speaking = clock > 0.8 && clock < 3.7
                let syllable = abs(sin(clock * 7.3)) * (0.55 + 0.45 * abs(sin(clock * 1.9)))
                motion.step(toward: speaking ? CGFloat(0.25 + 0.7 * syllable) : 0, at: start.addingTimeInterval(clock),
                            thinking: clock >= 3.7)
                clock += 1.0 / 60
            }
            let renderer = ImageRenderer(content: DemoFrame(t: t, flow: motion.flow, energy: motion.energy)
                .frame(width: 760, height: 460).environment(\.colorScheme, .dark))
            renderer.scale = 1.5
            guard let image = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent(String(format: "frame-%03d.png", index)))
        }
    }
}

private func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
    let x = min(1, max(0, (t - from) / (to - from)))
    return x * x * (3 - 2 * x)
}

private struct DemoFrame: View {
    let t: Double
    let flow: Double
    let energy: CGFloat

    private var holding: Bool { t >= 0.5 && t < 3.7 }
    private var wordsShown: Int { max(0, min(DemoRenderer.said.count, Int((t - 0.9) / 0.19))) }
    private var pasted: Bool { t >= 4.7 }

    var body: some View {
        ZStack {
            Theme.window
            Theme.sheen

            VStack(spacing: 0) {
                // A plain mail draft: the app being typed into.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.16)).frame(width: 10, height: 10) }
                        Spacer()
                        Text("New Message").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Color.clear.frame(width: 44, height: 1)
                    }
                    .padding(.horizontal, 14).frame(height: 36)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    field("To", "Priya")
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    field("Subject", "Design review")
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(alignment: .top, spacing: 1) {
                        Text(pasted ? DemoRenderer.typed : "")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.94))
                        Rectangle().fill(Theme.accent).frame(width: 1.5, height: 18)
                            .opacity(Int(t * 2) % 2 == 0 || holding ? 1 : 0.15)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    Spacer(minLength: 0)
                }
                .frame(width: 520, height: 214)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .padding(.top, 34)

                Spacer(minLength: 0)

                // What was actually said, shown as it is spoken.
                Text(DemoRenderer.said.prefix(wordsShown).joined(separator: " "))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.46))
                    .frame(height: 18)
                    .opacity(1 - ramp(t, 4.5, 4.9))
                    .padding(.bottom, 12)

                pill
                    .frame(height: 84)
                    .opacity(ramp(t, 0.5, 0.75) * (1 - ramp(t, 4.9, 5.4)))
                    .padding(.bottom, 20)
            }

            // The key being held.
            VStack {
                Spacer()
                HStack {
                    Text("fn")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(holding ? 0.95 : 0.5))
                        .frame(width: 46, height: 42)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(holding ? Theme.accent.opacity(0.30) : Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(holding ? Theme.accent.opacity(0.9) : Color.white.opacity(0.16), lineWidth: 1))
                        .offset(y: holding ? 1.5 : 0)
                    Text(holding ? "holding" : (t < 0.5 ? "hold to talk" : "released"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer()
                }
                .padding(.leading, 28).padding(.bottom, 34)
            }
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
            Text(value).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 34)
    }

    /// The orb alone while speaking, then sliding left as its capsule opens.
    private var pill: some View {
        let p = ramp(t, 3.7, 4.1)
        let size = 76 - 36 * p
        let width = 76 + 104 * p
        let height = 76 - 26 * p
        return ZStack {
            Capsule()
                .fill(Color(red: 0.10, green: 0.10, blue: 0.13))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: width, height: height)
                .opacity(p)
            Text(t < 4.7 ? "Transcribing" : "Done")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .opacity(p)
                .offset(x: 22)
            StillOrb(flow: flow, energy: energy, alert: 0)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(0.5)).blur(radius: 5).offset(y: 3))
                .offset(x: -(width / 2 - size / 2 - 5) * p)
        }
    }
}
