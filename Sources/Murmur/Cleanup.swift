import Foundation
import Security
import MurmurCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The language-model pass. Every failure path returns the text it was given, so a
/// dictation is never lost to a slow or unavailable model.
enum Cleanup {
    struct Result {
        var text: String
        /// "none", "on-device", "anthropic", "openai", "groq"
        var engine: String
    }

    struct Unavailable: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    static func run(_ text: String, level: CleanupLevel, tone: Tone, vocabulary: [String],
                    engine: CleanupEngine, timeout: Double = 8) async -> Result {
        // Nothing for a model to improve in one or two words.
        guard level != .off, tone != .verbatim, TextRules.wordCount(text) >= 3 else {
            return Result(text: text, engine: "none")
        }
        let instructions = CleanupPrompt.instructions(level: level, tone: tone, vocabulary: vocabulary)
        let message = CleanupPrompt.userMessage(text)

        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    switch engine {
                    case .onDevice: return try await onDevice(instructions, message)
                    default: return try await cloud(engine, instructions, message)
                    }
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let answer, let cleaned = CleanupPrompt.accept(original: text, cleaned: answer) else {
            return Result(text: text, engine: "none")
        }
        return Result(text: cleaned, engine: engine == .onDevice ? "on-device" : engine.rawValue)
    }

    // MARK: - Apple's on-device model

    /// nil when the on-device model can be used, otherwise why not.
    static var onDeviceProblem: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings."
                case .modelNotReady: return "macOS is still downloading its language model."
                @unknown default: return "The on-device model isn't available right now."
                }
            }
        }
        #endif
        return "Needs macOS 26 or later."
    }

    // A session made ready while the user is still speaking, so cleanup starts warm.
    private static let warmLock = NSLock()
    private static var warm: (instructions: String, session: Any)?

    private static func takeWarm(_ instructions: String) -> Any? {
        warmLock.lock(); defer { warmLock.unlock() }
        guard let current = warm, current.instructions == instructions else { return nil }
        warm = nil
        return current.session
    }

    /// Called on key-down. Loads the on-device model in the background.
    static func prewarm(level: CleanupLevel, tone: Tone, vocabulary: [String], engine: CleanupEngine) {
        guard engine == .onDevice, level != .off, tone != .verbatim else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            let instructions = CleanupPrompt.instructions(level: level, tone: tone, vocabulary: vocabulary)
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            warmLock.lock(); warm = (instructions, session); warmLock.unlock()
        }
        #endif
    }

    private static func onDevice(_ instructions: String, _ message: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw Unavailable(reason: onDeviceProblem ?? "unavailable")
            }
            let session = takeWarm(instructions) as? LanguageModelSession ?? LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: message, options: GenerationOptions(temperature: 0.1))
            return response.content
        }
        #endif
        throw Unavailable(reason: "Needs macOS 26 or later.")
    }

    // MARK: - Optional cloud engines (text only, user's own key)

    static func defaultModel(for engine: CleanupEngine) -> String {
        switch engine {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4o-mini"
        case .groq: return "llama-3.3-70b-versatile"
        case .onDevice: return ""
        }
    }

    private static func cloud(_ engine: CleanupEngine, _ instructions: String, _ message: String) async throws -> String {
        guard let key = Keychain.get(engine.rawValue), !key.isEmpty else { throw Unavailable(reason: "No API key") }
        let stored = UserDefaults.standard.string(forKey: "cloudModel.\(engine.rawValue)") ?? ""
        let model = stored.isEmpty ? defaultModel(for: engine) : stored

        var request: URLRequest
        let body: [String: Any]
        if engine == .anthropic {
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": 2048, "system": instructions,
                    "messages": [["role": "user", "content": message]]]
        } else {
            let host = engine == .groq ? "https://api.groq.com/openai/v1" : "https://api.openai.com/v1"
            request = URLRequest(url: URL(string: host + "/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "temperature": 0.1,
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": message]]]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Unavailable(reason: "The cleanup service returned an error")
        }
        if engine == .anthropic {
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }
}

/// API keys live in the login keychain, never in a file.
enum Keychain {
    private static let service = "app.murmur.cleanup-key"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
