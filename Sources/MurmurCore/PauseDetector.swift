import Foundation

/// Finds the pauses between phrases while audio is still arriving, so a finished phrase can
/// be transcribed before the speaker has stopped. Fed one level per audio buffer.
public struct PauseDetector {
    /// A phrase must be at least this long before it is cut off (16 kHz samples).
    public var minimumPhrase = 4 * 16_000
    /// Silence this long counts as a pause.
    public var pauseLength = 8_000

    private var total = 0
    private var lastCut = 0
    private var floor: Float = 1
    private var peak: Float = 0
    private var silentSince: Int?
    private var spoke = false

    public init() {}

    /// 0...1 loudness for a buffer of samples: -50 dBFS maps to 0, -10 dBFS to 1.
    public static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }

    /// Returns the sample index to cut at when a pause has just been confirmed, otherwise nil.
    /// The cut lands in the middle of the silence, so neither side loses a word edge.
    public mutating func feed(level: Float, count: Int) -> Int? {
        let start = total
        total += count
        floor = min(floor, level)
        peak = max(peak, level)
        // Until speech clearly stands out from the room, nothing is a pause.
        guard peak - floor > 0.15 else {
            // No quiet reference yet (speech began at once). Loud audio still counts as speech.
            if level > 0.3 { spoke = true }
            return nil
        }
        let threshold = floor + 0.3 * (peak - floor)

        if level >= threshold {
            spoke = true
            silentSince = nil
            return nil
        }
        if silentSince == nil { silentSince = start }
        guard spoke, let began = silentSince, total - began >= pauseLength, began - lastCut >= minimumPhrase else { return nil }

        let cut = began + (total - began) / 2
        lastCut = cut
        spoke = false
        silentSince = nil
        return cut
    }
}
