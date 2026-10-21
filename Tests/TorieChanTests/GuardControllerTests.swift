import XCTest
@testable import GuardShared
@testable import TorieChan

/// The guard's state machine, end to end, with fake sensors and a controllable clock.
@MainActor
final class GuardControllerTests: XCTestCase {
    // MARK: Arming

    func testArmingNeedsACodeAndConsent() {
        let noCode = GuardHarness(code: nil)
        var askedForSetup = false
        noCode.guardian.onNeedsSetup = { askedForSetup = true }
        XCTAssertNotNil(noCode.guardian.arm())
        XCTAssertEqual(noCode.phase, "disarmed")
        XCTAssertTrue(askedForSetup)

        let noConsent = GuardHarness(acknowledged: false)
        XCTAssertNotNil(noConsent.guardian.arm())
        XCTAssertEqual(noConsent.phase, "disarmed")
    }

    func testCountdownThenWatching() {
        let h = GuardHarness()
        XCTAssertNil(h.guardian.arm(countdown: 3))
        XCTAssertEqual(h.phase, "arming")
        XCTAssertTrue(h.sleep.engaged, "lid protection engages at arm time")
        XCTAssertTrue(h.guardian.armedMarker.exists, "armed marker written so a kill is detectable")
        h.advance(2.5)
        XCTAssertEqual(h.phase, "arming")
        h.advance(0.8)
        XCTAssertEqual(h.phase, "armed")
        XCTAssertEqual(h.alarm.chirps, 1)
        XCTAssertTrue(h.guardian.events.events.contains { $0.kind == "armed" })
    }

    // MARK: Motion

    func testASingleKnockIsIgnored() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(2, accel: GuardHarness.knock(at: 0.5))
        XCTAssertEqual(h.phase, "armed")
        XCTAssertTrue(h.alarm.spoken.isEmpty)
    }

    func testRepeatedKnockingWarnsAndTexts() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(2) { t in
            [0.2, 0.7, 1.2].map { GuardHarness.knock(at: $0)(t) - GuardHarness.flat }.reduce(GuardHarness.flat, +)
        }
        XCTAssertEqual(h.phase, "suspicious")
        XCTAssertEqual(h.alarm.spoken.count, 1, "spoken warning")
        XCTAssertFalse(h.alarm.isSounding, "a warning is not the siren")
        XCTAssertTrue(h.outbox.texts.contains { $0.contains("Someone's touching your laptop") })
    }

    func testWarningCalmsDownWhenLeftAlone() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(2) { t in
            [0.2, 0.7, 1.2].map { GuardHarness.knock(at: $0)(t) - GuardHarness.flat }.reduce(GuardHarness.flat, +)
        }
        XCTAssertEqual(h.phase, "suspicious")
        h.advance(8)
        XCTAssertEqual(h.phase, "armed")
        XCTAssertTrue(h.guardian.events.events.contains { $0.kind == "calm" })
    }

    func testOwnerTypingRightAfterAWarningCancelsIt() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(1.5) { t in
            [0.2, 0.7, 1.2].map { GuardHarness.knock(at: $0)(t) - GuardHarness.flat }.reduce(GuardHarness.flat, +)
        }
        XCTAssertEqual(h.phase, "suspicious")
        h.guardian.noteUserInput()
        XCTAssertEqual(h.phase, "armed")
        XCTAssertGreaterThan(h.alarm.hushCount, 0)
    }

    func testTypingLongAfterAWarningDoesNotCancelIt() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(1.5) { t in
            [0.2, 0.7, 1.2].map { GuardHarness.knock(at: $0)(t) - GuardHarness.flat }.reduce(GuardHarness.flat, +)
        }
        h.advance(3)
        h.guardian.noteUserInput()
        XCTAssertNotEqual(h.phase, "armed")
    }

    func testLiftingSoundsTheAlarmAndTextsTheOwner() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(1.5) { t in GuardHarness.tilted(min(25, t * 30)) }
        XCTAssertEqual(h.phase, "alarm")
        XCTAssertTrue(h.alarm.isSounding)
        XCTAssertTrue(h.outbox.texts.contains { $0.contains("ALARM") })
        let alarm = h.guardian.events.events.last { $0.kind == "alarm" }
        XCTAssertNotNil(alarm?.snapshotPath, "an alarm photo is saved")
        XCTAssertTrue(alarm?.snapshotPath?.hasPrefix(h.directory.path) == true, "photo goes to the data folder")
    }

    // MARK: Lid, charger, devices

    func testClosedLidEscalatesAfterAShortFuse() {
        let h = GuardHarness()
        h.armAndWatch()
        h.system.set { $0.lidClosed = true }
        XCTAssertEqual(h.phase, "suspicious")
        h.advance(1.7)
        XCTAssertEqual(h.phase, "alarm")
    }

    func testReopeningTheLidWithinTheFuseCalmsDown() {
        let h = GuardHarness()
        h.armAndWatch()
        h.system.set { $0.lidClosed = true }
        h.advance(0.5)
        h.system.set { $0.lidClosed = false }
        h.advance(1.5)
        XCTAssertEqual(h.phase, "armed")
    }

    func testWithoutTheHelperAClosedLidAlarmsImmediately() {
        let h = GuardHarness()
        h.sleep.protectionWhenEngaged = .helperNotInstalled
        h.armAndWatch()
        h.system.set { $0.lidClosed = true }
        XCTAssertEqual(h.phase, "alarm", "the Mac is about to sleep; there's no time for a warning")
    }

    func testUnpluggedChargerThatStaysUnpluggedAlarms() {
        let h = GuardHarness()
        h.armAndWatch()
        h.system.set { $0.onACPower = false }
        XCTAssertEqual(h.phase, "suspicious")
        h.advance(5.5)
        XCTAssertEqual(h.phase, "alarm")
    }

    func testPluggingInHeadphonesIsTampering() {
        let h = GuardHarness()
        h.armAndWatch()
        h.audio = AudioOutput.Fingerprint(wiredOutputs: ["BuiltInSpeakerDevice", "BuiltInHeadphoneOutputDevice"], speakerDataSource: 1)
        h.advance(1)
        XCTAssertEqual(h.phase, "suspicious")
        h.advance(6)
        XCTAssertEqual(h.phase, "alarm")
    }

    func testMotionSensorGoingSilentIsTampering() {
        let h = GuardHarness()
        h.armAndWatch()
        h.motion.isHealthy = false
        h.advance(6)
        XCTAssertEqual(h.phase, "alarm")
    }

    func testScreenLockAndPowerButtonAreTampering() {
        let h = GuardHarness()
        h.armAndWatch()
        h.guardian.tamper("Screen was locked")
        XCTAssertEqual(h.phase, "alarm")
    }

    func testFocusLossOnlyCountsAfterTheScreenHadFocus() {
        let h = GuardHarness()
        XCTAssertNil(h.guardian.arm(countdown: 3))
        h.guardian.kioskFocusChanged(false) // macOS refused to activate a background launch
        h.advance(3.5)
        XCTAssertEqual(h.phase, "armed", "starting unfocused is shown on screen, not treated as an escape")

        h.guardian.kioskFocusChanged(true)
        h.guardian.kioskFocusChanged(false)
        h.advance(2.5)
        XCTAssertEqual(h.phase, "alarm")
    }

    // MARK: Disarming

    func testCorrectCodeDisarmsAndDebriefs() {
        let h = GuardHarness()
        h.armAndWatch()
        h.advance(60)
        h.enter(GuardHarness.code)
        guard case .welcomeBack(let box) = h.guardian.phase else {
            return XCTFail("expected the welcome-back debrief, got \(h.phase)")
        }
        XCTAssertEqual(box.summary.disarmedWith, "code")
        XCTAssertEqual(h.sleep.releaseCount, 1, "lid sleep restored")
        XCTAssertFalse(h.guardian.armedMarker.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("last_session.json").path))
    }

    func testWrongCodesLockTheKeypadAndSoundTheAlarm() {
        let h = GuardHarness()
        h.armAndWatch()
        h.enter("111111")
        h.enter("222222")
        XCTAssertEqual(h.phase, "armed", "two wrong tries are free")
        h.enter("333333")
        XCTAssertEqual(h.phase, "alarm")

        h.enter(GuardHarness.code)
        XCTAssertEqual(h.phase, "alarm", "even the right code waits out the lockout")
        h.advance(11)
        h.enter(GuardHarness.code)
        XCTAssertEqual(h.phase, "disarmed", "welcome-back resolves to disarmed")
        XCTAssertFalse(h.alarm.isSounding)
    }

    func testRelaunchAfterBeingKilledComesBackScreaming() {
        let first = GuardHarness()
        first.armAndWatch()
        XCTAssertTrue(first.guardian.armedMarker.exists)

        // Same data folder, new process.
        let second = GuardHarness(directory: first.directory)
        second.guardian.resumeAfterTamper()
        XCTAssertEqual(second.phase, "alarm")
        XCTAssertTrue(second.alarm.isSounding)
    }

    // MARK: Agents (control socket / MCP requests)

    func testAgentsGetAMinimumCountdownAndSanitizedNotes() {
        let h = GuardHarness()
        let response = h.guardian.handle(ControlRequest(command: .arm, countdownSeconds: 0,
                                                        note: "Back\nin 5\u{0007}" + String(repeating: "!", count: 100)))
        XCTAssertTrue(response.ok)
        guard case .arming(let until) = h.guardian.phase else { return XCTFail("not arming") }
        XCTAssertEqual(until.timeIntervalSince(h.clock.date), Double(GuardController.minAgentCountdown), accuracy: 0.01)
        let note = h.guardian.note ?? ""
        XCTAssertTrue(note.hasPrefix("Back in 5 "))
        XCTAssertLessThanOrEqual(note.count, 60)
        XCTAssertFalse(note.contains("\n"))
    }

    func testAnAgentCantRewriteTheNoteOnceArmed() {
        let h = GuardHarness()
        _ = h.guardian.handle(ControlRequest(command: .arm, note: "Back in 5"))
        _ = h.guardian.handle(ControlRequest(command: .arm, note: "Call support at 555-0100"))
        XCTAssertEqual(h.guardian.note, "Back in 5")
    }

    func testThereIsNoDisarmCommand() {
        let json = Data(#"{"command":"disarm"}"#.utf8)
        XCTAssertThrowsError(try ControlCoding.decoder.decode(ControlRequest.self, from: json))
    }

    func testAgentUpdatesOnlyWhileGuarding() {
        let h = GuardHarness()
        XCTAssertFalse(h.guardian.handle(ControlRequest(command: .postUpdate, message: "tests passing")).ok)
        h.armAndWatch()
        XCTAssertTrue(h.guardian.handle(ControlRequest(command: .postUpdate, message: "tests\npassing")).ok)
        XCTAssertEqual(h.guardian.agentUpdate, "tests passing")
    }

    // MARK: Readiness

    func testReadinessNamesWhatIsntCovered() {
        let h = GuardHarness(alerts: false)
        h.cameraAllowed = false
        let gaps = h.guardian.readinessDetail().gaps.map(\.fix)
        XCTAssertTrue(gaps.contains(.alerts))
        XCTAssertTrue(gaps.contains(.camera))
        XCTAssertFalse(gaps.contains(.lidHelper), "helper is enabled in this harness")
    }
}
