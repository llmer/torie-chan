import AVFoundation
import Foundation
import GuardShared
import ServiceManagement

// Everything GuardController touches outside itself: hardware, the helper, the clock, storage.
// The app runs with `.live()`; tests substitute fakes and a controllable clock.

protocol MotionSource: AnyObject {
    var onAccel: ((SIMD3<Double>) -> Void)? { get set }
    var onGyro: ((SIMD3<Double>) -> Void)? { get set }
    var isRunning: Bool { get }
    var isHealthy: Bool { get }
    var lastError: String? { get }
    @discardableResult func start() -> Bool
    func stop()
}

protocol SystemSource: AnyObject {
    var onChange: ((SystemMonitor.Snapshot, SystemMonitor.Snapshot) -> Void)? { get set }
    var current: SystemMonitor.Snapshot { get }
    func start()
    func stop()
    func refresh() -> SystemMonitor.Snapshot
}

protocol CameraSource: AnyObject {
    var onObservation: ((PersonTracker.Observation) -> Void)? { get set }
    var onScene: ((PersonTracker.Scene) -> Void)? { get set }
    var session: AVCaptureSession { get }
    func start(completion: @escaping (PersonTracker.CameraState) -> Void)
    func stop(wait: Bool)
    func pause()
    func resume()
    func setLowPower(_ on: Bool)
    func captureSceneReference()
    func snapshotJPEG() -> Data?
}

protocol AlarmOutput: AnyObject {
    var isSounding: Bool { get }
    func say(_ text: String, volume: Float32, completion: (() -> Void)?)
    func hush()
    func chirp()
    func start()
    func stop()
}

extension AlarmOutput {
    func say(_ text: String, completion: (() -> Void)? = nil) { say(text, volume: 0.8, completion: completion) }
    func say(_ text: String, volume: Float32) { say(text, volume: volume, completion: nil) }
}

protocol SleepControl: AnyObject {
    var lidProtection: SleepGuard.LidProtection { get }
    var helperStatus: SMAppService.Status { get }
    var onLidProtectionChange: ((SleepGuard.LidProtection) -> Void)? { get set }
    func engage()
    func release()
    func dropLidProtection(reason: String)
}

extension MotionSensor: MotionSource {}
extension SystemMonitor: SystemSource {}
extension PersonTracker: CameraSource {}
extension Alarm: AlarmOutput {}
extension SleepGuard: SleepControl {}

struct GuardEnvironment {
    var motion: MotionSource
    var system: SystemSource
    var camera: CameraSource
    var alarm: AlarmOutput
    var sleep: SleepControl
    var notifier: Notifier
    var passcode: Passcode
    var photoKeys: PhotoKeyStore
    var defaults: UserDefaults
    /// Event log, alarm photos, session history and the armed marker live here.
    var dataDirectory: URL
    var now: () -> Date
    var audioFingerprint: () -> AudioOutput.Fingerprint
    var lidAngle: () -> Int?
    var motionAvailable: () -> Bool
    var cameraAllowed: () -> Bool
    /// Stream the hinge angle to the eyes while armed (off in tests).
    var feedsLidAngle: Bool

    @MainActor static func live() -> GuardEnvironment {
        GuardEnvironment(
            motion: MotionSensor(), system: SystemMonitor(), camera: PersonTracker(), alarm: Alarm(),
            sleep: SleepGuard(), notifier: Notifier(), passcode: Passcode(), photoKeys: KeychainPhotoKeyStore(), defaults: .standard,
            dataDirectory: GuardIDs.supportDirectory, now: Date.init,
            audioFingerprint: { AudioOutput.fingerprint() },
            lidAngle: { LidAngleSensor.shared.angle() },
            motionAvailable: { MotionSensor.isAvailable },
            cameraAllowed: { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
            feedsLidAngle: true)
    }
}
