import AVFoundation
import Foundation
import ServiceManagement
import XCTest
@testable import GuardShared
@testable import TorieChan

// In-memory stand-ins for hardware, the helper and storage, so the guard's logic runs in tests
// without touching the real keychain, data folder, Messages, speakers or sensors.

final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

final class FakeMotion: MotionSource {
    var onAccel: ((SIMD3<Double>) -> Void)?
    var onGyro: ((SIMD3<Double>) -> Void)?
    var isRunning = false
    var isHealthy = true
    var lastError: String?
    var available = true

    func start() -> Bool {
        isRunning = available
        return available
    }

    func stop() { isRunning = false }
    func emit(_ a: SIMD3<Double>) { onAccel?(a) }
}

final class FakeSystem: SystemSource {
    var onChange: ((SystemMonitor.Snapshot, SystemMonitor.Snapshot) -> Void)?
    var current = SystemMonitor.Snapshot(lidClosed: false, lidCausesSleep: false, onACPower: true, lidAngle: nil)
    func start() {}
    func stop() {}
    func refresh() -> SystemMonitor.Snapshot { current }

    func set(_ change: (inout SystemMonitor.Snapshot) -> Void) {
        let old = current
        change(&current)
        onChange?(old, current)
    }
}

final class FakeCamera: CameraSource {
    var onObservation: ((PersonTracker.Observation) -> Void)?
    var onScene: ((PersonTracker.Scene) -> Void)?
    let session = AVCaptureSession()
    var running = false
    func start(completion: @escaping (PersonTracker.CameraState) -> Void) {
        running = true
        completion(.running)
    }
    func stop(wait: Bool) { running = false }
    func pause() {}
    func resume() {}
    func setLowPower(_ on: Bool) {}
    func captureSceneReference() {}
    func snapshotJPEG() -> Data? { Data([0xFF, 0xD8, 0xFF]) }
}

final class FakeAlarm: AlarmOutput {
    private(set) var isSounding = false
    private(set) var spoken: [String] = []
    private(set) var hushCount = 0
    private(set) var chirps = 0
    func say(_ text: String, volume: Float32, completion: (() -> Void)?) {
        spoken.append(text)
        completion?()
    }
    func hush() { hushCount += 1 }
    func chirp() { chirps += 1 }
    func start() { isSounding = true }
    func stop() { isSounding = false }
}

final class FakeSleep: SleepControl {
    /// What engaging protection results in (e.g. .helperNotInstalled when the helper is missing).
    var protectionWhenEngaged: SleepGuard.LidProtection = .active
    private(set) var lidProtection: SleepGuard.LidProtection = .inactive
    var helperStatus: SMAppService.Status = .enabled
    var onLidProtectionChange: ((SleepGuard.LidProtection) -> Void)?
    private(set) var engaged = false
    private(set) var releaseCount = 0
    func engage() {
        engaged = true
        set(protectionWhenEngaged)
    }
    func release() {
        engaged = false
        releaseCount += 1
        set(.inactive)
    }
    func dropLidProtection(reason: String) { set(.failed(reason)) }
    private func set(_ value: SleepGuard.LidProtection) {
        lidProtection = value
        onLidProtectionChange?(value)
    }
}

final class InMemoryPasscodeStore: PasscodeStore {
    var data: Data?
    var locked = false
    func read(interactive: Bool) -> Result<Data?, PasscodeError> {
        locked && !interactive ? .failure(.keychain(errSecInteractionNotAllowed)) : .success(data)
    }
    func write(_ data: Data) throws { self.data = data }
}

/// Messages "sent" by the fake iMessage transport.
final class Outbox {
    var messages: [[String]] = []
    var texts: [String] { messages.map { $0[1] } }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("toriechan-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func ephemeralDefaults() -> UserDefaults {
    let name = "toriechan-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// A GuardController wired to fakes, with helpers to move time and feed the sensors.
@MainActor
final class GuardHarness {
    nonisolated static let code = "246810"
    nonisolated static let flat = SIMD3<Double>(0, 0, -0.992)

    let clock = TestClock()
    let motion = FakeMotion()
    let system = FakeSystem()
    let camera = FakeCamera()
    let alarm = FakeAlarm()
    let sleep = FakeSleep()
    let outbox = Outbox()
    let store = InMemoryPasscodeStore()
    let defaults: UserDefaults
    let directory: URL
    var audio = AudioOutput.Fingerprint(wiredOutputs: ["BuiltInSpeakerDevice"], speakerDataSource: 1)
    var cameraAllowed = true
    private(set) var guardian: GuardController!
    /// Model time since the harness started.
    private(set) var elapsed = 0.0

    init(code: String? = GuardHarness.code, acknowledged: Bool = true, alerts: Bool = true,
         directory: URL = temporaryDirectory(), defaults: UserDefaults = ephemeralDefaults()) {
        self.directory = directory
        self.defaults = defaults
        defaults.set(acknowledged, forKey: "acknowledgedResponsibility")
        let clock = self.clock
        let outbox = self.outbox
        let passcode = Passcode(store: store, defaults: defaults, now: { clock.date }, iterations: 1_000)
        if let code { try! passcode.set(code, current: nil) }
        let notifier = Notifier(defaults: defaults, transport: { outbox.messages.append($0); return nil },
                                now: { clock.date }, runsInline: true)
        if alerts {
            notifier.isEnabled = true
            notifier.handle = "+15551234567"
        }
        let env = GuardEnvironment(
            motion: motion, system: system, camera: camera, alarm: alarm, sleep: sleep, notifier: notifier,
            passcode: passcode, defaults: defaults, dataDirectory: directory, now: { clock.date },
            audioFingerprint: { [unowned self] in self.audio }, lidAngle: { nil }, motionAvailable: { true },
            cameraAllowed: { [unowned self] in self.cameraAllowed }, feedsLidAngle: false)
        guardian = GuardController(environment: env)
    }

    var phase: String { guardian.phase.name }

    /// Advance model time, feeding the accelerometer at 100 Hz and ticking the guard at 10 Hz.
    func advance(_ seconds: Double, accel: (Double) -> SIMD3<Double> = { _ in GuardHarness.flat }) {
        let steps = Int((seconds * 100).rounded())
        for i in 0..<steps {
            clock.advance(0.01)
            elapsed += 0.01
            if motion.isRunning { motion.emit(accel(Double(i) * 0.01)) }
            if i % 10 == 9 { guardian.tick() }
        }
    }

    /// Arm and run the countdown (calibrating on a still laptop) until it's watching.
    func armAndWatch(countdown: Int = 3) {
        XCTAssertNil(guardian.arm(countdown: countdown))
        advance(Double(countdown) + 0.3)
        XCTAssertEqual(phase, "armed")
    }

    func enter(_ code: String) {
        for c in code { guardian.typeDigit(c) }
        guardian.submitEntry()
    }

    /// One short knock: a 0.15 g wobble for 0.1 s, then stillness.
    nonisolated static func knock(at start: Double, g: Double = 0.15) -> (Double) -> SIMD3<Double> {
        { t in
            flat + SIMD3((t >= start && t < start + 0.1) ? g * sin((t - start) / 0.1 * .pi * 6) : 0, 0, 0)
        }
    }

    nonisolated static func tilted(_ degrees: Double) -> SIMD3<Double> {
        let r = degrees * .pi / 180
        return SIMD3(0, sin(r) * 0.992, -cos(r) * 0.992)
    }
}
