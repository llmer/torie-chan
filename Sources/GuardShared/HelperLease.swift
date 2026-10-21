import Foundation

/// The helper's lid-sleep lease (see GuardHelperProtocol), separated from XPC, launchd and
/// `pmset` so the fail-safe rules can be tested:
/// - disarm restores sleep immediately;
/// - the app vanishing while armed triggers relaunches for `relaunchGraceSeconds`, then sleep is restored;
/// - no heartbeat for `leaseSeconds` (app hung) restores sleep.
public final class HelperLease {
    public struct Actions {
        public var setSleepDisabled: (Bool) -> (Bool, String?)
        public var relaunchApp: () -> Void
        public var log: (String) -> Void

        public init(setSleepDisabled: @escaping (Bool) -> (Bool, String?), relaunchApp: @escaping () -> Void,
                    log: @escaping (String) -> Void = { _ in }) {
            self.setSleepDisabled = setSleepDisabled
            self.relaunchApp = relaunchApp
            self.log = log
        }
    }

    public private(set) var isArmed = false
    public private(set) var isAwaitingRelaunch = false

    private let actions: Actions
    private let now: () -> Date
    private var lastHeartbeat: Date
    private var awaitingRelaunchSince: Date?
    private var connections = 0

    public init(actions: Actions, now: @escaping () -> Date = Date.init) {
        self.actions = actions
        self.now = now
        lastHeartbeat = now()
    }

    @discardableResult
    public func arm() -> (Bool, String?) {
        isArmed = true
        setAwaiting(nil)
        lastHeartbeat = now()
        return actions.setSleepDisabled(true)
    }

    public func heartbeat() {
        lastHeartbeat = now()
        setAwaiting(nil)
    }

    @discardableResult
    public func disarm() -> (Bool, String?) {
        isArmed = false
        setAwaiting(nil)
        return actions.setSleepDisabled(false)
    }

    public func connected() {
        connections += 1
    }

    public func disconnected() {
        connections = max(0, connections - 1)
        guard connections == 0 else { return }
        guard isArmed else {
            _ = actions.setSleepDisabled(false)
            return
        }
        // The app vanished without disarming: it was killed or crashed. Bring it back; it will
        // find its armed marker and go straight to the alarm.
        actions.log("app disconnected while armed; relaunching")
        setAwaiting(now())
        actions.relaunchApp()
    }

    /// Call every few seconds.
    public func check() {
        guard isArmed else { return }
        let t = now()
        if let since = awaitingRelaunchSince {
            if t.timeIntervalSince(since) > HelperInfo.relaunchGraceSeconds {
                actions.log("app never came back; restoring sleep")
                isArmed = false
                setAwaiting(nil)
                _ = actions.setSleepDisabled(false)
            } else {
                actions.relaunchApp()
            }
        } else if t.timeIntervalSince(lastHeartbeat) > HelperInfo.leaseSeconds {
            actions.log("no heartbeat for \(Int(HelperInfo.leaseSeconds))s (app hung?); restoring sleep")
            isArmed = false
            _ = actions.setSleepDisabled(false)
        }
    }

    private func setAwaiting(_ date: Date?) {
        awaitingRelaunchSince = date
        isAwaitingRelaunch = date != nil
    }
}
