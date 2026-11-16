import AVFoundation
import CoreAudio
import MurmurCore

/// Captures the microphone as 16 kHz mono floats, through Core Audio's own input unit.
///
/// The microphone is chosen before anything is opened. That matters for Bluetooth headsets:
/// opening a headset's microphone even for a moment switches it to call mode, which turns any
/// music playing through it to low quality. (The previous AVAudioEngine version opened the
/// system default first and switched afterwards, which was already too late.)
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

    private var unit: AudioUnit?
    private var converter: AVAudioConverter?
    private var capture: AVAudioPCMBuffer?
    private var ratio = 1.0
    private var samples: [Float] = []
    private var peak: Float = 0
    private let lock = NSLock()

    /// The microphone actually in use for the current recording.
    private(set) var deviceName = ""

    var isRecording: Bool { unit != nil }

    func start(deviceUID: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.noPermission }
        guard let device = Recorder.chooseDevice(uid: deviceUID) else { throw Failure.noInput }

        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure.noInput }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let unit = made else { throw Failure.noInput }

        func fail() -> Failure { AudioComponentInstanceDispose(unit); return .noInput }
        // Input on, output off: this unit only listens.
        var on: UInt32 = 1, off: UInt32 = 0
        let flag = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flag) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flag) == noErr else { throw fail() }
        var chosen = device
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &chosen, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw fail() }

        // The device's own rate; Murmur takes one channel of 32-bit floats at that rate.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
              hardware.mSampleRate > 0 else { throw fail() }
        guard let clientFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: clientFormat, to: AudioFormat.whisper),
              let capture = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: 8_192) else { throw fail() }
        var client = clientFormat.streamDescription.pointee
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size) == noErr else { throw fail() }

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            let recorder = Unmanaged<Recorder>.fromOpaque(refCon).takeUnretainedValue()
            recorder.pull(flags, time, bus, frames)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else { throw fail() }

        lock.lock(); samples.removeAll(keepingCapacity: true); samples.reserveCapacity(16_000 * 30); peak = 0; detector = PauseDetector(); lock.unlock()
        self.converter = converter
        self.capture = capture
        self.ratio = 16_000 / hardware.mSampleRate
        self.deviceName = AudioDevices.name(of: device) ?? ""
        self.unit = unit
        guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
            self.unit = nil
            AudioUnitUninitialize(unit)
            throw fail()
        }
    }

    /// Stops and returns what was captured, plus the loudest level seen (0...1).
    func stop() -> (samples: [Float], peak: Float) {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        converter = nil
        capture = nil
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

    /// The microphone to open: the one picked in Settings if it is connected, otherwise the
    /// system default, except that a Bluetooth headset is passed over for the Mac's own
    /// microphone when that setting is on.
    static func chooseDevice(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty, let picked = AudioDevices.id(forUID: uid) { return picked }
        guard let fallback = AudioDevices.defaultInput else { return AudioDevices.builtInInput }
        if Prefs.defaults.bool(forKey: Prefs.Key.avoidBluetoothMic), AudioDevices.isBluetooth(fallback),
           let builtIn = AudioDevices.builtInInput { return builtIn }
        return fallback
    }

    // MARK: - Audio thread

    private func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                      _ bus: UInt32, _ frames: UInt32) {
        guard let unit, let capture, frames <= capture.frameCapacity else { return }
        capture.frameLength = frames
        let list = capture.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * 4
        guard AudioUnitRender(unit, flags, time, bus, frames, list) == noErr else { return }
        consume(capture)
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
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

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    static var defaultInput: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let kind = transport(id)
        return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
    }

    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }

    static var defaultInputIsBluetooth: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return false }
        let kind = transport(id)
        return kind == kAudioDeviceTransportTypeBluetooth || kind == kAudioDeviceTransportTypeBluetoothLE
    }

    static var builtInInput: AudioDeviceID? {
        inputs().first { transport($0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
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
