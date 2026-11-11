import AVFoundation

enum AudioFormat {
    /// What Whisper wants: 16 kHz, mono, 32-bit float.
    static let whisper = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
}

enum AudioFileLoader {
    /// Reads any audio file Core Audio understands and returns 16 kHz mono samples.
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: source, to: AudioFormat.whisper) else { return [] }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / source.sampleRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioFormat.whisper, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
