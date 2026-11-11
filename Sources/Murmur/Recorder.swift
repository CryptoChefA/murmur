import AVFoundation
import CoreAudio
import MurmurCore

/// Captures the microphone as 16 kHz mono floats. A fresh engine is created for each
/// recording and torn down afterwards, so the mic indicator is only on while dictating.
final class Recorder {
    enum Failure: LocalizedError {
        case noPermission, noInput
        var errorDescription: String? {
            switch self {
            case .noPermission: return "No microphone access"
            case .noInput: return "No microphone found"
            }
        }
    }

    /// Called on the main queue with a 0...1 level, roughly 20 times a second.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the speaker pauses, with the sample index to cut at.
    var onPause: ((Int) -> Void)?
    private var detector = PauseDetector()

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var peak: Float = 0
    private let lock = NSLock()

    var isRecording: Bool { engine != nil }

    func start(deviceUID: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.noPermission }
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if !deviceUID.isEmpty, let id = AudioDevices.id(forUID: deviceUID), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: AudioFormat.whisper) else { throw Failure.noInput }
        self.converter = converter
        lock.lock(); samples.removeAll(keepingCapacity: true); samples.reserveCapacity(16_000 * 30); peak = 0; detector = PauseDetector(); lock.unlock()

        let ratio = 16_000 / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, ratio: ratio)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops and returns what was captured, plus the loudest level seen (0...1).
    func stop() -> (samples: [Float], peak: Float) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        lock.lock(); defer { lock.unlock() }
        let result = (samples, peak)
        samples = []
        return result
    }

    /// A copy of part of the recording so far. Safe to call while recording.
    func slice(_ range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let clamped = max(0, range.lowerBound)..<min(samples.count, range.upperBound)
        return clamped.isEmpty ? [] : Array(samples[clamped])
    }

    private func consume(_ buffer: AVAudioPCMBuffer, ratio: Double) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioFormat.whisper, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))

        let level = PauseDetector.level(of: chunk)

        lock.lock()
        samples.append(contentsOf: chunk)
        peak = max(peak, level)
        let cut = detector.feed(level: level, count: chunk.count)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(level)
            if let cut { self?.onPause?(cut) }
        }
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func inputs() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [AudioDevice] = []
        for id in ids where hasInput(id) {
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { continue }
            result.append(AudioDevice(id: id, uid: uid, name: name))
        }
        return result
    }

    static func id(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
