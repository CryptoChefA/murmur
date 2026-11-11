import SwiftUI
import MetalKit

/// The moving parts of the orb, advanced once per display frame. Keeping the state here, and
/// integrating it over real elapsed time, is what makes the motion fluid: the microphone only
/// reports about 25 levels a second, and speed changes must never make the flow jump.
final class OrbMotion {
    /// Smoothed 0...1 voice energy.
    private(set) var energy: CGFloat = 0
    /// The same energy, heavily smoothed. Liquid metal is heavy: it gathers pace over a phrase,
    /// not a syllable, so this is what stirs it. Driving the stir from `energy` made it twitch.
    private(set) var swell: CGFloat = 0
    /// How far the metal has flowed. Accumulated, so louder speech bends the pace smoothly.
    private(set) var flow: Double = 0
    /// 0 is the normal chrome, 1 is fully red: something went wrong.
    private(set) var alert: CGFloat = 0
    /// 0 while listening, 1 while transcribing, eased between.
    private(set) var calm: CGFloat = 0
    private var last: Date?

    func step(toward target: CGFloat, at date: Date, thinking: Bool, alert wantsAlert: Bool = false) {
        let dt = min(0.05, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        // The colour bleeds across rather than switching; a first frame has nothing to bleed from.
        if last == nil { alert = wantsAlert ? 1 : 0 }
        if last == nil { calm = thinking ? 1 : 0 }
        alert += ((wantsAlert ? 1 : 0) - alert) * CGFloat(1 - exp(-9 * dt))
        calm += ((thinking ? 1 : 0) - calm) * CGFloat(1 - exp(-6 * dt))
        last = date

        // While transcribing there is no voice: breathe slowly instead.
        let goal = thinking ? 0.16 + 0.06 * CGFloat(sin(date.timeIntervalSinceReferenceDate * 2.2)) : target
        // Rise with the syllable, fall away gently after it.
        let rate: Double = goal > energy ? 13 : 4
        energy += (goal - energy) * CGFloat(1 - exp(-rate * dt))

        swell += (energy - swell) * CGFloat(1 - exp(-(energy > swell ? 4.5 : 1.4) * dt))

        flow += (thinking ? 0.70 : 0.55 + 2.8 * Double(swell)) * dt
    }
}

/// The looks the orb can take. Chosen in Settings.
enum OrbStyle: String, CaseIterable, Identifiable {
    case mercury, halftone
    var id: String { rawValue }
    var label: String { self == .mercury ? "Mercury" : "Halftone" }
    static var current: OrbStyle { OrbStyle(rawValue: Prefs.defaults.string(forKey: Prefs.Key.orbStyle) ?? "") ?? .mercury }
}

/// One frame's worth of numbers for the shader.
struct OrbFrame {
    var flow: Double
    var energy: CGFloat
    var swell: CGFloat = 0
    var alert: CGFloat = 0
    var calm: CGFloat = 0
}

/// Draws the orb: liquid chrome flowing over a sphere, in the spirit of the "Mercury" voice orb
/// (voiceorbs.vercel.app). The shader is our own and is compiled from source when first shown,
/// so the project still builds with Command Line Tools and ships no compiled shader file.
final class MercuryRenderer {
    static let shared = MercuryRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [OrbStyle: MTLRenderPipelineState]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: MercuryRenderer.source, options: nil) } catch {
            FileHandle.standardError.write(Data("Orb shader: \(error)\n".utf8))
            return nil
        }
        var built: [OrbStyle: MTLRenderPipelineState] = [:]
        for (style, name) in [(OrbStyle.mercury, "orb_fragment"), (OrbStyle.halftone, "halftone_fragment")] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            built[style] = pipeline
        }
        self.device = device
        self.queue = queue
        self.pipelines = built
    }

    private func encode(_ pass: MTLRenderPassDescriptor, _ frame: OrbFrame, style: OrbStyle) -> MTLCommandBuffer? {
        guard let pipeline = pipelines[style], let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = [SIMD4<Float>(Float(frame.flow.truncatingRemainder(dividingBy: 4_000)), Float(frame.energy), Float(frame.alert), Float(frame.swell)),
                        SIMD4<Float>(Float(frame.calm), 0, 0, 0)]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    func draw(in view: MTKView, _ frame: OrbFrame, style: OrbStyle) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = encode(pass, frame, style: style) else { return }
        buffer.present(drawable)
        buffer.commit()
    }

    /// One still frame, for screenshots and for checking the look without a display.
    func image(side: Int, _ frame: OrbFrame, style: OrbStyle = .mercury) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = encode(pass, frame, style: style) else { return nil }
        if !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Varying { float4 position [[position]]; float2 uv; };

    vertex Varying orb_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Varying out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = p * 2.0 - 1.0;
        return out;
    }

    // One band of chrome: dark, a quick climb to bright silver, a long fall back through grey.
    static float chrome(float x) {
        x = fract(x);
        float rise = smoothstep(0.30, 0.38, x);
        float fall = 1.0 - smoothstep(0.82, 0.98, x);
        float body = mix(1.0, 0.34, smoothstep(0.40, 0.90, x));
        return rise * fall * body;
    }

    struct Uniforms { float4 a; float4 b; };

    fragment float4 orb_fragment(Varying in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
        float flow = U.a.x, energy = U.a.y, alert = U.a.z, swell = U.a.w;

        // The sphere swells a little with the voice.
        float2 uv = in.uv * (1.16 - 0.15 * energy);
        float r = length(uv);
        float edge = fwidth(r);
        float mask = 1.0 - smoothstep(1.0 - edge, 1.0, r);
        if (mask <= 0.0) { return float4(0.0); }
        float z = sqrt(max(0.0, 1.0 - r * r));

        // Wrap the pattern over the ball, then fold it through itself like stirred liquid.
        float2 p = uv / (0.58 + 0.42 * z) * 0.62;
        float stir = 0.42 + 0.36 * swell;
        for (int i = 1; i <= 4; i++) {
            float f = float(i);
            p.x += stir / f * sin(f * 1.7 * p.y + flow * (0.60 + 0.17 * f) + 1.7 * f);
            p.y += stir / f * cos(f * 1.4 * p.x - flow * (0.50 + 0.13 * f) + 0.6 * f);
        }
        float s = p.x * 0.66 + p.y * 0.48 + 0.07 * flow;

        // Each colour reads the band a hair apart, which leaves thin rainbow fringes on the edges.
        float spread = 0.012 + 0.028 * swell;
        float3 band = float3(chrome(s + spread), chrome(s), chrome(s - spread));

        float3 deep = mix(float3(0.030, 0.040, 0.130), float3(0.150, 0.008, 0.030), alert);
        float3 bright = mix(float3(0.930, 0.950, 1.000), float3(1.000, 0.340, 0.300), alert);
        float3 colour = deep + (bright - deep) * band;

        // Shade it as a ball: darker toward the rim, a soft highlight up and to the left.
        float3 normal = normalize(float3(uv, z));
        float shine = pow(max(0.0, dot(normal, normalize(float3(-0.45, 0.60, 0.66)))), 14.0);
        colour *= mix(0.38, 1.0, smoothstep(0.0, 0.55, z));
        colour *= 0.88 + 0.30 * energy;
        colour += shine * (0.20 + 0.30 * energy) * mix(float3(1.0), float3(1.0, 0.6, 0.55), alert);

        return float4(colour * mask, mask);
    }

    // The halftone look: dots laid out along the lines of a slowly turning globe. Each dot is as
    // big as the light falling on it, so the lit side is nearly solid and the far side thins out.
    fragment float4 halftone_fragment(Varying in [[stage_in]], constant Uniforms &U [[buffer(0)]]) {
        float flow = U.a.x, energy = U.a.y, alert = U.a.z, calm = U.b.x;
        float2 view = in.uv * (1.34 - 0.10 * energy);

        // A soft dark patch behind it, so pale dots read on any wallpaper.
        float back = (1.0 - smoothstep(0.70, 1.30, length(view))) * 0.58;

        // When something went wrong the globe breaks in two along a slanted line.
        float2 across = normalize(float2(-0.62, 0.78));
        float side = dot(view, across) >= 0.0 ? 1.0 : -1.0;
        float2 uv = view - across * side * 0.10 * alert;
        float whole = step(0.0, dot(uv, across) * side);

        float r = length(uv);
        float dots = 0.0;
        if (r < 1.0 && whole > 0.5) {
            float z = sqrt(1.0 - r * r);
            float3 n = float3(uv, z);
            // Turn it, then tip the pole toward the viewer a little.
            float spin = flow * 0.32;
            float3 p = float3(n.x * cos(spin) + n.z * sin(spin), n.y, -n.x * sin(spin) + n.z * cos(spin));
            float tip = 0.42;
            p = float3(p.x, p.y * cos(tip) - p.z * sin(tip), p.y * sin(tip) + p.z * cos(tip));

            const float rows = 15.0;
            const float pi = 3.14159265;
            float lat = asin(clamp(p.y, -1.0, 1.0));
            float v = lat / pi * rows;
            float centre = (floor(v) + 0.5) / rows * pi;
            float around = max(1.0, floor(2.0 * rows * cos(centre) + 0.5));
            float u = atan2(p.x, p.z) / (2.0 * pi) * around;
            float2 cell = float2((fract(u) - 0.5) * (2.0 * rows * cos(centre) / around), fract(v) - 0.5);
            float d = length(cell);

            float light = saturate(dot(n, normalize(float3(-0.50, 0.60, 0.62))) * 0.85 + 0.25);
            float size = 0.47 * mix(0.10, 1.0, pow(light, 1.3));
            size *= 0.78 + 0.50 * energy;                                        // louder, fuller
            size *= 1.0 - 0.30 * calm * (0.55 + 0.45 * sin(lat * 5.0 - flow * 5.0)); // a wave while thinking
            size *= 1.0 - 0.32 * alert;
            size = min(size, 0.49);
            float soft = clamp(fwidth(v) * 1.4, 0.004, 0.2);
            dots = (1.0 - smoothstep(size - soft, size + soft, d)) * smoothstep(0.0, 0.14, z);
        }
        float3 ink = mix(float3(0.93, 0.95, 1.00), float3(1.00, 0.36, 0.30), alert);
        return float4(ink * dots, dots + back * (1.0 - dots));
    }
    """
}

/// The orb on screen. It redraws every display frame while it exists and reads the voice level
/// itself, so nothing in SwiftUI has to re-render for it to move.
struct MercuryOrb: View {
    let motion: OrbMotion
    let model: PillModel
    var thinking: Bool
    var alert: Bool
    var still: Bool
    var style: OrbStyle = .mercury
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        if staticRender || MercuryRenderer.shared == nil {
            StillOrb(flow: 3.1, energy: thinking ? 0.18 : model.voice, alert: alert ? 1 : 0, calm: thinking ? 1 : 0, style: style)
        } else {
            LiveOrb(motion: motion, model: model, thinking: thinking, alert: alert, still: still, style: style)
        }
    }
}

/// A single rendered frame as an image.
struct StillOrb: View {
    var flow: Double
    var energy: CGFloat
    var alert: CGFloat
    var calm: CGFloat = 0
    var style: OrbStyle = .mercury

    var body: some View {
        GeometryReader { geo in
            let side = Int(max(geo.size.width, geo.size.height) * 2)
            let frame = OrbFrame(flow: flow, energy: energy, swell: energy, alert: alert, calm: calm)
            if let image = MercuryRenderer.shared?.image(side: max(side, 16), frame, style: style) {
                Image(decorative: image, scale: 2).resizable()
            } else {
                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(red: 0.05, green: 0.06, blue: 0.16)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LiveOrb: NSViewRepresentable {
    let motion: OrbMotion
    let model: PillModel
    var thinking: Bool
    var alert: Bool
    var still: Bool
    var style: OrbStyle

    func makeCoordinator() -> Coordinator { Coordinator(motion: motion, model: model) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MercuryRenderer.shared?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.thinking = thinking
        context.coordinator.alert = alert
        context.coordinator.style = style
        // Reduce Motion: a still orb that only changes when the state does.
        view.isPaused = still
        view.enableSetNeedsDisplay = still
        if still { view.needsDisplay = true }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let motion: OrbMotion
        let model: PillModel
        var thinking = false
        var alert = false
        var style = OrbStyle.mercury

        init(motion: OrbMotion, model: PillModel) {
            self.motion = motion
            self.model = model
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            motion.step(toward: model.voice, at: Date(), thinking: thinking, alert: alert)
            let frame = OrbFrame(flow: motion.flow, energy: motion.energy, swell: motion.swell, alert: motion.alert, calm: motion.calm)
            MercuryRenderer.shared?.draw(in: view, frame, style: style)
        }
    }
}

private struct StaticRenderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when drawing to an image file: live Metal views and system glass do not capture.
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}
