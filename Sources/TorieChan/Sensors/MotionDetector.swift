import Foundation
import simd

enum Sensitivity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    // Resting noise on an M3 Pro is ~0.002g (p99), so even "high" leaves a wide margin;
    // these are tuned against handling, not sensor noise.

    /// High-pass acceleration (g) above which motion starts adding agitation.
    var bumpG: Double {
        switch self { case .low: 0.10; case .medium: 0.06; case .high: 0.035 }
    }
    /// Single-sample jolt (g) that means "someone grabbed it": alarm immediately.
    var grabG: Double {
        switch self { case .low: 0.8; case .medium: 0.6; case .high: 0.4 }
    }
    /// Degrees of tilt from the armed resting pose that start adding agitation.
    var tiltDegrees: Double {
        switch self { case .low: 8; case .medium: 5; case .high: 3 }
    }
    /// Tilt that can only mean it's been lifted: alarm immediately.
    var liftDegrees: Double {
        switch self { case .low: 25; case .medium: 18; case .high: 12 }
    }
    /// Gyro deviation (raw units; resting noise p99 ≈ 0.26) that starts adding agitation.
    var gyroRate: Double {
        switch self { case .low: 3.0; case .medium: 2.0; case .high: 1.2 }
    }
}

/// Turns raw IMU samples into an *agitation* score relative to a calibrated resting pose.
///
/// Every sample over a threshold adds a little (capped per sample), and the score decays
/// with a ~2s time constant. A single bump only jiggles the eyes; a sustained bump earns a
/// warning; continued handling (being picked up, carried, slid along) reaches the alarm.
final class MotionDetector {
    static let warnLevel = 1.0
    static let alarmLevel = 3.0
    private static let decaySeconds = 2.0
    private static let maxPerSample = 0.15

    var sensitivity: Sensitivity = .medium
    /// Owner is interacting (typing the code, touching the trackpad): small motion counts for a quarter.
    var ownerLeeway = false
    /// Our own speaker is talking; chassis vibration looks like bumps.
    var joltsSuppressed = false
    /// Stop learning the background noise level (while suspicious, so a thief can't "teach" it).
    var noiseFloorFrozen = false

    /// Slow average of high-pass motion while calm: a vibrating table (espresso machine, a
    /// neighbour typing) raises the bump bar instead of slowly filling the agitation score.
    private(set) var noiseFloor = 0.0

    private(set) var agitation = 0.0
    /// What contributed most recently, for the warning/alarm message.
    private(set) var reason = "Moved"
    /// Most recent high-pass acceleration, for googly-eye jiggle.
    private(set) var jolt = SIMD3<Double>(repeating: 0)

    private var fastGravity: SIMD3<Double>?
    private var slowGravity: SIMD3<Double>?
    private var restingGravity: SIMD3<Double>?
    /// The pose when armed. Rebaselining after a false alarm may never drift far from it,
    /// otherwise a patient thief could ratchet the laptop away a few degrees at a time.
    private var anchorGravity: SIMD3<Double>?
    private var lastSampleAt: Date?

    private var gyroBias = SIMD3<Double>(repeating: 0)
    private var gyroCalibration: [SIMD3<Double>] = []
    private var calibrationNoise: [Double] = []
    private var calibrating = false

    var isCalibrated: Bool { restingGravity != nil && !calibrating }

    func beginCalibration() {
        calibrating = true
        gyroCalibration.removeAll()
        calibrationNoise.removeAll()
        restingGravity = nil
        agitation = 0
    }

    func finishCalibration() {
        calibrating = false
        restingGravity = fastGravity
        anchorGravity = fastGravity
        // Vibration that's already there when armed (a buzzing table) sets the starting floor.
        if !calibrationNoise.isEmpty {
            let rms = (calibrationNoise.map { $0 * $0 }.reduce(0, +) / Double(calibrationNoise.count)).squareRoot()
            noiseFloor = min(rms, 0.05)
        }
        if gyroCalibration.count > 10 {
            gyroBias = gyroCalibration.reduce(SIMD3<Double>(repeating: 0), +) / Double(gyroCalibration.count)
        }
        agitation = 0
    }

    /// Accept the current pose as the new resting pose (after a false alarm nudged the laptop).
    func rebaseline() {
        guard let fast = fastGravity, let anchor = anchorGravity else { return }
        if angleDegrees(fast, anchor) <= sensitivity.tiltDegrees { restingGravity = fast }
    }

    /// How far the laptop now sits from where it was when armed.
    var degreesFromAnchor: Double {
        guard let fast = fastGravity, let anchor = anchorGravity else { return 0 }
        return angleDegrees(fast, anchor)
    }

    /// Forget accumulated agitation (owner cancelled a warning).
    func settle() {
        agitation = 0
    }

    func reset() {
        calibrating = false
        restingGravity = nil
        anchorGravity = nil
        fastGravity = nil
        slowGravity = nil
        lastSampleAt = nil
        agitation = 0
        noiseFloor = 0
        noiseFloorFrozen = false
    }

    /// Returns a reason if this sample alone is proof of theft (grabbed or lifted).
    func ingestAccel(_ a: SIMD3<Double>, at time: Date = Date()) -> String? {
        let fast = fastGravity.map { $0 + (a - $0) * 0.05 } ?? a // ~0.2s
        let slow = slowGravity.map { $0 + (a - $0) * 0.005 } ?? a // ~2s
        fastGravity = fast
        slowGravity = slow
        jolt = a - slow
        decay(at: time)

        let hp = simd_length(a - slow)
        if calibrating { calibrationNoise.append(hp) }
        guard let rest = restingGravity, !calibrating else { return nil }

        let tilt = angleDegrees(fast, rest)
        if !noiseFloorFrozen, agitation < 0.2 {
            noiseFloor += (min(hp, 0.05) - noiseFloor) * 0.0005 // ~20s at 100 Hz, capped so a bump barely moves it
        }
        let grabG = ownerLeeway ? sensitivity.grabG * 1.5 : sensitivity.grabG
        if hp > grabG { return "Grabbed" }
        if tilt > sensitivity.liftDegrees { return "Lifted" }

        let bumpG = max(sensitivity.bumpG, noiseFloor * 4)
        var hpExcess = max(0, hp - bumpG) / bumpG
        if joltsSuppressed { hpExcess *= 0.2 }
        let tiltExcess = max(0, tilt - sensitivity.tiltDegrees) / sensitivity.tiltDegrees
        if tiltExcess > 0 {
            reason = "Tilted"
        } else if hpExcess > 0 {
            reason = "Bumped"
        }
        add(hpExcess + 2 * tiltExcess)
        return nil
    }

    func ingestGyro(_ g: SIMD3<Double>) {
        if calibrating {
            gyroCalibration.append(g)
            return
        }
        guard restingGravity != nil else { return }
        let rate = simd_length(g - gyroBias)
        // Track bias drift while things are quiet.
        if agitation < 0.1, rate < sensitivity.gyroRate * 0.5 {
            gyroBias += (g - gyroBias) * 0.001
        }
        let excess = max(0, rate - sensitivity.gyroRate) / sensitivity.gyroRate
        if excess > 0 { reason = "Rotated" }
        add(excess * 0.6)
    }

    /// Evidence from other sensors (camera scene shift, lid angle). Not subject to owner leeway.
    func addExternal(_ amount: Double, reason: String) {
        guard isCalibrated else { return }
        agitation += amount
        self.reason = reason
    }

    private func add(_ excess: Double) {
        guard excess > 0 else { return }
        var amount = min(excess, 1) * Self.maxPerSample
        if ownerLeeway { amount *= 0.25 }
        agitation += amount
    }

    private func decay(at now: Date) {
        if let last = lastSampleAt {
            let dt = min(0.5, now.timeIntervalSince(last))
            agitation *= exp(-dt / Self.decaySeconds)
        }
        lastSampleAt = now
    }

    private func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0.1, lb > 0.1 else { return 0 }
        let c = max(-1, min(1, simd_dot(a, b) / (la * lb)))
        return acos(c) * 180 / .pi
    }
}
