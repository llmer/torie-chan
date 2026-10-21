import AppKit
import Combine
import Foundation
import simd

/// Torie-chan's eyes: a kawaii pair whose every parameter glides on a spring.
///
/// Nothing is random per frame and nothing is stepped by a timer: the view asks for
/// `frame(at:)` once per display refresh (120 Hz on ProMotion) and the model advances in fixed
/// 1/240 s substeps up to that time, so motion is identical at any frame rate and can be
/// rendered offscreen with `settle(_:)`.
@MainActor
final class EyesModel: ObservableObject {
    enum Mood {
        case sleepy, calm, angry, alarm, happy
    }

    /// How a nearly-closed eye is drawn.
    enum ClosedStyle {
        case lash   // blink: a soft ‿
        case happy  // ^
        case sleepy // ‿, deeper
    }

    struct EyeShape {
        var open: Double        // vertical openness, 0 = shut, 1 = normal
        var lidCut: Double      // fraction of the eye clipped away from the top
        var lidTilt: Double     // degrees; positive lowers the inner corner (angry)
        var irisScale: Double
        var pupilScale: Double
        var look: SIMD2<Double> // -1...1, x right, y down
        var scaleX: Double
        var scaleY: Double
        var closedStyle: ClosedStyle
    }

    struct Frame {
        var left: EyeShape
        var right: EyeShape
        /// Whole-face offset in eye heights (gaze parallax, breathing bob, hop, shake, tremble).
        var offset: SIMD2<Double>
        var blush: Double
        var mouthAlpha: Double
        var iconAlpha: Double
        var sparkle: Double
        var browAlpha: Double
        /// Shake reaction: eyes become > < for a moment.
        var flinch: Bool
        /// How far the closing lid has come down, 0…1. The renderer draws it as the underside of
        /// a bed descending from the top, with the eyes ducking under its edge and peering out.
        var hide: Double
        /// Sweat drop while the lid is closing on them.
        var sweat: Double
        /// "Ta-da!" sparkle burst after peeking back out: 0 = none, else progress 0…1.
        var burst: Double
        var mood: Mood
        var time: Double
    }

    @Published var mood: Mood = .calm {
        didSet { if mood != oldValue { moodChanged() } }
    }
    @Published var angryFlash = false
    @Published private(set) var isRunning = false

    var someoneClose = false
    /// Where a person is, in -1...1 (x right, y down). nil = nobody around.
    var lookTarget: CGPoint?
    /// High-pass acceleration from the IMU in g.
    var jolt = SIMD3<Double>(repeating: 0)
    /// Motion agitation score from the detector (0…4+).
    var agitation = 0.0
    private(set) var eyebrowUntil = Date.distantPast

    /// Hinge angle in degrees from the lid sensor (nil = this Mac has none).
    var lidAngle: Double? {
        didSet {
            if lidReferenceAngle == nil, let a = lidAngle, a > 60 { lidReferenceAngle = a }
            if lidClosedness() > 0.9 { wasShut = true }
        }
    }
    /// "Fully open" for this session (set when arming). Changes smaller than a few degrees are ignored.
    var lidReferenceAngle: Double?

    var reduceMotion = false

    // MARK: Springs

    private struct Spring {
        var x: Double
        var v = 0.0
        init(_ x: Double) { self.x = x }
        mutating func step(to goal: Double, omega: Double, zeta: Double = 1, dt: Double) {
            let a = omega * omega * (goal - x) - 2 * zeta * omega * v
            v += a * dt
            x += v * dt
        }
        mutating func snap(_ goal: Double) {
            x = goal
            v = 0
        }
    }

    private var open = Spring(1)
    private var lidCut = Spring(0)
    private var lidTilt = Spring(0)
    private var iris = Spring(1)
    private var pupil = Spring(1)
    private var scale = Spring(1)
    private var blush = Spring(0)
    private var mouth = Spring(0)
    private var icon = Spring(0)
    private var sparkle = Spring(0)
    private var brow = Spring(0)
    private var lookX = Spring(0)
    private var lookY = Spring(0)
    private var pop = Spring(0)           // boing / startle: + = taller, volume preserved
    private var lid = Spring(0)           // how far the lid has closed on the eyes, 0…1
    private var lidPrevious = 0.0
    private var wasShut = false
    private var peeking = false
    private var peekStart = 0.0
    private var burstStart: Double?

    // MARK: Clock & scheduling (model time, seconds)

    private var t = 0.0
    private var lastClock: Double?
    private var cached: Frame?
    private var rng = SplitMix64(seed: 0x6A09_E667)

    private var gazeFilterX = OneEuroFilter()
    private var gazeFilterY = OneEuroFilter()
    private var lastSeenTarget: SIMD2<Double>?
    private var lastSeenAt = -10.0
    private var acquiredAt = -10.0
    private var idleLook = SIMD2<Double>(0, 0)
    private var nextIdleLookAt = 1.0
    private var glanceBackAt: Double?
    private var nextAlarmDartAt = 0.0

    private var blinkStart: Double?
    private var blinkIsDouble = false
    private var nextBlinkAt = 3.0
    private var winkStart: Double?
    private var shakeStart: Double?
    private var hopStart: Double?
    private var smoothedJolt = SIMD3<Double>(repeating: 0)
    private var lastStartleAt = -10.0

    private var cursorTarget: CGPoint?
    private var cursorAt = Date.distantPast
    private var lastAccessibilityCheck = -10.0

    // MARK: Public API

    func start() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isRunning = true
    }
    func stop() { isRunning = false }

    func lookAtCursor(_ point: CGPoint) {
        cursorTarget = point
        cursorAt = Date()
    }

    /// Attention pop: a quick squash, then a springy stretch back. ~0.5 twitch, 1 full pop.
    func boing(_ amount: Double) {
        let a = min(1, max(0, amount))
        pop.x = -0.08 * a
        pop.v = 0
    }

    func blink() { startBlink(at: t, double: false) }

    func wink() {
        guard winkStart == nil, blinkStart == nil else { return }
        winkStart = t
    }

    /// A cute flinch: > < while the face does a small decaying side-to-side.
    func shake() { shakeStart = t }

    /// Peekaboo: start hidden under the lid and creep back out, as if it just opened.
    func wakeFromLidClose() {
        lid.x = 1
        lid.v = 0
        peeking = true
        peekStart = t
    }

    /// Skeptical look for a while (¬_¬ at a lingerer).
    func raiseEyebrow(for seconds: TimeInterval) {
        eyebrowUntil = Date().addingTimeInterval(seconds)
    }

    /// How the eyes respond to what the camera sees. `playful` enables the social reactions
    /// (wink, eyebrow) that only make sense while calmly watching.
    func react(to obs: PersonTracker.Observation, playful: Bool) {
        if obs.arrived > 0 { boing(0.6) }
        if playful {
            if obs.departed > 0, obs.count == 0 { wink() }
            if obs.approaching { boing(0.8) }
            if obs.lingerStarted { raiseEyebrow(for: 4) }
        }
        lookTarget = obs.lookAt
        someoneClose = obs.isClose
    }

    /// The pose at a display timestamp. Idempotent for the same timestamp, so several windows
    /// (one per display) can share one model.
    func frame(at clock: TimeInterval) -> Frame {
        if let last = lastClock {
            let dt = clock - last
            if dt > 0.5 {
                snapToTargets() // woke from sleep / window was hidden: don't replay the gap
                lastClock = clock
            } else if dt > 0 {
                advance(min(dt, 1.0 / 15))
                lastClock = clock
            }
        } else {
            lastClock = clock
        }
        if let cached, cached.time == t { return cached }
        let f = compose()
        cached = f
        return f
    }

    /// Run the model for a while without a display (tests, share card, contact sheets).
    func settle(_ seconds: Double) {
        advance(seconds)
        cached = nil
    }

    /// The current pose without advancing time (offscreen renders after `settle`).
    func currentFrame() -> Frame {
        compose()
    }

    /// A model already resting in a mood, for static renders.
    static func preview(mood: Mood, lookAt: CGPoint? = nil, close: Bool = false) -> EyesModel {
        let m = EyesModel()
        m.mood = mood
        m.lookTarget = lookAt
        m.someoneClose = close
        m.settle(1.5)
        m.blinkStart = nil
        m.nextBlinkAt = .infinity
        return m
    }

    // MARK: Targets per mood

    private struct Targets {
        var open = 1.0, lidCut = 0.0, lidTilt = 0.0, iris = 1.0, pupil = 1.0, scale = 1.0
        var blush = 0.0, mouth = 0.0, icon = 0.0, sparkle = 0.0, brow = 0.0
        var omega = 11.0
    }

    private var skeptical: Bool { mood == .calm && eyebrowUntil > Date() }

    private func targets() -> Targets {
        var g = Targets()
        switch mood {
        case .sleepy:
            g.open = 0
            g.omega = 5
        case .calm:
            if someoneClose {
                g.scale = 1.08
                g.iris = 1.05
                g.pupil = 1.2
                g.blush = 0.55
                g.sparkle = 1
            }
            if skeptical {
                g.lidCut = 0.45
                g.brow = 1
                g.omega = 9
            }
        case .angry:
            g.lidCut = 0.3
            g.lidTilt = 22
            g.iris = 0.85
            g.mouth = 1
            g.icon = 1
            g.omega = 14
        case .alarm:
            g.scale = 1.1
            g.iris = 0.7
            g.pupil = 0.75
            g.mouth = 1
            g.icon = 1
            g.omega = 20
        case .happy:
            g.open = 0
            g.blush = 0.7
            g.mouth = 1
        }
        // Agitation shrinks the iris a little (alert), never adds randomness.
        g.iris *= 1 - min(agitation, 4) / 4 * 0.2
        return g
    }

    private func moodChanged() {
        // Swap shapes behind a blink so the change reads as one smooth beat.
        if mood != .sleepy, mood != .happy { startBlink(at: t, double: false) }
        if mood == .happy { hopStart = t }
        nextAlarmDartAt = t
    }

    // MARK: Simulation

    private func advance(_ seconds: Double) {
        var remaining = seconds
        let h = 1.0 / 240
        while remaining > 1e-9 {
            let dt = min(h, remaining)
            step(dt)
            remaining -= dt
        }
    }

    private func step(_ dt: Double) {
        t += dt
        if t - lastAccessibilityCheck > 1 {
            lastAccessibilityCheck = t
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        let g = targets()
        open.step(to: g.open, omega: g.omega, dt: dt)
        lidCut.step(to: g.lidCut, omega: g.omega, dt: dt)
        lidTilt.step(to: g.lidTilt, omega: g.omega, dt: dt)
        iris.step(to: g.iris, omega: g.omega, dt: dt)
        pupil.step(to: g.pupil, omega: g.omega, dt: dt)
        scale.step(to: g.scale, omega: g.omega, dt: dt)
        blush.step(to: g.blush, omega: 8, dt: dt)
        mouth.step(to: g.mouth, omega: g.omega, dt: dt)
        icon.step(to: g.icon, omega: 12, dt: dt)
        sparkle.step(to: g.sparkle, omega: 9, dt: dt)
        brow.step(to: g.brow, omega: 12, dt: dt)
        pop.step(to: 0, omega: 20, zeta: 0.5, dt: dt)
        stepLid(dt)

        stepGaze(dt)
        stepJolt(dt)
        scheduleBlinks()
    }

    /// How long to keep looking where someone was after the camera loses them for a moment.
    private static let gazeHoldSeconds = 1.2

    private func stepGaze(_ dt: Double) {
        let cursorFresh = Date().timeIntervalSince(cursorAt) < 3
        let raw = (cursorFresh ? cursorTarget : lookTarget).map { SIMD2(Double($0.x), Double($0.y)) }

        // Coast through short detection dropouts instead of glancing away and back.
        if let raw {
            if t - lastSeenAt > Self.gazeHoldSeconds { acquiredAt = t } // someone new: a quicker first look
            lastSeenTarget = raw
            lastSeenAt = t
        }
        let tracked = t - lastSeenAt <= Self.gazeHoldSeconds ? lastSeenTarget : nil

        var goal: SIMD2<Double>
        var omega: Double
        if let tracked {
            // One Euro filter: heavy smoothing while the person is still (no jitter), lighter
            // while they move (little lag). Then one critically damped spring: no overshoot.
            goal = SIMD2(gazeFilterX.filter(tracked.x, dt: dt), gazeFilterY.filter(tracked.y, dt: dt))
            omega = t - acquiredAt < 0.35 ? 14 : 10
        } else {
            gazeFilterX.reset()
            gazeFilterY.reset()
            goal = idleGaze()
            omega = 7
        }

        switch mood {
        case .sleepy:
            goal = SIMD2(0, 0.2)
            omega = 3
        case .angry:
            omega = max(omega, 12)
        case .alarm:
            if tracked == nil {
                if t >= nextAlarmDartAt {
                    let edges: [SIMD2<Double>] = [[-0.9, 0], [0.9, 0], [-0.7, -0.5], [0.7, -0.5], [0, 0.4]]
                    idleLook = edges[Int.random(in: 0..<edges.count, using: &rng)]
                    nextAlarmDartAt = t + Double.random(in: 0.25...0.4, using: &rng)
                }
                goal = idleLook
                omega = 22
            } else {
                omega = 16
            }
        case .calm where skeptical && tracked == nil:
            goal = SIMD2(0.75, 0)
            omega = 5
        default:
            break
        }
        if peeking {
            // Coming out from under: looking around to see if the coast is clear.
            goal = SIMD2(0.8 * sin(2 * .pi * 0.7 * (t - peekStart)), -0.35)
            omega = 7
        } else if lid.x > 0.02 {
            // Hiding under the bed: peer up and out at the gap, with slow curious glances.
            goal.y += (-0.35 - goal.y) * lid.x
            if tracked == nil { goal.x += 0.4 * sin(2 * .pi * 0.22 * t) * lid.x }
        }
        if reduceMotion { omega = 40 }
        lookX.step(to: goal.x, omega: omega, dt: dt)
        lookY.step(to: goal.y, omega: omega, dt: dt)
    }

    /// 0 = lid where it was left (within a few degrees), 1 = nearly shut (~25°).
    private func lidClosedness() -> Double {
        guard let angle = lidAngle else { return 0 }
        let reference = (lidReferenceAngle ?? max(angle, 100)) - 8
        guard reference > 30 else { return 0 }
        return max(0, min(1, (reference - angle) / (reference - 25)))
    }

    private func stepLid(_ dt: Double) {
        lid.step(to: lidClosedness(), omega: 14, dt: dt)
        let rate = (lid.x - lidPrevious) / dt
        lidPrevious = lid.x

        // Opening back up from deep enough: creep out from under, peeking around, then pop up with
        // a sparkle burst. Any deliberate opening speed counts (a slow, careful open is the cutest).
        if !peeking, wasShut || lid.x > 0.55, rate < -0.2 {
            peeking = true
            peekStart = t
        }
        if peeking {
            if lid.x < 0.12 {
                peeking = false
                wasShut = false
                burstStart = t
                boing(1)
            } else if rate > 0.3, lid.x > 0.6 {
                peeking = false // closing again
            }
        }
        if let b = burstStart, t - b > 0.8 { burstStart = nil }
    }

    /// Gentle look-arounds when nobody's there: center, sideways, sometimes up, with holds.
    private func idleGaze() -> SIMD2<Double> {
        if let back = glanceBackAt, t >= back {
            glanceBackAt = nil
            idleLook = SIMD2(0, 0)
        }
        if t >= nextIdleLookAt {
            let r = Double.random(in: 0...1, using: &rng)
            if r < 0.4 {
                idleLook = SIMD2(0, 0)
            } else if r < 0.8 {
                idleLook = SIMD2(Bool.random(using: &rng) ? 0.6 : -0.6, 0.05)
            } else {
                idleLook = SIMD2(0, -0.4)
            }
            if Double.random(in: 0...1, using: &rng) < 0.25 { glanceBackAt = t + 0.6 }
            nextIdleLookAt = t + Double.random(in: 2.5...5, using: &rng)
        }
        return idleLook
    }

    private func stepJolt(_ dt: Double) {
        smoothedJolt += (jolt - smoothedJolt) * (1 - exp(-dt * log(2) / 0.03))
        // Only a real knock startles; typing and table buzz don't.
        if simd_length(smoothedJolt) > 0.08, t - lastStartleAt > 0.6, mood != .sleepy {
            lastStartleAt = t
            pop.v += 1.6 // surprised widen, one soft rebound
        }
    }

    private func scheduleBlinks() {
        if blinkStart == nil, winkStart == nil, mood != .alarm, mood != .sleepy, mood != .happy, t >= nextBlinkAt {
            startBlink(at: t, double: Double.random(in: 0...1, using: &rng) < 0.15)
        }
        if let s = blinkStart, t - s > blinkDuration { blinkStart = nil }
        if let w = winkStart, t - w > 0.35 { winkStart = nil }
        if let sh = shakeStart, t - sh > 0.45 { shakeStart = nil }
        if let hp = hopStart, t - hp > 1.2 { hopStart = nil }
    }

    private var blinkDuration: Double { blinkIsDouble ? 0.6 : 0.24 }

    private func startBlink(at time: Double, double: Bool) {
        blinkStart = time
        blinkIsDouble = double
        nextBlinkAt = time + Double.random(in: 2.5...6, using: &rng)
    }

    /// Lid closure 0…1: close in 0.07 s (ease-in), hold 0.03 s, open in 0.14 s (ease-out).
    private func blinkClosure(_ elapsed: Double) -> Double {
        func single(_ e: Double) -> Double {
            if e < 0 { return 0 }
            if e < 0.07 {
                let p = e / 0.07
                return p * p
            }
            if e < 0.10 { return 1 }
            if e < 0.24 {
                let p = (e - 0.10) / 0.14
                return pow(1 - p, 3)
            }
            return 0
        }
        return blinkIsDouble ? max(single(elapsed), single(elapsed - 0.36)) : single(elapsed)
    }

    private func snapToTargets() {
        let g = targets()
        open.snap(g.open)
        lidCut.snap(g.lidCut)
        lidTilt.snap(g.lidTilt)
        iris.snap(g.iris)
        pupil.snap(g.pupil)
        scale.snap(g.scale)
        blush.snap(g.blush)
        mouth.snap(g.mouth)
        icon.snap(g.icon)
        sparkle.snap(g.sparkle)
        brow.snap(g.brow)
        pop.snap(0)
        if wasShut, lidClosedness() < 0.9 {
            // The lid was shut while we weren't drawing (display off); come back with a peekaboo.
            wakeFromLidClose()
        } else {
            lid.snap(lidClosedness())
        }
        lidPrevious = lid.x
        blinkStart = nil
        winkStart = nil
        shakeStart = nil
        cached = nil
    }

    // MARK: Compose

    private func compose() -> Frame {
        let blinkC = blinkStart.map { blinkClosure(t - $0) } ?? 0
        let winkC: Double = winkStart.map { w in
            let e = t - w
            return e < 0.08 ? e / 0.08 : e < 0.2 ? 1 : max(0, 1 - (e - 0.2) / 0.15)
        } ?? 0

        // Breathing: slow, tiny, in phase.
        let period: Double = switch mood {
        case .sleepy: 5.5
        case .alarm: 1.6
        default: someoneClose ? 2.8 : 4.0
        }
        let amp = reduceMotion ? 0 : (mood == .alarm ? 2.0 : 1.0)
        let breath = sin(2 * .pi * t / period) * amp

        // Pop is volume-preserving: taller ⇄ wider. Under the bed they're a little cramped.
        let c = lid.x
        let sy = scale.x * (1 + pop.x) * (1 + 0.015 * breath) * (1 - 0.1 * c)
        let sx = scale.x / (1 + pop.x) * (1 - 0.008 * breath) * (1 + 0.05 * c)

        var offset = SIMD2(lookX.x * 0.09, lookY.x * 0.05) // parallax: the face leans toward the gaze
        offset.y += 0.012 * breath
        if let hp = hopStart, !reduceMotion { offset.y -= 0.03 * abs(sin(2 * .pi * 2 * (t - hp))) }
        if let sh = shakeStart, !reduceMotion {
            let e = t - sh
            offset.x += 0.06 * sin(2 * .pi * 6 * e) * exp(-e / 0.13)
        }
        if mood == .alarm, !reduceMotion {
            offset.x += 0.008 * (sin(2 * .pi * 13 * t) + 0.6 * sin(2 * .pi * 17 * t))
        }

        let closedStyle: ClosedStyle = mood == .happy ? .happy : mood == .sleepy ? .sleepy : .lash
        let look = SIMD2(lookX.x, lookY.x)

        func eye(isLeft: Bool) -> EyeShape {
            var o = open.x * (1 - blinkC)
            o *= peeking ? 0.9 : 1 - 0.2 * c // wary, but still wide enough to see out
            var style = closedStyle
            if winkStart != nil {
                // The right eye winks into a ^; the left one squints a little in sympathy.
                if isLeft {
                    o *= 1 - 0.15 * winkC
                } else {
                    o *= 1 - winkC
                    style = .happy
                }
            }
            var l = look
            if someoneClose, mood == .calm { l.x += isLeft ? 0.25 : -0.25 } // a touch inward
            // A little worried (inner corners up) while the lid closes in.
            return EyeShape(open: max(0, o), lidCut: lidCut.x + 0.05 * c, lidTilt: lidTilt.x - 10 * c, irisScale: iris.x, pupilScale: pupil.x,
                            look: l, scaleX: sx, scaleY: sy, closedStyle: style)
        }

        return Frame(left: eye(isLeft: true), right: eye(isLeft: false), offset: offset,
                     blush: blush.x, mouthAlpha: mouth.x, iconAlpha: icon.x, sparkle: sparkle.x, browAlpha: brow.x,
                     flinch: shakeStart != nil,
                     hide: lid.x,
                     sweat: mood == .sleepy || peeking ? 0 : max(0, min(1, (lid.x - 0.3) / 0.25)),
                     burst: burstStart.map { (t - $0) / 0.8 } ?? 0,
                     mood: mood, time: t)
    }
}

/// One Euro filter (Casiez et al. 2012): a low-pass whose cutoff rises with speed, so a still
/// target is smoothed hard and a moving one follows with little lag.
struct OneEuroFilter {
    var minCutoff = 0.4   // Hz: smoothing when still
    var beta = 1.0        // how fast the cutoff opens up with speed
    var derivativeCutoff = 1.0
    private var value: Double?
    private var derivative = 0.0

    mutating func filter(_ x: Double, dt: Double) -> Double {
        guard let prev = value, dt > 0 else {
            value = x
            return x
        }
        derivative += Self.alpha(derivativeCutoff, dt) * ((x - prev) / dt - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let next = prev + Self.alpha(cutoff, dt) * (x - prev)
        value = next
        return next
    }

    mutating func reset() {
        value = nil
        derivative = 0
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Tiny deterministic RNG so the eyes behave the same on every run (and in tests).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
