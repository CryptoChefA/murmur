import Foundation
import CWhisper
import MurmurCore

/// whisper.cpp behind one serial queue. The model is loaded on first use and released
/// after an idle period, so nothing is held in memory while Murmur sits in the menu bar.
final class WhisperEngine: @unchecked Sendable {
    static let shared = WhisperEngine()

    enum Failure: LocalizedError {
        case modelMissing, loadFailed, decodeFailed
        var errorDescription: String? {
            switch self {
            case .modelMissing: return "No speech model installed"
            case .loadFailed: return "The speech model could not be loaded"
            case .decodeFailed: return "Transcription failed"
            }
        }
    }

    private let queue = DispatchQueue(label: "murmur.whisper", qos: .userInitiated)
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var unloadWork: DispatchWorkItem?

    /// Minutes the model stays loaded after a dictation ends. 0 releases it as soon as it does.
    var idleMinutes: Double = 0
    /// True from key-down until the dictation is over, so phrases transcribed while the speaker
    /// is still talking don't each load and free the model.
    private var inSession = false

    private(set) var isLoaded = false

    /// Extra encoder frames beyond the audio's own length (50 frames = 1 s). -1 uses the full window.
    /// 200 / 512 measured as the smallest setting with no accuracy change; tighter ones repeat text.
    static var contextMargin = 200
    static var contextFloor = 512

    private init() {
        // ggml's Metal backend otherwise starts a loop that wakes every 5 ms for the life of the
        // process to keep GPU memory wired. Murmur unloads the model when idle, so it gains
        // nothing from that; measured speed is the same without it.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        whisper_log_set({ _, _, _ in }, nil)
    }

    /// Called on key-down. Loading takes about a quarter of a second, which happens while the
    /// speaker is already talking, so the model is ready by key-up.
    func begin(modelPath: String) {
        queue.async {
            self.inSession = true
            _ = try? self.load(modelPath)
        }
    }

    /// Called whenever a dictation is over, however it ended: typed, cancelled, too short, or
    /// failed. Every path that loaded the model now leads to it being released.
    func end() {
        queue.async {
            guard self.inSession else { return }
            self.inSession = false
            if self.context != nil { self.scheduleUnload() }
        }
    }

    func transcribe(samples: [Float], modelPath: String, language: String, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(samples, modelPath, language, prompt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// For measuring: loads (or not), reports seconds taken and memory after, then frees.
    func benchLoad(modelPath: String) -> (load: Double, loadedMB: Double, freedMB: Double) {
        queue.sync {
            let start = Date()
            _ = try? self.load(modelPath)
            let took = Date().timeIntervalSince(start)
            let loaded = WhisperEngine.footprintMB()
            self.release()
            return (took, loaded, WhisperEngine.footprintMB())
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func unload() {
        queue.async { self.release() }
    }

    /// Frees the model before the process exits; Metal objects must not outlive it.
    func shutdown() {
        queue.sync { self.release() }
    }

    // MARK: - On the queue

    private func load(_ path: String) throws -> OpaquePointer {
        unloadWork?.cancel()
        if let context, loadedPath == path { return context }
        release()
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.modelMissing }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, params) else { throw Failure.loadFailed }
        context = ctx; loadedPath = path; isLoaded = true
        return ctx
    }

    private func release() {
        unloadWork?.cancel(); unloadWork = nil
        let had = context != nil
        if let context { whisper_free(context) }
        context = nil; loadedPath = nil; isLoaded = false
        // The allocator keeps freed blocks for reuse; hand them back so the memory really goes.
        if had { malloc_zone_pressure_relief(nil, 0) }
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        guard idleMinutes > 0 else { release(); return }
        // One-shot. Nothing ticks while the model is idle.
        let work = DispatchWorkItem { [weak self] in self?.release() }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + idleMinutes * 60, execute: work)
    }

    private func run(_ input: [Float], _ path: String, _ language: String, _ prompt: String) throws -> String {
        let ctx = try load(path)
        // During a dictation the session decides; outside one (command-line use) release after.
        defer { if !inSession { scheduleUnload() } }

        // Whisper needs at least a second of audio; pad short clips with silence.
        var samples = input
        let minimum = 16_000 + 1_600
        if samples.count < minimum { samples.append(contentsOf: [Float](repeating: 0, count: minimum - samples.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.translate = false
        params.detect_language = false
        params.temperature = 0
        // Whisper encodes a fixed 30 s window (1500 frames) however short the clip is. Sizing the
        // window to the audio makes short phrases proportionally quick.
        var fitted = false
        if WhisperEngine.contextMargin >= 0 {
            let frames = Int((Double(samples.count) / 16_000 * 50).rounded(.up)) + WhisperEngine.contextMargin
            let window = min(1500, max(WhisperEngine.contextFloor, frames))
            params.audio_ctx = Int32(window)
            fitted = window < 1500
        }

        var text = try decode(ctx, params, samples, language, prompt)
        // A fitted window very occasionally makes Whisper say everything twice. Redo it in full.
        if fitted, text.isEmpty || TextRules.isDoubled(text) {
            params.audio_ctx = 0
            text = try decode(ctx, params, samples, language, prompt)
        }
        return text
    }

    private func decode(_ ctx: OpaquePointer, _ base: whisper_full_params, _ samples: [Float],
                        _ language: String, _ prompt: String) throws -> String {
        var params = base

        let code: Int32 = language.withCString { lang in
            prompt.withCString { promptPtr in
                params.language = lang
                params.initial_prompt = prompt.isEmpty ? nil : promptPtr
                return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard code == 0 else { throw Failure.decodeFailed }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, i) { text += String(cString: segment) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
