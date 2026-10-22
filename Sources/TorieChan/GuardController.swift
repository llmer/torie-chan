import AVFoundation
import AppKit
import Combine
import GuardShared
import LocalAuthentication

enum GuardPhase: Equatable {
    case disarmed
    case arming(until: Date)
    case armed
    case suspicious(reason: String, until: Date)
    case alarm(reason: String)
    /// Brief happy-eyes debrief after disarming, then back to disarmed.
    case welcomeBack(SessionSummaryBox)

    var name: String {
        switch self {
        case .disarmed, .welcomeBack: "disarmed"
        case .arming: "arming"
        case .armed: "armed"
        case .suspicious: "suspicious"
        case .alarm: "alarm"
        }
    }

    /// Guarding in earnest (sensors calibrated, triggers live).
    var isWatching: Bool {
        switch self {
        case .armed, .suspicious: true
        default: false
        }
    }

    /// Anything where the kiosk is up and the Mac must not be tampered with.
    var isGuarding: Bool {
        switch self {
        case .arming, .armed, .suspicious, .alarm: true
        default: false
        }
    }
}

/// Equatable wrapper so the phase enum stays Equatable.
struct SessionSummaryBox: Equatable {
    let summary: SessionSummary
    static func == (a: Self, b: Self) -> Bool { a.summary.startedAt == b.summary.startedAt }
}

/// The guard's brain: owns the sensors and runs the state machine
/// disarmed → arming (countdown, calibrate) → armed → suspicious (spoken warning, grace) → alarm.
@MainActor
final class GuardController: ObservableObject {
    nonisolated static let defaultCountdown = 10
    /// Agents can't arm with less than this, so the owner always has a moment to see it happen.
    nonisolated static let minAgentCountdown = 5
    nonisolated static let maxAgentCountdown = 120
    /// How long a warning lasts before we decide it was nothing (or escalate).
    nonisolated static let graceSeconds: TimeInterval = 5
    /// Lid closed or screen being lowered: a much shorter fuse.
    nonisolated static let lidGraceSeconds: TimeInterval = 1.5
    /// After any key/click/trackpad input, small motion counts for a quarter for this long.
    nonisolated static let ownerLeewaySeconds: TimeInterval = 10
    /// Input this soon after a motion warning started cancels it (the owner touched it to disarm).
    nonisolated static let ownerCancelSeconds: TimeInterval = 2.5
    /// The guard screen must get focus back within this long, or it's an escape attempt.
    nonisolated static let focusLossSeconds: TimeInterval = 2
    nonisolated static let welcomeBackSeconds: TimeInterval = 6

    private static let warnLines = ["Hey! Paws off, please.", "Um, that's not yours!", "Hands off. I'm watching!"]

    @Published private(set) var phase: GuardPhase = .disarmed
    @Published private(set) var now = Date.distantPast
    @Published private(set) var note: String?
    @Published private(set) var armedSince: Date?
    @Published private(set) var expectedBack: Date?
    @Published private(set) var peopleInView = 0
    @Published private(set) var peopleSeen = 0
    @Published private(set) var lidProtection: SleepGuard.LidProtection = .inactive
    @Published private(set) var cameraState: PersonTracker.CameraState = .off
    @Published private(set) var agentUpdate: String?
    @Published private(set) var kioskFocused = false

    @Published private(set) var keypadVisible = false
    @Published private(set) var entry = ""
    @Published private(set) var keypadMessage: String?
    @Published private(set) var authContext: LAContext?
    /// What the keypad offers besides the code, while `authContext` is live.
    @Published private(set) var biometrics: BiometricOptions?

    /// Settings "test motion" mode: live agitation without arming.
    @Published private(set) var motionTestActive = false
    @Published private(set) var agitationMeter = 0.0
    @Published private(set) var agitationPeak = 0.0
    @Published private(set) var motionTestNote: String?

    @Published var sensitivity: Sensitivity {
        didSet {
            detector.sensitivity = sensitivity
            defaults.set(sensitivity.rawValue, forKey: "sensitivity")
        }
    }

    @Published var acknowledgedResponsibility: Bool {
        didSet { defaults.set(acknowledgedResponsibility, forKey: "acknowledgedResponsibility") }
    }

    let eyes = EyesModel()
    let passcode: Passcode
    let events: EventLog
    /// Alarm photos, encrypted at rest.
    let photos: PhotoVault
    let notifier: Notifier
    /// The concrete helper manager, for Settings (install/remove). The guard itself talks to `sleep`.
    let sleepGuard: SleepGuard

    var onPhaseChange: ((GuardPhase) -> Void)?
    var onNeedsSetup: (() -> Void)?
    /// Called just before the sensors start, so Developer Tools can hand back the camera.
    var onWillArm: (() -> Void)?

    var cameraSession: AVCaptureSession { tracker.session }
    private(set) var lastSession: SessionSummary?

    private let motion: MotionSource
    private let detector = MotionDetector()
    private let system: SystemSource
    private let tracker: CameraSource
    private let alarm: AlarmOutput
    private let sleep: SleepControl
    private let lidFeed: LidAngleFeed?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let audioFingerprint: () -> AudioOutput.Fingerprint
    private let lidAngleReading: () -> Int?
    private let motionAvailable: () -> Bool
    private let cameraAllowed: () -> Bool
    private let dataDirectory: URL
    let armedMarker: ArmedMarker

    private var tickTimer: Timer?
    private var calibrationStarted = false
    private var armedOnAC = false
    private var armedLidAngle: Int?
    private var armedAudio: AudioOutput.Fingerprint?
    private var lastAudioCheck = Date.distantPast
    private var suspiciousSince = Date.distantPast
    private var suspicionFromMotion = false
    private var saidPutItDown = false
    private var warnLineIndex = 0
    private var lastUserInputAt = Date.distantPast
    private var lastKeypadActivity = Date.distantPast
    private var lastLingerSpeech = Date.distantPast
    private var lastCloseLogAt = Date.distantPast
    private var lastPersonLogAt = Date.distantPast
    private var cameraShifted = false
    private var cameraCovered = false
    private var focusLostAt: Date?
    private var overdueNotified = false
    private var session: SessionSummary?
    private var testTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    convenience init() {
        self.init(environment: .live())
    }

    init(environment env: GuardEnvironment) {
        motion = env.motion
        system = env.system
        tracker = env.camera
        alarm = env.alarm
        sleep = env.sleep
        sleepGuard = (env.sleep as? SleepGuard) ?? SleepGuard()
        notifier = env.notifier
        passcode = env.passcode
        defaults = env.defaults
        clock = env.now
        audioFingerprint = env.audioFingerprint
        lidAngleReading = env.lidAngle
        motionAvailable = env.motionAvailable
        cameraAllowed = env.cameraAllowed
        dataDirectory = env.dataDirectory
        lidFeed = env.feedsLidAngle ? LidAngleFeed() : nil
        events = EventLog(url: env.dataDirectory.appendingPathComponent("events.jsonl"))
        photos = PhotoVault(directory: env.dataDirectory, keys: env.photoKeys, now: env.now)
        armedMarker = ArmedMarker(directory: env.dataDirectory)
        sensitivity = Sensitivity(rawValue: env.defaults.string(forKey: "sensitivity") ?? "") ?? .medium
        acknowledgedResponsibility = env.defaults.bool(forKey: "acknowledgedResponsibility")
        detector.sensitivity = sensitivity
        lastSession = Self.loadLastSession(from: env.dataDirectory)
        now = env.now()

        motion.onAccel = { [weak self] a in
            guard let self else { return }
            let grab = self.detector.ingestAccel(a, at: self.clock())
            self.eyes.jolt = self.detector.jolt
            self.eyes.agitation = self.detector.agitation
            if let grab { self.handleGrab(grab) } else { self.evaluateAgitation() }
        }
        motion.onGyro = { [weak self] g in
            guard let self else { return }
            self.detector.ingestGyro(g)
            self.evaluateAgitation()
        }
        system.onChange = { [weak self] old, new in self?.handleSystemChange(old, new) }
        tracker.onObservation = { [weak self] obs in self?.handlePeople(obs) }
        tracker.onScene = { [weak self] scene in self?.handleScene(scene) }
        sleep.onLidProtectionChange = { [weak self] value in
            guard let self else { return }
            self.lidProtection = value
            if self.phase.isGuarding, value != .active, value != .inactive {
                self.events.add("lid_protection", "Lid-close protection: \(value.label)")
            }
        }
        eyes.mood = .sleepy
        observeSystem()
    }

    // MARK: - Arming

    /// Returns an error message, or nil on success.
    @discardableResult
    func arm(countdown: Int = defaultCountdown, note rawNote: String? = nil, expectedBackMinutes: Int? = nil) -> String? {
        if case .welcomeBack = phase { finishWelcomeBack() }
        guard phase == .disarmed else { return nil } // already guarding; never let a later call rewrite the note
        switch passcode.loadState {
        case .needsUnlock:
            onNeedsSetup?()
            return "Torie-chan can't read its disarm code from the keychain. The owner needs to open Settings and unlock it."
        case .notSet:
            onNeedsSetup?()
            return "No disarm code is set yet. The owner needs to open Torie-chan and set a code before it can be armed."
        case .loaded:
            break
        }
        guard acknowledgedResponsibility else {
            onNeedsSetup?()
            return "The owner needs to open Torie-chan Settings once and confirm they'll only use it where filming is allowed."
        }
        stopMotionTest()
        onWillArm?()
        photos.prepare() // now, so an alarm never has to touch the keychain

        // At least 2s so there's a quiet window to calibrate the resting pose.
        let seconds = max(2, countdown)
        note = AgentText.sanitize(rawNote, maxLength: 60)
        expectedBack = expectedBackMinutes.map { clock().addingTimeInterval(TimeInterval(max(1, min(240, $0)) * 60)) }
        overdueNotified = false
        phase = .arming(until: clock().addingTimeInterval(TimeInterval(seconds)))
        peopleSeen = 0
        agentUpdate = nil
        calibrationStarted = false
        cameraShifted = false
        cameraCovered = false
        focusLostAt = nil
        hideKeypad()
        lastUserInputAt = .distantPast
        detector.ownerLeeway = false
        session = SessionSummary(startedAt: clock())
        armedMarker.write(note: note, at: clock())

        sleep.engage()
        detector.reset()
        if !motion.start() {
            events.add("sensor", "Motion sensor unavailable: \(motion.lastError ?? "unknown")")
        }
        system.start()
        tracker.start { [weak self] state in
            guard let self else { return }
            self.cameraState = state
            switch state {
            case .running: break
            case .notAsked: self.events.add("sensor", "Camera permission not granted yet (allow it in Settings); people tracking off")
            default: self.events.add("sensor", "Camera \(state.rawValue); people tracking off")
            }
        }
        eyes.mood = .calm
        eyes.lidReferenceAngle = lidAngleReading().map(Double.init)
        lidFeed?.start { [weak self] angle in self?.eyes.lidAngle = angle }
        eyes.start()

        tickTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        events.add("arming", "Arming: \(seconds)-second countdown" + (note.map { " (\"\($0)\")" } ?? ""))
        onPhaseChange?(phase)
        return nil
    }

    /// The app was killed or crashed while armed and has been relaunched (by the helper, or by hand).
    func resumeAfterTamper() {
        guard armedMarker.exists else { return }
        events.add("tamper", "Torie-chan was force-quit or crashed while armed")
        rearmIntoAlarm("Guard app was force-quit while armed", note: armedMarker.read()?.note)
    }

    /// The root helper still had the guard armed, but the armed marker was gone: someone erased it
    /// and then killed the app, hoping it would come back disarmed.
    func helperReportedArmed() {
        guard !phase.isGuarding else { return }
        events.add("tamper", "Relaunched while the lid-close helper still had the guard armed; its armed marker had been deleted")
        rearmIntoAlarm("Guard app was killed while armed", note: nil)
    }

    private func rearmIntoAlarm(_ reason: String, note: String?) {
        if arm(countdown: 2, note: note) == nil {
            triggerAlarm(reason)
        }
    }

    private func becomeArmed() {
        detector.finishCalibration()
        let s = system.refresh()
        armedOnAC = s.onACPower
        armedLidAngle = s.lidAngle
        if let angle = s.lidAngle { eyes.lidReferenceAngle = Double(angle) }
        armedAudio = audioFingerprint()
        armedSince = clock()
        tracker.captureSceneReference()
        phase = .armed
        eyes.mood = .calm
        eyes.boing(0.8)
        alarm.chirp()
        let detail = readinessDetail()
        var message = armedOnAC ? "Armed on charger." : "Armed on battery."
        for gap in detail.gaps where gap.fix != .alerts && gap.fix != .focus { message += " \(gap.text)." }
        events.add("armed", message)
        onPhaseChange?(phase)
    }

    /// Something the guard can't cover right now, phrased for people (`text`) and for agents
    /// (`agentText`, which also says where to fix it).
    struct Gap {
        enum Fix { case lidHelper, camera, alerts, focus, none }
        let text: String
        let agentText: String
        let fix: Fix
    }

    /// What sets the alarm off right now, and what isn't covered.
    func readinessDetail() -> (protections: [String], gaps: [Gap]) {
        var protections: [String] = []
        var gaps: [Gap] = []
        if motion.isRunning || (phase == .disarmed && motionAvailable()) {
            protections.append("Being moved or picked up")
        } else {
            gaps.append(Gap(text: "No motion sensor: moving the laptop won't be noticed",
                            agentText: "no motion sensor, so moving the laptop won't be noticed", fix: .none))
        }
        let helperReady = lidProtection == .active || (lidProtection == .inactive && sleep.helperStatus == .enabled)
        if helperReady {
            protections.append("Lid closed")
        } else {
            protections.append("Lid closed (then the Mac sleeps)")
            gaps.append(Gap(text: "Closing the lid puts the Mac to sleep after the alarm",
                            agentText: "lid-close protection isn't installed (Torie-chan Settings > Sensors), so closing the lid sleeps the Mac after the alarm",
                            fix: .lidHelper))
        }
        if phase == .disarmed || phase.name == "arming" ? system.refresh().onACPower : armedOnAC {
            protections.append("Charger unplugged")
        }
        if lidAngleReading() != nil { protections.append("Screen being lowered") }
        protections.append("Screen locked, power button pressed, or shut down")
        protections.append("Headphones or adapters plugged in")
        let cameraAllowed = cameraAllowed()
        if cameraState == .running || (cameraAllowed && (phase == .disarmed || phase.name == "arming")) {
            protections.append("Camera covered")
        } else {
            gaps.append(Gap(text: cameraAllowed ? "Camera unavailable: no people tracking or alarm photo"
                                                : "Camera not allowed: no people tracking or alarm photo",
                            agentText: "camera off (\(cameraAllowed ? "unavailable" : "permission not granted in Torie-chan Settings > Sensors")), so no people tracking or alarm photo",
                            fix: .camera))
        }
        if phase.isGuarding, !kioskFocused {
            gaps.append(Gap(text: "Guard screen isn't focused: click it once so keystrokes can't reach other apps",
                            agentText: "guard screen isn't focused; click it once so keystrokes can't reach other apps", fix: .focus))
        }
        if !notifier.isConfigured {
            gaps.append(Gap(text: "iMessage alerts are off: you'll only hear the alarm if you're nearby",
                            agentText: "iMessage alerts are off (Torie-chan Settings > Phone Alerts)", fix: .alerts))
        }
        return (protections, gaps)
    }

    /// People-facing version for the arming checklist on the guard screen.
    func readinessForScreen() -> (protections: [String], gaps: [String]) {
        let d = readinessDetail()
        return (d.protections, d.gaps.map(\.text))
    }

    /// Agent-facing version (MCP status, event log): says where to fix things.
    func readiness() -> (protections: [String], gaps: [String]) {
        let d = readinessDetail()
        return (d.protections, d.gaps.map(\.agentText))
    }

    // MARK: - Ticks

    func tick() {
        now = clock()

        switch phase {
        case .arming(let until):
            if !calibrationStarted, until.timeIntervalSince(now) <= 1.5 {
                calibrationStarted = true
                detector.beginCalibration()
            }
            if now >= until { becomeArmed() }

        case .suspicious(let reason, let until):
            guard now >= until else { break }
            if let persistent = persistentThreat() {
                triggerAlarm(persistent)
            } else if detector.agitation >= MotionDetector.warnLevel / 2 {
                // Still being fiddled with: keep the warning up a bit longer, and get firmer.
                phase = .suspicious(reason: reason, until: now.addingTimeInterval(1.5))
                if !saidPutItDown {
                    saidPutItDown = true
                    alarm.say("Put it down! Now!", volume: 0.9)
                }
            } else {
                calmDown("Back to watching (was: \(reason))")
            }

        default:
            break
        }

        if phase.isWatching {
            if motion.isRunning, !motion.isHealthy {
                trigger("Motion sensor stopped reporting")
            }
            if now.timeIntervalSince(lastAudioCheck) > 0.5 {
                lastAudioCheck = now
                if let armedAudio, audioFingerprint() != armedAudio { trigger("Audio device plugged in or removed") }
            }
        }
        if phase.isGuarding, let lost = focusLostAt, now.timeIntervalSince(lost) > Self.focusLossSeconds {
            focusLostAt = nil
            triggerAlarm("Guard screen was switched away from")
        }
        if let expectedBack, phase.isGuarding, !overdueNotified, now > expectedBack.addingTimeInterval(120) {
            overdueNotified = true
            let late = Int(now.timeIntervalSince(armedSince ?? now) / 60)
            notifier.send("Still guarding", "You've been away \(late) minutes. Your laptop is fine so far.", priority: .low)
        }

        if detector.ownerLeeway, now.timeIntervalSince(lastUserInputAt) > Self.ownerLeewaySeconds {
            detector.ownerLeeway = false
        }
        detector.noiseFloorFrozen = phase.name == "suspicious" || phase.name == "alarm"
        agitationMeter = detector.agitation

        if keypadVisible, entry.isEmpty, now.timeIntervalSince(lastKeypadActivity) > 15 {
            hideKeypad()
        }
        let reduceFlashing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        eyes.angryFlash = phase.name == "alarm" && !reduceFlashing && Int(now.timeIntervalSince1970 * 3) % 2 == 0
    }

    /// Conditions that are still true after the grace period, meaning "this wasn't a bump".
    private func persistentThreat() -> String? {
        let s = system.refresh()
        if s.lidClosed { return "Lid closed" }
        if armedOnAC, !s.onACPower { return "Charger unplugged" }
        if detector.degreesFromAnchor > sensitivity.tiltDegrees {
            return "Moved from where it was left"
        }
        if let armedLidAngle, let angle = s.lidAngle, abs(angle - armedLidAngle) > 15, !detector.ownerLeeway {
            return "Screen lowered"
        }
        if let armedAudio, audioFingerprint() != armedAudio { return "Audio device plugged in" }
        if motion.isRunning, !motion.isHealthy { return "Motion sensor stopped reporting" }
        if cameraCovered, !s.lidClosed { return "Camera covered" }
        if cameraShifted, peopleInView == 0 { return "Moved (camera view shifted)" }
        return nil
    }

    private func calmDown(_ message: String) {
        phase = .armed
        eyes.mood = .calm
        suspicionFromMotion = false
        detector.settle()
        detector.rebaseline()
        events.add("calm", message)
        onPhaseChange?(phase)
    }

    // MARK: - Triggers

    private func handleGrab(_ reason: String) {
        if motionTestActive {
            motionTestNote = "Would sound the alarm: \(reason)"
            agitationPeak = max(agitationPeak, MotionDetector.alarmLevel)
            return
        }
        guard phase.isWatching else { return }
        triggerAlarm(reason)
    }

    private func evaluateAgitation() {
        let level = detector.agitation
        switch phase {
        case .armed where level >= MotionDetector.warnLevel:
            trigger(detector.reason, fromMotion: true)
        case .suspicious where level >= MotionDetector.alarmLevel:
            triggerAlarm(detector.reason)
        default:
            break
        }
    }

    private func handleSystemChange(_ old: SystemMonitor.Snapshot, _ new: SystemMonitor.Snapshot) {
        if new.lidClosed != old.lidClosed, phase.isGuarding {
            // The camera only sees black with the lid shut; pause it (and the eyes) to save power.
            if new.lidClosed {
                tracker.pause()
                eyes.stop()
            } else {
                tracker.resume()
                eyes.start()
            }
        }
        guard phase.isWatching else { return }
        if new.lidClosed, !old.lidClosed {
            if lidProtection == .active {
                trigger("Lid closed", grace: Self.lidGraceSeconds)
            } else {
                // The Mac is about to sleep; sound off while we still can.
                triggerAlarm("Lid closed (lid protection off, Mac will sleep)")
            }
        }
        if armedOnAC, old.onACPower, !new.onACPower {
            trigger("Charger unplugged")
        }
        if let armedLidAngle, let angle = new.lidAngle, abs(angle - armedLidAngle) > 15, !detector.ownerLeeway {
            detector.addExternal(0.5, reason: "Screen lowered")
            trigger("Screen lowered", grace: Self.lidGraceSeconds)
        }
    }

    private func handleScene(_ scene: PersonTracker.Scene) {
        guard phase.isWatching else { return }
        cameraCovered = scene.covered && !system.current.lidClosed
        if cameraCovered { trigger("Camera covered") }
        // Only trust a whole-view shift when nobody is filling the frame.
        cameraShifted = scene.shift > 0.04 && peopleInView == 0
        if cameraShifted {
            detector.addExternal(0.6, reason: "Camera view moved")
            evaluateAgitation()
        }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
        // Nobody needs these while their laptop is guarded, so they're all treated as theft.
        on(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.tamper("Screen was locked")
        }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.tamper("Switched to another user") }
        on(ws, NSWorkspace.willPowerOffNotification) { [weak self] in self?.tamper("Shutdown or restart attempted") }
        on(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.tamper("Mac is going to sleep") }
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in
            // Lid closing also sleeps the display; give the clamshell state a moment to update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let self, !self.system.refresh().lidClosed else { return }
                self.tamper("Display turned off (power button?)")
            }
        }
        on(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.thermalChanged() }
    }

    func tamper(_ reason: String) {
        guard phase.isGuarding else { return }
        triggerAlarm(reason)
    }

    private func thermalChanged() {
        guard phase.isGuarding else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            tracker.setLowPower(true)
            events.add("thermal", "Mac is hot; camera slowed down")
        case .critical:
            tracker.setLowPower(true)
            if system.refresh().lidClosed {
                sleep.dropLidProtection(reason: "Mac overheating with the lid closed")
                events.add("thermal", "Mac overheating with the lid closed; letting it sleep to protect it")
            }
        default:
            tracker.setLowPower(false)
        }
    }

    /// Kiosk focus bookkeeping (from KioskController).
    func kioskFocusChanged(_ focused: Bool) {
        let wasFocused = kioskFocused
        kioskFocused = focused
        if focused {
            focusLostAt = nil
        } else if wasFocused, phase.isGuarding, focusLostAt == nil {
            // Only *losing* focus is suspicious. Starting unfocused (macOS refused to activate a
            // background-launched app) is shown on screen as "click to lock the keyboard" instead.
            focusLostAt = clock()
        }
    }

    func displaysChanged() {
        guard phase.isWatching else { return }
        trigger("Display connected or changed")
    }

    /// Armed → suspicious. Escalation to the alarm comes from agitation reaching the alarm level,
    /// or from a lid/charger/pose problem still being true when the grace period ends.
    private func trigger(_ reason: String, fromMotion: Bool = false, grace: TimeInterval = graceSeconds) {
        guard phase == .armed else { return }
        let now = clock()
        suspiciousSince = now
        suspicionFromMotion = fromMotion
        saidPutItDown = false
        phase = .suspicious(reason: reason, until: now.addingTimeInterval(grace))
        eyes.mood = .angry
        eyes.boing(1.4)
        detector.joltsSuppressed = true
        let line = Self.warnLines[warnLineIndex % Self.warnLines.count]
        warnLineIndex += 1
        alarm.say(line) { [weak self] in
            self?.detector.joltsSuppressed = false
        }
        events.add("suspicious", reason)
        session?.warnings.append(reason)
        notifier.send("Someone's touching your laptop", "\(reason). I warned them.", priority: .high)
        onPhaseChange?(phase)
    }

    /// Any key, click, scroll or trackpad movement on the guard screen.
    func noteUserInput() {
        let now = clock()
        lastUserInputAt = now
        detector.ownerLeeway = true
        // The owner's own touch often registers as a bump a moment before the key press arrives.
        if case .suspicious = phase, suspicionFromMotion,
           now.timeIntervalSince(suspiciousSince) < Self.ownerCancelSeconds,
           detector.agitation < MotionDetector.alarmLevel, persistentThreat() == nil {
            alarm.hush()
            calmDown("Warning cancelled: someone started typing (likely the owner)")
        }
    }

    func triggerAlarm(_ reason: String) {
        if case .alarm = phase { return }
        guard phase.isGuarding else { return }
        phase = .alarm(reason: reason)
        eyes.mood = .alarm
        eyes.boing(2.5)
        alarm.start()
        let jpeg = tracker.snapshotJPEG()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "alarm_\(formatter.string(from: clock())).jpg"
        let photo = jpeg.flatMap { photos.save($0, named: name) }
        events.add("alarm", reason, snapshotPath: photo)
        session?.alarms.append(reason)
        if photo != nil { session?.photoTaken = true }
        // Messages needs a plain file: written from memory only if the owner opted in, and short-lived.
        let attachment = notifier.includePhoto ? jpeg.flatMap { photos.outgoingCopy(of: $0, named: name) } : nil
        if attachment != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + PhotoVault.outgoingLifetime + 5) { [photos] in photos.cleanOutgoing() }
        }
        notifier.send("ALARM", "\(reason). The siren is going." + (photo != nil && !notifier.includePhoto ? " A photo was saved on your Mac." : ""),
                      priority: .urgent, attachment: attachment)
        onPhaseChange?(phase)
    }

    // MARK: - People

    private func handlePeople(_ obs: PersonTracker.Observation) {
        guard phase.isGuarding else { return }
        let now = clock()
        let wasClose = eyes.someoneClose
        eyes.react(to: obs, playful: phase == .armed)
        if obs.arrived > 0 {
            peopleSeen += obs.arrived
            session?.peopleWalkedBy += obs.arrived
            if phase.isWatching, now.timeIntervalSince(lastPersonLogAt) > 10 {
                lastPersonLogAt = now
                events.add("person", obs.count == 1 ? "Someone walked into view" : "\(obs.count) people in view")
            }
        }
        if obs.isClose, !wasClose, phase.isWatching, now.timeIntervalSince(lastCloseLogAt) > 30 {
            lastCloseLogAt = now
            session?.gotClose += 1
            events.add("close", "Someone came right up to the laptop")
        }
        if obs.lingerStarted, phase == .armed {
            session?.lingered += 1
            if now.timeIntervalSince(lastLingerSpeech) > 60 {
                lastLingerSpeech = now
                alarm.say("I'm guarding this for my friend.", volume: 0.55)
            }
        }
        peopleInView = obs.count
    }

    // MARK: - Disarming

    func showKeypad() {
        guard phase.isGuarding else { return }
        lastKeypadActivity = clock()
        guard !keypadVisible else { return }
        keypadVisible = true
        keypadMessage = nil
        entry = ""
        startTouchID()
    }

    func hideKeypad() {
        keypadVisible = false
        entry = ""
        keypadMessage = nil
        authContext?.invalidate()
        authContext = nil
        biometrics = nil
    }

    func typeDigit(_ d: Character) {
        showKeypad()
        lastKeypadActivity = clock()
        guard entry.count < 12 else { return }
        entry.append(d)
        keypadMessage = nil
    }

    func clearEntry() {
        lastKeypadActivity = clock()
        entry = ""
    }

    func deleteDigit() {
        lastKeypadActivity = clock()
        if !entry.isEmpty { entry.removeLast() }
    }

    func submitEntry() {
        lastKeypadActivity = clock()
        guard !entry.isEmpty else { return }
        let code = entry
        entry = ""
        switch passcode.attempt(code) {
        case .success:
            disarm(method: "code")
        case .wrong(let remaining):
            session?.wrongCodes += 1
            events.add("wrong_code", "Wrong code entered")
            keypadMessage = "Wrong code (\(remaining) more \(remaining == 1 ? "try" : "tries"))"
        case .lockedOut(let until):
            session?.wrongCodes += 1
            events.add("wrong_code", "Wrong code; keypad locked for \(Int(until.timeIntervalSinceNow.rounded()))s")
            keypadMessage = "Locked for \(Int(until.timeIntervalSinceNow.rounded(.up)))s"
            // Guessing counts as tampering, even during the countdown.
            triggerAlarm("Too many wrong codes")
        }
    }

    var lockoutRemaining: Int? {
        passcode.lockedUntil.map { Int($0.timeIntervalSince(now).rounded(.up)) }
    }

    /// Disarming without the code: Touch ID, or approving on the owner's Apple Watch, which macOS only
    /// allows when the Watch is unlocked, on their wrist and right next to the Mac. Never the Mac's
    /// password: the keypad code stays the only thing anyone can type.
    struct BiometricOptions: Equatable {
        var touchID: Bool
        var watch: Bool

        var isEmpty: Bool { !touchID && !watch }

        var prompt: String {
            switch (touchID, watch) {
            case (true, true): "or use Touch ID or your Apple Watch"
            case (false, true): "or approve on your Apple Watch"
            default: "or use Touch ID"
            }
        }

        /// How a successful disarm is recorded (macOS doesn't say which one was used).
        var method: String {
            switch (touchID, watch) {
            case (true, true): "Touch ID or Apple Watch"
            case (false, true): "Apple Watch"
            default: "Touch ID"
            }
        }
    }

    nonisolated static var watchPolicy: LAPolicy {
        if #available(macOS 15, *) { .deviceOwnerAuthenticationWithCompanion } else { .deviceOwnerAuthenticationWithWatch }
    }

    nonisolated static var biometricsOrWatchPolicy: LAPolicy {
        if #available(macOS 15, *) { .deviceOwnerAuthenticationWithBiometricsOrCompanion } else { .deviceOwnerAuthenticationWithBiometricsOrWatch }
    }

    private func startTouchID() {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        let options = BiometricOptions(touchID: context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil),
                                       watch: context.canEvaluatePolicy(Self.watchPolicy, error: nil))
        guard !options.isEmpty else { return }
        authContext = context
        biometrics = options
        // The keypad embeds an LAAuthenticationView bound to this context, so no system panel
        // has to appear above our kiosk window.
        let policy: LAPolicy = options.watch ? Self.biometricsOrWatchPolicy : .deviceOwnerAuthenticationWithBiometrics
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            context.evaluatePolicy(policy, localizedReason: "disarm Torie-chan") { ok, _ in
                DispatchQueue.main.async {
                    guard let self, ok, self.authContext === context else { return }
                    self.passcode.resetFailures()
                    self.disarm(method: options.method)
                }
            }
        }
    }

    private func disarm(method: String) {
        guard phase.isGuarding else { return }
        let wasAlarm = phase.name == "alarm"
        alarm.stop()
        sleep.release()
        motion.stop()
        detector.reset()
        system.stop()
        tracker.stop(wait: false)
        lidFeed?.stop()
        eyes.lidAngle = nil
        eyes.lidReferenceAngle = nil
        tickTimer?.invalidate()
        tickTimer = nil
        hideKeypad()
        detector.ownerLeeway = false
        suspicionFromMotion = false
        armedMarker.clear()

        var summary = session ?? SessionSummary(startedAt: armedSince ?? clock())
        summary.endedAt = clock()
        summary.disarmedWith = method
        session = nil
        lastSession = summary
        Self.saveLastSession(summary, in: dataDirectory)
        events.add("disarmed", "Disarmed with \(method) " + summary.sentence)
        if wasAlarm { notifier.send("Disarmed", "Disarmed with \(method). All quiet.", priority: .low) }

        armedSince = nil
        expectedBack = nil
        note = nil
        agentUpdate = nil
        peopleInView = 0
        cameraState = .off
        lidProtection = .inactive
        eyes.lookTarget = nil
        eyes.someoneClose = false
        eyes.mood = .happy
        eyes.boing(1.2)

        // Happy eyes and a debrief for a few seconds, then back to sleep.
        phase = .welcomeBack(SessionSummaryBox(summary: summary))
        onPhaseChange?(phase)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeBackSeconds) { [weak self] in
            self?.finishWelcomeBack()
        }
    }

    func finishWelcomeBack() {
        guard case .welcomeBack = phase else { return }
        phase = .disarmed
        eyes.mood = .sleepy
        eyes.stop()
        onPhaseChange?(phase)
    }

    // MARK: - Agent updates

    func postAgentUpdate(_ raw: String?) -> String? {
        guard phase.isGuarding else { return "The guard isn't armed, so there's no screen to post to." }
        guard let message = AgentText.sanitize(raw, maxLength: 100) else { return "Empty message." }
        agentUpdate = message
        session?.agentUpdates.append(message)
        events.add("agent_update", message)
        return nil
    }

    // MARK: - Motion test (Settings)

    func startMotionTest() {
        guard phase == .disarmed, !motionTestActive else { return }
        guard motion.start() else {
            motionTestNote = "Motion sensor unavailable: \(motion.lastError ?? "unknown")"
            return
        }
        detector.reset()
        detector.beginCalibration()
        motionTestActive = true
        agitationMeter = 0
        agitationPeak = 0
        motionTestNote = "Calibrating… keep it still"
        eyes.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.motionTestActive else { return }
            self.detector.finishCalibration()
            self.motionTestNote = "Go: type, tap the table, nudge it, pick it up."
        }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agitationMeter = self.detector.agitation
                self.agitationPeak = max(self.agitationPeak, self.detector.agitation)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        testTimer = t
    }

    func stopMotionTest() {
        guard motionTestActive else { return }
        testTimer?.invalidate()
        testTimer = nil
        motion.stop()
        detector.reset()
        eyes.stop()
        motionTestActive = false
        motionTestNote = nil
    }

    // MARK: - Data

    func deleteAllData() {
        guard phase == .disarmed else { return }
        events.clear()
        photos.deleteEverything()
        try? FileManager.default.removeItem(at: Self.lastSessionURL(in: dataDirectory))
        lastSession = nil
        objectWillChange.send()
    }

    private static func lastSessionURL(in directory: URL) -> URL { directory.appendingPathComponent("last_session.json") }

    private static func loadLastSession(from directory: URL) -> SessionSummary? {
        (try? Data(contentsOf: lastSessionURL(in: directory))).flatMap { try? ControlCoding.decoder.decode(SessionSummary.self, from: $0) }
    }

    private static func saveLastSession(_ summary: SessionSummary, in directory: URL) {
        try? ControlCoding.encoder.encode(summary).write(to: lastSessionURL(in: directory), options: .atomic)
    }

    // MARK: - Control socket / MCP

    func status() -> GuardStatus {
        let s = system.refresh()
        var detail: String?
        switch phase {
        case .arming(let until): detail = "active in \(max(0, Int(until.timeIntervalSinceNow.rounded(.up))))s"
        case .suspicious(let reason, _), .alarm(let reason): detail = reason
        default: break
        }
        let r = readiness()
        return GuardStatus(state: phase.name, detail: detail, armedSince: armedSince, expectedBack: expectedBack, note: note,
                           peopleSeen: peopleSeen, peopleInView: peopleInView, lidClosed: s.lidClosed, onACPower: s.onACPower,
                           protections: r.protections, gaps: r.gaps, kioskFocused: kioskFocused, passcodeSet: passcode.isSet)
    }

    func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case .arm:
            // Clamped here too: the socket is reachable without going through bg-mcp.
            let countdown = min(Self.maxAgentCountdown, max(Self.minAgentCountdown, request.countdownSeconds ?? Self.defaultCountdown))
            if let error = arm(countdown: countdown, note: request.note, expectedBackMinutes: request.expectedBackMinutes) {
                return ControlResponse(ok: false, error: error, status: status())
            }
            return ControlResponse(ok: true, status: status())
        case .status:
            return ControlResponse(ok: true, status: status())
        case .events:
            return ControlResponse(ok: true, events: events.recent(limit: request.limit ?? 50, since: request.since))
        case .lastSession:
            if let session { return ControlResponse(ok: true, session: session) }
            if let lastSession { return ControlResponse(ok: true, session: lastSession) }
            return ControlResponse(ok: false, error: "No guard sessions yet.")
        case .postUpdate:
            if let error = postAgentUpdate(request.message) { return ControlResponse(ok: false, error: error) }
            return ControlResponse(ok: true)
        }
    }
}

/// A file that exists exactly while the guard is armed. If the app starts and finds it, the app
/// was killed mid-guard, so it comes back up in the alarm state.
struct ArmedMarker {
    struct Contents: Codable {
        var since: Date
        var note: String?
    }

    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("armed.json")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func write(note: String?, at date: Date) {
        try? ControlCoding.encoder.encode(Contents(since: date, note: note)).write(to: url, options: .atomic)
    }

    func read() -> Contents? {
        (try? Data(contentsOf: url)).flatMap { try? ControlCoding.decoder.decode(Contents.self, from: $0) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
