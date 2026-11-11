import SwiftUI

/// A dark glass sphere with a band of light across its middle that ripples with your voice.
/// Drawn entirely in SwiftUI (no Metal shader files), so it builds with Command Line Tools.
/// The wavy-surface idea follows metasidd/Orb (MIT): https://github.com/metasidd/Orb
struct OrbView: View {
    /// 0...1 microphone level.
    var level: CGFloat
    /// Seconds, drives the ripple. Pass a fixed value for a still image.
    var time: Double
    /// Slow shimmer instead of voice ripples, for the transcribing state.
    var thinking = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            let sphere = Path(ellipseIn: rect)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let r = side / 2

            // 1. The glass body: darker toward the rim, a little lift where light enters at the top.
            context.fill(sphere, with: .radialGradient(
                Gradient(stops: [.init(color: Color(white: 0.30), location: 0),
                                 .init(color: Color(white: 0.13), location: 0.55),
                                 .init(color: Color(white: 0.03), location: 1)]),
                center: CGPoint(x: centre.x, y: centre.y - r * 0.35), startRadius: 0, endRadius: r * 1.25))

            context.drawLayer { inner in
                inner.clip(to: sphere)

                // The surface line. It sags slightly at the centre like liquid seen through a lens.
                let energy = thinking ? 0.25 : level
                let amplitude = r * (0.035 + 0.16 * energy)
                let baseY = centre.y - r * 0.02
                func surfaceY(_ x: CGFloat) -> CGFloat {
                    let u = (x - rect.minX) / side                      // 0...1 across the sphere
                    let sag = sin(u * .pi) * r * 0.20
                    let speed = thinking ? 1.2 : 3.2
                    let wave = sin(Double(u) * 7.0 + time * speed) * 0.6 + sin(Double(u) * 13.0 - time * speed * 1.7) * 0.4
                    return baseY + sag + CGFloat(wave) * amplitude * sin(u * .pi)
                }
                var surface = Path()
                surface.move(to: CGPoint(x: rect.minX, y: surfaceY(rect.minX)))
                for step in 1...48 {
                    let x = rect.minX + side * CGFloat(step) / 48
                    surface.addLine(to: CGPoint(x: x, y: surfaceY(x)))
                }

                // 2. Below the line: cool, misty liquid.
                var liquid = surface
                liquid.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                liquid.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                liquid.closeSubpath()
                inner.fill(liquid, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.72, green: 0.78, blue: 0.86).opacity(0.80),
                                      Color(red: 0.36, green: 0.40, blue: 0.47).opacity(0.50),
                                      Color(white: 0.10).opacity(0.15)]),
                    startPoint: CGPoint(x: centre.x, y: baseY), endPoint: CGPoint(x: centre.x, y: rect.maxY)))

                // A bloom at the centre of the line, where the light is strongest.
                inner.drawLayer { bloom in
                    bloom.addFilter(.blur(radius: r * 0.16))
                    let spot = CGRect(x: centre.x - r * 0.42, y: surfaceY(centre.x) - r * 0.10, width: r * 0.84, height: r * 0.20)
                    bloom.fill(Path(ellipseIn: spot), with: .color(.white.opacity(0.80 + 0.20 * energy)))
                }

                // 3. The band of light, split into warm and cool edges like light through thick glass.
                let glow = 0.75 + 0.25 * energy
                inner.drawLayer { warm in
                    warm.addFilter(.blur(radius: r * 0.10))
                    warm.translateBy(x: 0, y: -r * 0.05)
                    warm.stroke(surface, with: .color(Color(red: 1.0, green: 0.62, blue: 0.30).opacity(1.0 * glow)), lineWidth: r * 0.14)
                }
                inner.drawLayer { cool in
                    cool.addFilter(.blur(radius: r * 0.12))
                    cool.translateBy(x: 0, y: r * 0.05)
                    cool.stroke(surface, with: .color(Color(red: 0.55, green: 0.75, blue: 1.0).opacity(0.7 * glow)), lineWidth: r * 0.12)
                }
                inner.drawLayer { core in
                    core.addFilter(.blur(radius: r * 0.035))
                    // Brightest in the middle, fading to nothing at the rim.
                    core.stroke(surface, with: .linearGradient(
                        Gradient(stops: [.init(color: .white.opacity(0), location: 0.04),
                                         .init(color: .white.opacity(0.95 * glow), location: 0.38),
                                         .init(color: .white.opacity(0.95 * glow), location: 0.62),
                                         .init(color: .white.opacity(0), location: 0.96)]),
                        startPoint: CGPoint(x: rect.minX, y: baseY), endPoint: CGPoint(x: rect.maxX, y: baseY)),
                        lineWidth: r * 0.06)
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

            // 6. The rim: a hairline of light, brighter along the bottom where the liquid catches it.
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.30), .white.opacity(0.08), .white.opacity(0.70)]),
                startPoint: CGPoint(x: centre.x, y: rect.minY), endPoint: CGPoint(x: centre.x, y: rect.maxY)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
