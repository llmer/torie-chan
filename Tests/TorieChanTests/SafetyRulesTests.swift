import CoreGraphics
import XCTest
@testable import GuardShared
@testable import TorieChan

// MARK: - Disarm code

final class PasscodeTests: XCTestCase {
    private var clock = TestClock()

    private func make(store: InMemoryPasscodeStore = InMemoryPasscodeStore(), defaults: UserDefaults = ephemeralDefaults()) -> Passcode {
        let clock = self.clock
        return Passcode(store: store, defaults: defaults, now: { clock.date }, iterations: 1_000)
    }

    func testCodesAreSixToTwelveDigits() throws {
        let p = make()
        XCTAssertThrowsError(try p.set("1234", current: nil))
        XCTAssertThrowsError(try p.set("12345a", current: nil))
        XCTAssertThrowsError(try p.set(String(repeating: "1", count: 13), current: nil))
        try p.set("123456", current: nil)
        XCTAssertTrue(p.verify("123456"))
        XCTAssertFalse(p.verify("123457"))
    }

    func testChangingTheCodeNeedsTheCurrentOne() throws {
        let p = make()
        try p.set("123456", current: nil)
        XCTAssertThrowsError(try p.set("654321", current: "000000"))
        XCTAssertThrowsError(try p.set("654321", current: nil))
        try p.set("654321", current: "123456")
        XCTAssertTrue(p.verify("654321"))
    }

    func testTheCodeIsStoredHashedNotInPlainText() throws {
        let store = InMemoryPasscodeStore()
        let p = make(store: store)
        try p.set("246810", current: nil)
        let stored = String(decoding: store.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("246810"))
        XCTAssertTrue(make(store: store).verify("246810"), "a fresh instance loads it back")
    }

    func testALockedKeychainIsNeverTreatedAsNoCode() throws {
        let store = InMemoryPasscodeStore()
        try make(store: store).set("246810", current: nil)
        store.locked = true
        let p = make(store: store)
        XCTAssertEqual(p.loadState, .needsUnlock)
        XCTAssertFalse(p.isSet)
        XCTAssertThrowsError(try p.set("111111", current: nil), "must not let anyone set a new code without the old one")
    }

    func testWrongGuessesEscalateAndSurviveARelaunch() throws {
        let defaults = ephemeralDefaults()
        let store = InMemoryPasscodeStore()
        let p = make(store: store, defaults: defaults)
        try p.set("246810", current: nil)

        XCTAssertEqual(p.attempt("1"), .wrong(remainingFreeTries: 2))
        XCTAssertEqual(p.attempt("2"), .wrong(remainingFreeTries: 1))
        guard case .lockedOut(let first) = p.attempt("3") else { return XCTFail("third miss locks") }
        XCTAssertEqual(first.timeIntervalSince(clock.date), 10, accuracy: 0.01)

        let relaunched = make(store: store, defaults: defaults)
        guard case .lockedOut = relaunched.attempt("246810") else { return XCTFail("lockout survives relaunch") }

        clock.advance(10.5)
        guard case .lockedOut(let second) = relaunched.attempt("4") else { return XCTFail("still escalating") }
        XCTAssertEqual(second.timeIntervalSince(clock.date), 20, accuracy: 0.01)

        clock.advance(20.5)
        XCTAssertEqual(relaunched.attempt("246810"), .success)
        XCTAssertNil(relaunched.lockedUntil)
        XCTAssertEqual(relaunched.attempt("5"), .wrong(remainingFreeTries: 2), "success resets the count")
    }

    func testLockoutsAreCappedAtFifteenMinutes() throws {
        let p = make()
        try p.set("246810", current: nil)
        var last: Date?
        for _ in 0..<20 {
            if case .lockedOut(let until) = p.attempt("0") { last = until }
            clock.advance(1_000)
        }
        clock.advance(-1_000)
        XCTAssertLessThanOrEqual(last!.timeIntervalSince(clock.date), 900.01)
    }
}

// MARK: - Helper lease (root helper's fail-safes)

final class HelperLeaseTests: XCTestCase {
    private let clock = TestClock()
    private var sleepDisabled = false
    private var relaunches = 0

    private func makeLease() -> HelperLease {
        HelperLease(actions: .init(setSleepDisabled: { [unowned self] in self.sleepDisabled = $0; return (true, nil) },
                                   relaunchApp: { [unowned self] in self.relaunches += 1 }),
                    now: { [clock] in clock.date })
    }

    func testDisarmRestoresSleep() {
        let lease = makeLease()
        lease.connected()
        lease.arm()
        XCTAssertTrue(sleepDisabled)
        lease.disarm()
        XCTAssertFalse(sleepDisabled)
    }

    func testAHungAppLosesTheLease() {
        let lease = makeLease()
        lease.connected()
        lease.arm()
        clock.advance(HelperInfo.leaseSeconds - 1)
        lease.check()
        XCTAssertTrue(sleepDisabled, "still within the lease")
        clock.advance(2)
        lease.check()
        XCTAssertFalse(sleepDisabled, "no heartbeat for the whole lease: sleep comes back")
    }

    func testHeartbeatsKeepTheLeaseAlive() {
        let lease = makeLease()
        lease.connected()
        lease.arm()
        for _ in 0..<20 {
            clock.advance(HelperInfo.heartbeatSeconds)
            lease.heartbeat()
            lease.check()
        }
        XCTAssertTrue(sleepDisabled)
    }

    func testAKilledAppIsRelaunchedAndTheMacStaysAwake() {
        let lease = makeLease()
        lease.connected()
        lease.arm()
        lease.disconnected()
        XCTAssertTrue(sleepDisabled)
        XCTAssertEqual(relaunches, 1)
        XCTAssertTrue(lease.isAwaitingRelaunch)

        // The app comes back, reconnects and re-arms.
        clock.advance(5)
        lease.connected()
        lease.arm()
        XCTAssertFalse(lease.isAwaitingRelaunch)
        XCTAssertTrue(sleepDisabled)
    }

    func testIfTheAppNeverComesBackSleepIsRestored() {
        let lease = makeLease()
        lease.connected()
        lease.arm()
        lease.disconnected()
        clock.advance(HelperInfo.relaunchGraceSeconds - 1)
        lease.check()
        XCTAssertTrue(sleepDisabled)
        XCTAssertEqual(relaunches, 2, "keeps trying during the grace period")
        clock.advance(2)
        lease.check()
        XCTAssertFalse(sleepDisabled)
        XCTAssertFalse(lease.isArmed)
    }

    func testDisconnectingWhileDisarmedRestoresSleep() {
        let lease = makeLease()
        lease.connected()
        sleepDisabled = true // stale state from a previous run
        lease.disconnected()
        XCTAssertFalse(sleepDisabled)
        XCTAssertEqual(relaunches, 0)
    }
}

// MARK: - People tracking

final class PeopleTrackerTests: XCTestCase {
    private let person = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6)
    private let face = CGRect(x: 0.45, y: 0.65, width: 0.1, height: 0.12)

    func testAPersonIsConfirmedAfterThreeSightingsAndCountedOnce() {
        var t = PeopleTracker()
        var arrived = 0
        for i in 0..<10 { arrived += t.update(faces: [face], bodies: [person], now: Double(i) * 0.125).arrived }
        XCTAssertEqual(arrived, 1)
        XCTAssertEqual(t.tracks.filter(\.confirmed).count, 1)
    }

    func testAOneFrameMissDoesNotLoseThePerson() {
        var t = PeopleTracker()
        for i in 0..<5 { _ = t.update(faces: [face], bodies: [person], now: Double(i) * 0.125) }
        let missed = t.update(faces: [], bodies: [], now: 0.75)
        XCTAssertNotNil(missed.lookAt, "the eyes keep looking where the person was")
        XCTAssertEqual(missed.departed, 0)
        let back = t.update(faces: [face], bodies: [person], now: 0.875)
        XCTAssertEqual(back.arrived, 0, "coming back isn't a new person")
    }

    func testSomeoneLeavingIsReportedOnce() {
        var t = PeopleTracker()
        for i in 0..<5 { _ = t.update(faces: [face], bodies: [person], now: Double(i) * 0.125) }
        var departed = 0
        for i in 0..<20 { departed += t.update(faces: [], bodies: [], now: 0.75 + Double(i) * 0.125).departed }
        XCTAssertEqual(departed, 1)
        XCTAssertTrue(t.tracks.isEmpty)
    }

    func testTheEyesStickWithOnePersonUntilSomeoneIsClearlyMoreProminent() {
        var t = PeopleTracker()
        let left = CGRect(x: 0.05, y: 0.2, width: 0.2, height: 0.6)
        let right = CGRect(x: 0.7, y: 0.2, width: 0.22, height: 0.6) // a bit bigger, not 1.5x
        var obs = t.update(faces: [], bodies: [left], now: 0)
        for i in 1..<6 { obs = t.update(faces: [], bodies: [left], now: Double(i) * 0.125) }
        let followingLeft = obs.lookAt!.x
        for i in 6..<12 { obs = t.update(faces: [], bodies: [left, right], now: Double(i) * 0.125) }
        XCTAssertEqual(obs.lookAt!.x, followingLeft, accuracy: 0.1, "doesn't flip to a slightly bigger newcomer")

        let close = CGRect(x: 0.55, y: 0.05, width: 0.4, height: 0.9) // much bigger
        for i in 12..<18 { obs = t.update(faces: [], bodies: [left, close], now: Double(i) * 0.125) }
        XCTAssertLessThan(obs.lookAt!.x, followingLeft, "switches to someone clearly more prominent")
    }

    func testLingeringIsReportedAfterSixSeconds() {
        var t = PeopleTracker()
        let bigFace = CGRect(x: 0.4, y: 0.4, width: 0.25, height: 0.3)
        var lingers = 0
        var firstLinger: Double?
        for i in 0..<80 {
            let now = Double(i) * 0.125
            if t.update(faces: [bigFace], bodies: [], now: now).lingerStarted {
                lingers += 1
                firstLinger = firstLinger ?? now
            }
        }
        XCTAssertEqual(lingers, 1)
        XCTAssertGreaterThan(firstLinger ?? 0, 6)
    }
}

// MARK: - iMessage alerts

final class NotifierTests: XCTestCase {
    private let clock = TestClock()
    private let outbox = Outbox()

    private func make(enabled: Bool = true, photo: Bool = false) -> Notifier {
        let outbox = self.outbox
        let n = Notifier(defaults: ephemeralDefaults(), transport: { outbox.messages.append($0); return nil },
                         now: { [clock] in clock.date }, runsInline: true)
        n.isEnabled = enabled
        n.handle = "  me@icloud.com "
        n.includePhoto = photo
        return n
    }

    func testMessagesGoToTheOwnerAsSeparateArguments() {
        make().send("ALARM", "Lifted. \"quotes\" and \\ backslashes", priority: .urgent)
        XCTAssertEqual(outbox.messages.count, 1)
        XCTAssertEqual(outbox.messages[0][0], "me@icloud.com", "trimmed recipient")
        XCTAssertTrue(outbox.messages[0][1].hasPrefix("Torie-chan: ALARM\nLifted. \"quotes\" and \\ backslashes"),
                      "text is passed verbatim as an argument, never spliced into the script")
    }

    func testNothingIsSentWhenTurnedOff() {
        make(enabled: false).send("ALARM", "Lifted", priority: .urgent)
        XCTAssertTrue(outbox.messages.isEmpty)
    }

    func testWarningsAreRateLimitedButAlarmsAlwaysGoThrough() {
        let n = make()
        n.send("Someone's touching your laptop", "Bumped", priority: .high)
        clock.advance(30)
        n.send("Someone's touching your laptop", "Bumped", priority: .high)
        XCTAssertEqual(outbox.messages.count, 1)
        n.send("ALARM", "Lifted", priority: .urgent)
        n.send("ALARM", "Lid closed", priority: .urgent)
        XCTAssertEqual(outbox.messages.count, 3)
        clock.advance(121)
        n.send("Someone's touching your laptop", "Bumped", priority: .high)
        XCTAssertEqual(outbox.messages.count, 4)
    }

    func testThePhotoIsOnlyAttachedWhenTheOwnerOptsIn() {
        let photo = URL(fileURLWithPath: "/tmp/alarm.jpg")
        make(photo: false).send("ALARM", "Lifted", priority: .urgent, attachment: photo)
        XCTAssertEqual(outbox.messages.last?.count, 2)
        make(photo: true).send("ALARM", "Lifted", priority: .urgent, attachment: photo)
        XCTAssertEqual(outbox.messages.last?.last, "/tmp/alarm.jpg")
    }
}

// MARK: - Event log

final class EventLogTests: XCTestCase {
    func testOldEventsArePrunedOnLaunch() throws {
        let url = temporaryDirectory().appendingPathComponent("events.jsonl")
        let old = GuardEvent(date: Date().addingTimeInterval(-40 * 86_400), kind: "armed", message: "old")
        let recent = GuardEvent(date: Date().addingTimeInterval(-86_400), kind: "armed", message: "recent")
        let lines = try [old, recent].map { String(decoding: try ControlCoding.encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let log = EventLog(url: url)
        XCTAssertEqual(log.events.map(\.message), ["recent"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("\"old\""), "pruned on disk too")
    }

    func testRecentRespectsLimitAndSince() {
        let log = EventLog(url: temporaryDirectory().appendingPathComponent("events.jsonl"))
        for i in 0..<10 { log.add("person", "event \(i)") }
        XCTAssertEqual(log.recent(limit: 3, since: nil).map(\.message), ["event 7", "event 8", "event 9"])
        let cutoff = log.events[5].date
        XCTAssertTrue(log.recent(limit: 50, since: cutoff).allSatisfy { $0.date > cutoff })
    }
}
