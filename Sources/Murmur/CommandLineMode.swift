import AppKit
import MurmurCore

enum CommandLineMode {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        if let dir = value("--render-screens") {
            MainActor.assumeIsolated { ScreenRenderer.render(into: URL(fileURLWithPath: dir)) }
            exit(0)
        }

        if let dir = value("--render-demo") {
            MainActor.assumeIsolated { DemoRenderer.render(into: URL(fileURLWithPath: dir)) }
            exit(0)
        }

        if let file = value("--render-icon") {
            MainActor.assumeIsolated { ScreenRenderer.renderIcon(to: URL(fileURLWithPath: file)) }
            exit(0)
        }

        guard let path = value("--transcribe") else { fail("usage: Murmur --transcribe <audio file> [--model <path>] [--language en] [--prompt text] [--cleanup light|polished] [--repeat n]") }
        let model = value("--model") ?? ModelCatalog.path(for: ModelCatalog.defaultID)
        let language = value("--language") ?? "en"
        let prompt = value("--prompt") ?? ""
        let repeats = Int(value("--repeat") ?? "1") ?? 1
        let cleanup = value("--cleanup").flatMap(CleanupLevel.init(rawValue:))

        if let margin = value("--ctx-margin").flatMap(Int.init) { WhisperEngine.contextMargin = margin }
        if let floor = value("--ctx-floor").flatMap(Int.init) { WhisperEngine.contextFloor = floor }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let samples = try AudioFileLoader.samples(from: URL(fileURLWithPath: path))
                let seconds = Double(samples.count) / 16_000
                if let cleanup { Cleanup.prewarm(level: cleanup, tone: .neutral, vocabulary: [], engine: .onDevice) }
                for run in 1...repeats {
                    let start = Date()
                    var raw = ""
                    if args.contains("--chunked") {
                        // Cut at pauses exactly as the live recorder would, and report what is left at release.
                        var detector = PauseDetector(), cuts: [Int] = [], offset = 0
                        while offset < samples.count {
                            let end = min(offset + 683, samples.count)
                            let level = samples[offset..<end].withUnsafeBufferPointer { PauseDetector.level(of: $0) }
                            if let cut = detector.feed(level: level, count: end - offset) { cuts.append(cut) }
                            offset = end
                        }
                        var parts: [String] = [], from = 0, lastTook = 0.0
                        for edge in cuts + [samples.count] where edge > from {
                            let piece = Array(samples[from..<edge])
                            from = edge
                            let context = [prompt, String((parts.last ?? "").suffix(200))].filter { !$0.isEmpty }.joined(separator: " ")
                            let pieceStart = Date()
                            let text = try await WhisperEngine.shared.transcribe(samples: piece, modelPath: model, language: language, prompt: context)
                            lastTook = Date().timeIntervalSince(pieceStart)
                            FileHandle.standardError.write(String(format: "  phrase %.1fs in %.2fs: %@\n", Double(piece.count) / 16_000, lastTook, text).data(using: .utf8)!)
                            if !text.isEmpty { parts.append(text) }
                        }
                        raw = parts.joined(separator: " ")
                        FileHandle.standardError.write(String(format: "%d phrases; work left at release: %.2fs\n", parts.count, lastTook).data(using: .utf8)!)
                    } else {
                        raw = try await WhisperEngine.shared.transcribe(samples: samples, modelPath: model, language: language, prompt: prompt)
                    }
                    let took = Date().timeIntervalSince(start)
                    var text = TextRules.process(raw, replacements: [], snippets: [])
                    FileHandle.standardError.write(String(format: "run %d: %.2fs audio in %.2fs\n", run, seconds, took).data(using: .utf8)!)
                    if run == repeats {
                        if let cleanup, !CleanupPrompt.needsModel(raw: raw, ruled: text, level: cleanup, tone: .neutral) {
                            FileHandle.standardError.write("cleanup skipped: already clean\n".data(using: .utf8)!)
                        } else if let cleanup {
                            if let problem = Cleanup.onDeviceProblem { FileHandle.standardError.write("on-device model: \(problem)\n".data(using: .utf8)!) }
                            let cleanStart = Date()
                            let result = await Cleanup.run(text, level: cleanup, tone: .neutral, vocabulary: [], engine: .onDevice)
                            FileHandle.standardError.write(String(format: "cleanup (%@): %.2fs\n", result.engine, Date().timeIntervalSince(cleanStart)).data(using: .utf8)!)
                            print("raw:     \(raw)")
                            text = result.text
                        }
                        print(text)
                    }
                }
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
            done.signal()
        }
        done.wait()
        WhisperEngine.shared.shutdown()
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(2)
    }
}
