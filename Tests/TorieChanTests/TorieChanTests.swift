import XCTest
import simd
@testable import TorieChan
@testable import GuardShared

// MARK: - Motion detection

final class MotionDetectorTests: XCTestCase {
    private let flat = SIMD3<Double>(0, 0, -0.992)

    private func tilted(_ degrees: Double) -> SIMD3<Double> {
        let r = degrees * .pi / 180
        return SIMD3(0, sin(r) * 0.992, -cos(r) * 0.992)
    }

    /// Feeds 100 Hz samples with a fixed clock; returns (peak agitation, first instant-alarm reason).
    private func run(_ seconds: Double, buzz: Double = 0, leeway: Bool = false,
                     _ signal: (Double) -> SIMD3<Double>) -> (peak: Double, grab: String?) {
        let d = MotionDetector()
        var t = Date(timeIntervalSince1970: 0)
        var i = 0
        func noise() -> SIMD3<Double> {
            i += 1
            return SIMD3(buzz * sin(Double(i) * 2.1), 0.0005 * cos(Double(i) * 1.3), 0.0005 * sin(Double(i) * 0.7))
        }
        for _ in 0..<150 { _ = d.ingestAccel(flat + noise(), at: t); t += 0.01 }
        d.beginCalibration()
        for _ in 0..<150 { _ = d.ingestAccel(flat + noise(), at: t); t += 0.01 }
        d.finishCalibration()
        d.ownerLeeway = leeway
        var peak = 0.0
        var grab: String?
        var time = 0.0
        while time < seconds {
            if let g = d.ingestAccel(signal(time) + noise(), at: t) { grab = grab ?? g }
            peak = max(peak, d.agitation)
            t += 0.01
            time += 0.01
        }
        return (peak, grab)
    }

    private func pulse(_ t: Double, at start: Double, duration: Double, g: Double) -> Double {
        (t >= start && t < start + duration) ? g * sin((t - start) / duration * .pi * 6) : 0
    }

    func testTypingIsIgnored() {
        let r = run(6) { t in self.flat + SIMD3(0, 0, t.truncatingRemainder(dividingBy: 0.125) < 0.02 ? 0.07 : 0) }
        XCTAssertLessThan(r.peak, MotionDetector.warnLevel)
        XCTAssertNil(r.grab)
    }

    func testSingleBumpOnlyJigglesTheEyes() {
        let r = run(3) { t in self.flat + SIMD3(self.pulse(t, at: 0.5, duration: 0.12, g: 0.3), 0, 0) }
        XCTAssertLessThan(r.peak, MotionDetector.warnLevel)
    }

    func testRepeatedBumpingWarns() {
        let r = run(3) { t in
            self.flat + SIMD3([0.2, 0.9, 1.6].map { self.pulse(t, at: $0, duration: 0.1, g: 0.15) }.reduce(0, +), 0, 0)
        }
        XCTAssertGreaterThanOrEqual(r.peak, MotionDetector.warnLevel)
        XCTAssertLessThan(r.peak, MotionDetector.alarmLevel)
    }

    func testGentleLiftSoundsTheAlarm() {
        let r = run(2) { t in self.tilted(min(8, t * 8)) + SIMD3(0, 0, t < 1 ? 0.08 * sin(t * 40) : 0) }
        XCTAssertGreaterThanOrEqual(r.peak, MotionDetector.alarmLevel)
    }

    func testGrabIsInstant() {
        let r = run(1) { t in self.flat + SIMD3(self.pulse(t, at: 0.3, duration: 0.05, g: 0.7), 0, 0) }
        XCTAssertEqual(r.grab, "Grabbed")
    }

    func testBuzzingTableIsLearnedButALiftStillAlarms() {
        let still = run(10, buzz: 0.08) { _ in self.flat }
        XCTAssertLessThan(still.peak, MotionDetector.warnLevel, "vibration present when armed should be background")
        let lift = run(2, buzz: 0.08) { t in self.tilted(min(8, t * 8)) + SIMD3(0, 0, 0.08 * sin(t * 40)) }
        XCTAssertGreaterThanOrEqual(lift.peak, MotionDetector.alarmLevel)
    }

    func testOwnerLeewayDampsSmallMotion() {
        let normal = run(3) { t in self.flat + SIMD3(self.pulse(t, at: 0.5, duration: 0.3, g: 0.12), 0, 0) }
        let leeway = run(3, leeway: true) { t in self.flat + SIMD3(self.pulse(t, at: 0.5, duration: 0.3, g: 0.12), 0, 0) }
        XCTAssertLessThan(leeway.peak, normal.peak * 0.5)
    }
}

// MARK: - Gaze filter

final class OneEuroFilterTests: XCTestCase {
    func testSmoothsNoiseWhileStill() {
        var f = OneEuroFilter()
        var outputs: [Double] = []
        for i in 0..<2400 { // 10 s at 240 Hz of jittery input around 0.5
            let raw = 0.5 + 0.05 * sin(Double(i) * 1.7) + 0.05 * cos(Double(i) * 2.9)
            outputs.append(f.filter(raw, dt: 1.0 / 240))
        }
        let tail = outputs.suffix(1200)
        let mean = tail.reduce(0, +) / Double(tail.count)
        let spread = tail.map { abs($0 - mean) }.max() ?? 1
        XCTAssertEqual(mean, 0.5, accuracy: 0.01)
        XCTAssertLessThan(spread, 0.01, "jitter of +/-0.1 should be smoothed to under 0.01")
    }

    func testFollowsARealMove() {
        var f = OneEuroFilter()
        _ = f.filter(0, dt: 1.0 / 240)
        var value = 0.0
        for _ in 0..<240 { value = f.filter(1, dt: 1.0 / 240) } // one second after a step
        XCTAssertGreaterThan(value, 0.9)
    }
}

// MARK: - Text and formatting

final class TextTests: XCTestCase {
    func testAgentTextIsOneShortPlainLine() {
        XCTAssertEqual(AgentText.sanitize("Back\nin 5\t\u{0007}min", maxLength: 60), "Back in 5 min")
        XCTAssertNil(AgentText.sanitize("   \n ", maxLength: 60))
        let long = AgentText.sanitize(String(repeating: "a", count: 200), maxLength: 60)!
        XCTAssertEqual(long.count, 60)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }

    func testIMessageRecipientLooksLikeAHandle() {
        XCTAssertTrue(Notifier.looksLikeHandle("+1 (555) 123-4567"))
        XCTAssertTrue(Notifier.looksLikeHandle("me@icloud.com"))
        XCTAssertFalse(Notifier.looksLikeHandle("555"))
        XCTAssertFalse(Notifier.looksLikeHandle("not an email"))
        XCTAssertFalse(Notifier.looksLikeHandle(""))
    }

    func testSessionSummaryReadsAsSentences() {
        var s = SessionSummary(startedAt: Date(timeIntervalSince1970: 0))
        s.endedAt = Date(timeIntervalSince1970: 7 * 60)
        s.peopleWalkedBy = 14
        XCTAssertEqual(s.sentence, "after 7 minutes. 14 people walked by. Nobody touched it.")
        XCTAssertEqual(s.headline, "7 min · 14 walked by · nobody touched it")
        s.alarms = ["Lifted"]
        XCTAssertTrue(s.sentence.hasSuffix("The alarm went off (lifted)."))
    }
}

// MARK: - Eyes

@MainActor
final class EyesModelTests: XCTestCase {
    func testPreviewIsDeterministic() {
        let a = EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0.5, y: 0)).currentFrame()
        let b = EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0.5, y: 0)).currentFrame()
        XCTAssertEqual(a.left.look.x, b.left.look.x, accuracy: 1e-9)
        XCTAssertEqual(a.offset.y, b.offset.y, accuracy: 1e-9)
    }

    func testMoodsSettleToTheirShapes() {
        XCTAssertLessThan(EyesModel.preview(mood: .happy).currentFrame().left.open, 0.05, "welcome back closes the eyes into arcs")
        XCTAssertGreaterThan(EyesModel.preview(mood: .alarm).currentFrame().left.open, 0.9, "the alarm keeps eye contact")
        XCTAssertGreaterThan(EyesModel.preview(mood: .calm, lookAt: CGPoint(x: 0.9, y: 0)).currentFrame().left.look.x, 0.5)
    }
}
