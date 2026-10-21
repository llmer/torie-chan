import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Siren + spoken warnings, always out of the built-in speakers.
///
/// The audio engine's output unit is pinned to the speaker device itself rather than following
/// the system default, so connecting AirPods or a headphone dongle can't reroute or stop it.
/// (It also means warnings aren't whispered into the owner's AirPods in the bathroom.)
/// If macOS reconfigures audio anyway, the engine is rebuilt; volume and mute are re-asserted
/// every 300ms while sounding.
final class Alarm {
    private(set) var isSounding = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var sirenGain: Float = 0
    private let synthesizer = AVSpeechSynthesizer()
    private var speechGeneration = 0
    private var enforceTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var savedSpeaker: (volume: Float32?, muted: Bool?)?

    private static let voice: AVSpeechSynthesisVoice? = {
        let preferred = ["com.apple.voice.premium.en-US.Zoe", "com.apple.voice.enhanced.en-US.Zoe",
                         "com.apple.voice.premium.en-US.Evan", "com.apple.voice.enhanced.en-US.Evan"]
        return preferred.lazy.compactMap { AVSpeechSynthesisVoice(identifier: $0) }.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Speak through the speakers. `completion` runs once speech ends and the chassis has settled.
    func say(_ text: String, volume: Float32 = 0.8, completion: (() -> Void)? = nil) {
        guard ensureEngine() else {
            completion?()
            return
        }
        claimSpeakers(volume: volume)
        speechGeneration += 1
        let generation = speechGeneration
        player?.stop()
        player?.play()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = 0.5
        var finished = false
        synthesizer.write(utterance) { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self, generation == self.speechGeneration, !finished else { return }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    self.schedule(pcm)
                    return
                }
                // End of utterance: fire completion after everything queued so far has played.
                finished = true
                let done = {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard generation == self.speechGeneration else { return }
                        completion?()
                    }
                }
                if let player = self.player, let format = self.playerFormat,
                   let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) {
                    marker.frameLength = 1
                    player.scheduleBuffer(marker) { DispatchQueue.main.async(execute: done) }
                } else {
                    done()
                }
            }
        }
    }

    /// Stop a spoken warning early.
    func hush() {
        hushSpeech()
        if !isSounding { releaseSpeakers() }
    }

    func chirp() {
        SystemSound.play("Ping")
    }

    func start() {
        guard !isSounding else { return }
        isSounding = true
        hushSpeech()
        claimSpeakers(volume: 1.0)
        sirenGain = 1
        if !ensureEngine() { SystemSound.play("Sosumi") }
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.isSounding else { return }
            if let speakers = AudioOutput.builtInSpeakers() {
                AudioOutput.setMuted(speakers, false)
                if (AudioOutput.volume(of: speakers) ?? 0) < 0.99 { AudioOutput.setVolume(speakers, 1.0) }
            }
            if self.engine?.isRunning != true { _ = self.ensureEngine(rebuild: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        enforceTimer = t
    }

    func stop() {
        isSounding = false
        sirenGain = 0
        enforceTimer?.invalidate()
        enforceTimer = nil
        hushSpeech()
        teardownEngine()
        releaseSpeakers()
    }

    // MARK: - Engine

    private func hushSpeech() {
        speechGeneration += 1
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
    }

    private func ensureEngine(rebuild: Bool = false) -> Bool {
        if !rebuild, let engine, engine.isRunning { return true }
        teardownEngine()
        guard let speakers = AudioOutput.builtInSpeakers() else { return false }

        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { return false }
        var device = speakers
        let rc = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard rc == noErr else { return false }

        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }

        // Siren: square-ish wave sweeping 650–1500 Hz twice a second, gated by sirenGain.
        var phase = 0.0
        var t = 0.0
        let siren = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let gain = self?.sirenGain ?? 0
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                var value: Float = 0
                if gain > 0 {
                    let sweep = 0.5 - 0.5 * cos(2 * .pi * 2 * t)
                    phase += 2 * .pi * (650 + 850 * sweep) / sampleRate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    value = Float((sin(phase) + sin(3 * phase) / 3 + sin(5 * phase) / 5) * 0.75) * gain
                    t += 1 / sampleRate
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        let player = AVAudioPlayerNode()
        engine.attach(siren)
        engine.attach(player)
        engine.connect(siren, to: engine.mainMixerNode, format: monoFormat)
        engine.connect(player, to: engine.mainMixerNode, format: monoFormat)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
        } catch {
            return false
        }
        player.play()
        self.engine = engine
        self.player = player
        self.playerFormat = monoFormat

        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isSounding else { return }
            _ = self.ensureEngine(rebuild: true)
        }
        return true
    }

    private func teardownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }

    /// Convert synthesizer output (often 22 kHz Int16) to the player's float format.
    private func schedule(_ pcm: AVAudioPCMBuffer) {
        guard let player, let target = playerFormat else { return }
        if pcm.format == target {
            player.scheduleBuffer(pcm)
            return
        }
        guard let converter = AVAudioConverter(from: pcm.format, to: target) else { return }
        let ratio = target.sampleRate / pcm.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if error == nil, out.frameLength > 0 { player.scheduleBuffer(out) }
    }

    // MARK: - Speaker volume

    private func claimSpeakers(volume: Float32) {
        guard let speakers = AudioOutput.builtInSpeakers() else { return }
        if savedSpeaker == nil {
            savedSpeaker = (AudioOutput.volume(of: speakers), AudioOutput.isMuted(speakers))
        }
        AudioOutput.setMuted(speakers, false)
        if (AudioOutput.volume(of: speakers) ?? 0) < volume - 0.01 { AudioOutput.setVolume(speakers, volume) }
    }

    private func releaseSpeakers() {
        guard let saved = savedSpeaker, let speakers = AudioOutput.builtInSpeakers() else { return }
        savedSpeaker = nil
        if let v = saved.volume { AudioOutput.setVolume(speakers, v) }
        if let m = saved.muted { AudioOutput.setMuted(speakers, m) }
    }
}

enum SystemSound {
    static func play(_ name: String) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return }
        AudioServicesPlaySystemSoundWithCompletion(id) { AudioServicesDisposeSystemSoundID(id) }
    }
}

/// Thin CoreAudio helpers.
enum AudioOutput {
    /// Wired/built-in outputs only. Bluetooth is excluded on purpose: the owner's AirPods dropping
    /// out as they walk away must not look like tampering.
    struct Fingerprint: Equatable {
        var wiredOutputs: Set<String>
        var speakerDataSource: UInt32?
    }

    static func fingerprint() -> Fingerprint {
        let ignored: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                    kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeVirtual,
                                    kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeContinuityCaptureWired,
                                    kAudioDeviceTransportTypeContinuityCaptureWireless]
        var outputs = Set<String>()
        for device in allDevices() where hasOutput(device) && !ignored.contains(transport(of: device)) {
            outputs.insert(uid(of: device) ?? String(device))
        }
        var source: UInt32?
        if let speakers = builtInSpeakers() {
            var ds: UInt32 = 0
            if get(speakers, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, &ds) == noErr { source = ds }
        }
        return Fingerprint(wiredOutputs: outputs, speakerDataSource: source)
    }

    static func builtInSpeakers() -> AudioDeviceID? {
        let devices = allDevices()
        if let byUID = devices.first(where: { uid(of: $0) == "BuiltInSpeakerDevice" }) { return byUID }
        // Fallback: a built-in output whose data source is the internal speaker ('ispk'),
        // so we never pick the headphone jack, which is also "built-in".
        let ispk: UInt32 = 0x6973_706B
        return devices.first { device in
            guard transport(of: device) == kAudioDeviceTransportTypeBuiltIn, hasOutput(device) else { return false }
            var ds: UInt32 = 0
            return get(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, &ds) == noErr && ds == ispk
        }
    }

    static func volume(of device: AudioDeviceID) -> Float32? {
        var v = Float32(0)
        return get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, &v) == noErr ? v : nil
    }

    static func setVolume(_ device: AudioDeviceID, _ volume: Float32) {
        var v = volume
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, &v)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var m = UInt32(0)
        return get(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &m) == noErr ? m != 0 : nil
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        var m = UInt32(muted ? 1 : 0)
        set(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, &m)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transport(of device: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        _ = get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &t)
        return t
    }

    private static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var addr = address(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func get<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: inout T) -> OSStatus {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
    }

    private static func set<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: inout T) {
        var addr = address(selector, scope)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
