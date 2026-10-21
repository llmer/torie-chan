import Foundation

public enum GuardIDs {
    public static let appBundleID = "com.mostperfectsip.toriechan"
    public static let helperLabel = "com.mostperfectsip.toriechan.helper"
    public static let helperPlistName = "\(helperLabel).plist"

    /// ~/Library/Application Support/Torie-chan, or `TORIECHAN_SUPPORT_DIR` when set (tests use a
    /// temporary folder so they can never talk to, or arm, a real running Torie-chan).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TORIECHAN_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Torie-chan", isDirectory: true)
    }

    public static var controlSocketPath: String {
        supportDirectory.appendingPathComponent("control.sock").path
    }

    public static var eventLogURL: URL {
        supportDirectory.appendingPathComponent("events.jsonl")
    }

    public static var snapshotsDirectory: URL {
        supportDirectory.appendingPathComponent("Snapshots", isDirectory: true)
    }
}
