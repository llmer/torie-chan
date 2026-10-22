import Foundation

/// XPC interface exported by the privileged helper (runs as root via SMAppService).
///
/// The helper keeps lid-close sleep disabled while the guard is armed. It distinguishes a
/// deliberate disarm from the app vanishing:
/// - `disarm` → sleep restored immediately.
/// - Connection drops while armed (app killed/crashed) → helper relaunches the app in the
///   owner's session (it comes back up screaming) and keeps sleep disabled for a short window.
/// - No heartbeat for `leaseSeconds` (app hung), or no relaunch within the window → sleep is
///   restored anyway, so the Mac can never be left cooking in a bag.
@objc public protocol GuardHelperProtocol {
    func arm(reply: @escaping (Bool, String?) -> Void)
    func heartbeat()
    func disarm(reply: @escaping (Bool, String?) -> Void)
    func version(reply: @escaping (String) -> Void)
    /// Whether the calling user's guard is armed, or waiting for the app to come back after it vanished.
    /// Read-only. The app asks at launch, so erasing its own armed marker can't make it forget.
    func guardState(reply: @escaping (Bool) -> Void)
}

public enum HelperInfo {
    public static let version = "3"
    /// The app sends a heartbeat at least this often while armed.
    public static let heartbeatSeconds: TimeInterval = 5
    /// Helper restores sleep if it hears nothing for this long.
    public static let leaseSeconds: TimeInterval = 30
    /// After the app disappears while armed, how long the helper keeps the Mac awake waiting for it to come back.
    public static let relaunchGraceSeconds: TimeInterval = 60
}
