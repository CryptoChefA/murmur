import Foundation

struct SpeechModel: Identifiable, Equatable {
    let id: String
    let name: String
    let file: String
    let megabytes: Int
    let blurb: String
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
    var englishOnly: Bool { file.contains(".en") }
}

enum ModelCatalog {
    static let defaultID = "large-v3-turbo-q5"

    static let all: [SpeechModel] = [
        SpeechModel(id: "large-v3-turbo-q5", name: "Large v3 Turbo", file: "ggml-large-v3-turbo-q5_0.bin", megabytes: 574,
                    blurb: "Recommended. Top accuracy in 99 languages, compressed to a third of the size."),
        SpeechModel(id: "large-v3-turbo", name: "Large v3 Turbo (full precision)", file: "ggml-large-v3-turbo.bin", megabytes: 1620,
                    blurb: "The uncompressed model. Marginally better on hard audio, three times the memory."),
        SpeechModel(id: "small-q5", name: "Small", file: "ggml-small-q5_1.bin", megabytes: 190,
                    blurb: "Lighter and quicker, multilingual. Fine for clear speech."),
        SpeechModel(id: "small.en-q5", name: "Small (English)", file: "ggml-small.en-q5_1.bin", megabytes: 190,
                    blurb: "Lighter and quicker, English only."),
        SpeechModel(id: "base.en-q5", name: "Base (English)", file: "ggml-base.en-q5_1.bin", megabytes: 60,
                    blurb: "Smallest. For older Macs or very low memory."),
    ]

    static var directory: URL {
        Paths.support.appendingPathComponent("Models", isDirectory: true)
    }

    static func model(_ id: String) -> SpeechModel {
        all.first { $0.id == id } ?? all[0]
    }

    static func path(for id: String) -> String {
        directory.appendingPathComponent(model(id).file).path
    }

    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: id))
    }
}

enum Paths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
