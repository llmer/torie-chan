import AppKit
import Sparkle

/// Auto-updates through Sparkle: an appcast published with each GitHub release, with every update
/// signed by our EdDSA key and by the same Developer ID team.
///
/// Never while guarding: an update relaunches the app (which would look like tampering), and an
/// update window must never sit on top of the guard screen. Checks are refused while guarding and a
/// relaunch is held until the guard is disarmed.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// A scheduled check found this version while Torie-chan was in the background. Shown as a gentle
    /// reminder in the menu bar and Settings instead of a window popping up out of nowhere.
    @Published private(set) var availableVersion: String?

    private let isGuarding: () -> Bool
    private var controller: SPUStandardUpdaterController?
    private var postponedRelaunch: (() -> Void)?

    /// Only a real app bundle updates itself; `swift run`, tests and snapshot mode don't.
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    init(isGuarding: @escaping () -> Bool) {
        self.isGuarding = isGuarding
        super.init()
        guard Self.isAvailable else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var canCheck: Bool { controller != nil && !isGuarding() }

    func checkForUpdates() {
        guard let controller, !isGuarding() else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Call when the guard is disarmed: lets a relaunch that was held back go ahead.
    func guardEnded() {
        guard let relaunch = postponedRelaunch else { return }
        postponedRelaunch = nil
        relaunch()
    }

    struct GuardingError: LocalizedError {
        var errorDescription: String? { "Torie-chan doesn't update while she's guarding." }
    }

    /// The update policy, separated so it can be tested: no checks of any kind while guarding.
    nonisolated static func mayCheck(guarding: Bool) throws {
        if guarding { throw GuardingError() }
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try MainActor.assumeIsolated { try Self.mayCheck(guarding: isGuarding()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard isGuarding() else { return false }
            postponedRelaunch = installHandler
            return true
        }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                         andInImmediateFocus immediateFocus: Bool) -> Bool {
        // A menu bar app is rarely in focus: only show Sparkle's window if it is, otherwise remind gently.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                NSApp.activate()
            } else {
                availableVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
