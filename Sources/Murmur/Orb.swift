import SwiftUI

/// The moving parts of the orb, advanced once per display frame. Keeping the state here, and
/// integrating it over real elapsed time, is what makes the motion fluid: the microphone only
/// reports about 25 levels a second, and wave speed changes must never make the phase jump.
final class OrbMotion {
    /// Smoothed 0...1 voice energy.
    private(set) var energy: CGFloat = 0
    /// One running phase per ribbon of light.
    private(set) var phases: [Double] = [0, 2.1, 4.4]
    private var last: Date?

    private static let drift: [Double] = [1.9, -2.6, 3.4]

    func step(toward target: CGFloat, at date: Date, thinking: Bool) {
        let dt = min(0.05, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date

        // While transcribing there is no voice: breathe slowly instead.
        let goal = thinking ? 0.20 + 0.08 * CGFloat(sin(date.timeIntervalSinceReferenceDate * 2.2)) : target
        // Rise with the syllable, fall away gently after it.
        let rate: Double = goal > energy ? 16 : 4.5
        energy += (goal - energy) * CGFloat(1 - exp(-rate * dt))

        // Louder speech moves the light faster. Because the phase is accumulated, a change of
        // speed bends the motion smoothly instead of teleporting the wave.
        let pace = thinking ? 0.9 : 0.55 + 2.4 * Double(energy)
        for i in phases.indices { phases[i] += OrbMotion.drift[i] * pace * dt }
    }
}

/// A dark glass sphere with ribbons of light across its middle. In silence they lie together
/// as one calm line; as you speak they swell from the centre and separate, the way layered
/// voice waveforms do. Drawn in SwiftUI only, so it builds with Command Line Tools.
/// The centre-weighted ribbon maths follows the classic open-source SiriWave approach
/// (kopiro/siriwave, MIT); the wavy-surface idea follows metasidd/Orb (MIT).
struct OrbView: View {
    /// Smoothed 0...1 voice energy.
    var energy: CGFloat
    /// Three phases, one per ribbon.
    var phases: [Double]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            // The sphere leaves room to swell and to glow inside its frame.
            let r = side * 0.30 * (1 + 0.14 * energy)
            let rect = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
            let sphere = Path(ellipseIn: rect)

            // Light spilling out of the glass when the voice is strong.
            if energy > 0.02 {
                let reach = r * (1.25 + 0.35 * energy)
                context.fill(Path(ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)),
                             with: .radialGradient(
                                Gradient(stops: [.init(color: Color(red: 1.0, green: 0.78, blue: 0.55).opacity(0.50 * energy), location: 0.62),
                                                 .init(color: Color(red: 0.6, green: 0.75, blue: 1.0).opacity(0.18 * energy), location: 0.82),
                                                 .init(color: .clear, location: 1)]),
                                center: centre, startRadius: 0, endRadius: reach))
            }

            // 1. The glass body.
            context.fill(sphere, with: .radialGradient(
                Gradient(stops: [.init(color: Color(white: 0.30), location: 0),
                                 .init(color: Color(white: 0.13), location: 0.55),
                                 .init(color: Color(white: 0.03), location: 1)]),
                center: CGPoint(x: centre.x, y: centre.y - r * 0.35), startRadius: 0, endRadius: r * 1.25))

            context.drawLayer { inner in
                inner.clip(to: sphere)

                let baseY = centre.y - r * 0.04
                let amplitude = r * (0.022 + 0.50 * pow(energy, 0.85))

                /// One ribbon's height at u (-1 at the left rim, +1 at the right).
                /// `mix` weights three sine waves of different wavelength.
                func ribbonY(_ u: CGFloat, _ mix: (Double, Double, Double)) -> CGFloat {
                    let inside = max(0, 1 - u * u)
                    let envelope = inside * inside                 // pinned at the rim, free at the centre
                    let sag = r * 0.17 * inside                    // liquid seen through a lens
                    let x = Double(u)
                    let wave = mix.0 * sin(2.3 * x + phases[0]) + mix.1 * sin(3.9 * x + phases[1]) + mix.2 * sin(5.7 * x + phases[2])
                    return baseY + sag - amplitude * envelope * CGFloat(wave)
                }
                func ribbon(_ mix: (Double, Double, Double)) -> Path {
                    var path = Path()
                    let steps = 56
                    for i in 0...steps {
                        let u = CGFloat(i) / CGFloat(steps) * 2 - 1
                        let point = CGPoint(x: centre.x + u * r, y: ribbonY(u, mix))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    return path
                }
                let core = ribbon((0.55, 0.30, 0.15))
                let warm = ribbon((0.75, 0.25, 0.00))
                let cool = ribbon((0.10, 0.50, 0.40))

                // 2. Below the line: cool, misty liquid.
                var liquid = core
                liquid.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                liquid.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                liquid.closeSubpath()
                inner.fill(liquid, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.80),
                                      Color(red: 0.36, green: 0.40, blue: 0.47).opacity(0.50),
                                      Color(white: 0.10).opacity(0.15)]),
                    startPoint: CGPoint(x: centre.x, y: baseY), endPoint: CGPoint(x: centre.x, y: rect.maxY)))

                // 3. The ribbons of light, added together like light rather than paint.
                var light = inner
                light.blendMode = .plusLighter
                let glow = 0.50 + 0.50 * energy

                light.drawLayer { layer in
                    layer.addFilter(.blur(radius: r * 0.15))
                    let grow = 1 + 0.8 * energy
                    let spot = CGRect(x: centre.x - r * 0.40 * grow, y: ribbonY(0, (0.55, 0.30, 0.15)) - r * 0.09 * grow,
                                      width: r * 0.80 * grow, height: r * 0.18 * grow)
                    layer.fill(Path(ellipseIn: spot), with: .color(.white.opacity(0.40 + 0.45 * energy)))
                }
                light.drawLayer { layer in
                    layer.addFilter(.blur(radius: r * 0.10))
                    layer.translateBy(x: 0, y: -r * 0.045)
                    layer.stroke(warm, with: .color(Color(red: 1.0, green: 0.58, blue: 0.26).opacity(0.95 * glow)), lineWidth: r * 0.13)
                }
                light.drawLayer { layer in
                    layer.addFilter(.blur(radius: r * 0.11))
                    layer.translateBy(x: 0, y: r * 0.045)
                    layer.stroke(cool, with: .color(Color(red: 0.45, green: 0.70, blue: 1.0).opacity(0.80 * glow)), lineWidth: r * 0.12)
                }
                light.drawLayer { layer in
                    layer.addFilter(.blur(radius: r * 0.03))
                    layer.stroke(core, with: .linearGradient(
                        Gradient(stops: [.init(color: .white.opacity(0), location: 0.04),
                                         .init(color: .white.opacity(0.95 * glow), location: 0.36),
                                         .init(color: .white.opacity(0.95 * glow), location: 0.64),
                                         .init(color: .white.opacity(0), location: 0.96)]),
                        startPoint: CGPoint(x: rect.minX, y: baseY), endPoint: CGPoint(x: rect.maxX, y: baseY)),
                        lineWidth: r * 0.055)
                }

                // 4. A soft reflection in the upper half.
                inner.drawLayer { shine in
                    shine.addFilter(.blur(radius: r * 0.16))
                    let highlight = CGRect(x: centre.x - r * 0.55, y: rect.minY + r * 0.12, width: r * 1.1, height: r * 0.5)
                    shine.fill(Path(ellipseIn: highlight), with: .color(.white.opacity(0.10)))
                }

                // 5. Darkening toward the edge so it reads as a ball, not a disc.
                inner.fill(sphere, with: .radialGradient(
                    Gradient(stops: [.init(color: .clear, location: 0.70), .init(color: .black.opacity(0.42), location: 1)]),
                    center: centre, startRadius: 0, endRadius: r))
            }

            // Light pooling along the bottom edge of the glass.
            context.drawLayer { pool in
                pool.clip(to: sphere)
                pool.addFilter(.blur(radius: r * 0.07))
                pool.stroke(Path { p in
                    p.addArc(center: centre, radius: r * 0.96, startAngle: .degrees(35), endAngle: .degrees(145), clockwise: false)
                }, with: .color(.white.opacity(0.35)), lineWidth: r * 0.06)
            }

            // 6. The rim.
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.30), .white.opacity(0.08), .white.opacity(0.70)]),
                startPoint: CGPoint(x: centre.x, y: rect.minY), endPoint: CGPoint(x: centre.x, y: rect.maxY)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
