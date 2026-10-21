import Foundation

/// Phone alerts over iMessage, sent through Messages on this Mac to the owner's own iPhone
/// number or Apple ID email. No third-party service: iMessage is end-to-end encrypted, which is
/// also why the alarm photo may (optionally) be attached.
///
/// Sending runs Apple's `osascript` in a child process so the alarm never waits on Messages. The
/// recipient, text and photo path are passed as script arguments, never spliced into the script.
final class Notifier {
    enum Priority {
        case low, normal, high, urgent

        /// Minimum gap between messages of this kind, so a fidgety table doesn't spam you.
        var cooldown: TimeInterval {
            switch self {
            case .low: 600
            case .normal: 60
            case .high: 120
            case .urgent: 0
            }
        }
    }

    /// Sends the osascript arguments [recipient, text, photo path?]; returns an error or nil.
    typealias Transport = ([String]) -> String?

    private let defaults: UserDefaults
    private let transport: Transport
    private let now: () -> Date
    /// Tests run the transport inline; the app never blocks the alarm on Messages.
    private let queue: DispatchQueue?
    private var lastSent: [Priority: Date] = [:]

    init(defaults: UserDefaults = .standard, transport: @escaping Transport = Notifier.run,
         now: @escaping () -> Date = Date.init, runsInline: Bool = false) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        queue = runsInline ? nil : DispatchQueue(label: "toriechan.imessage")
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: "imessageEnabled") }
        set { defaults.set(newValue, forKey: "imessageEnabled") }
    }

    /// The owner's iPhone number or Apple ID email.
    var handle: String {
        get { defaults.string(forKey: "imessageHandle") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "imessageHandle") }
    }

    /// Attach the alarm photo. Off by default; it's a picture of whoever was at the laptop.
    var includePhoto: Bool {
        get { defaults.bool(forKey: "imessageIncludePhoto") }
        set { defaults.set(newValue, forKey: "imessageIncludePhoto") }
    }

    var isConfigured: Bool { isEnabled && Self.looksLikeHandle(handle) }

    static func looksLikeHandle(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains("@") { return t.split(separator: "@").count == 2 && t.contains(".") }
        return t.filter(\.isNumber).count >= 7
    }

    /// Send "Torie-chan: <title>\n<body>\n<time>". `force` skips the enabled check and cooldown (test button).
    func send(_ title: String, _ body: String, priority: Priority = .normal, attachment: URL? = nil, force: Bool = false,
              completion: ((String?) -> Void)? = nil) {
        guard force || isConfigured else { return }
        let now = self.now()
        if !force, let last = lastSent[priority], now.timeIntervalSince(last) < priority.cooldown { return }
        lastSent[priority] = now

        let time = now.formatted(date: .omitted, time: .shortened)
        let text = "Torie-chan: \(title)\n\(body)\n\(time)"
        var args = [handle, text]
        if let attachment, includePhoto || force { args.append(attachment.path) }

        guard let queue else {
            // Not `completion?(transport(args))`: optional chaining would skip the send when there's no completion.
            let error = transport(args)
            completion?(error)
            return
        }
        let transport = self.transport
        queue.async {
            let error = transport(args)
            DispatchQueue.main.async { completion?(error) }
        }
    }

    // MARK: - Messages scripting

    private static let script = [
        "on run argv",
        "  set theHandle to item 1 of argv",
        "  set theText to item 2 of argv",
        "  tell application \"Messages\"",
        "    set theAccount to 1st account whose service type = iMessage",
        "    set theBuddy to participant theHandle of theAccount",
        "    send theText to theBuddy",
        "  end tell",
        "  if (count of argv) > 2 then",
        "    set thePhoto to (POSIX file (item 3 of argv)) as alias",
        "    tell application \"Messages\" to send thePhoto to participant theHandle of (1st account whose service type = iMessage)",
        "  end if",
        "end run",
    ]

    /// Returns a human-readable error, or nil on success.
    static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = script.flatMap { ["-e", $0] } + args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
        } catch {
            return "Couldn't start osascript: \(error.localizedDescription)"
        }
        // Messages can hang if it's mid-sign-in; don't let a stuck send pile up.
        let deadline = Date().addingTimeInterval(25)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            return "Messages didn't respond in time."
        }
        guard p.terminationStatus != 0 else { return nil }
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return explain(message)
    }

    private static func explain(_ raw: String) -> String {
        if raw.contains("-1743") || raw.localizedCaseInsensitiveContains("not authorized") {
            return "macOS blocked Torie-chan from controlling Messages. Allow it in System Settings > Privacy & Security > Automation."
        }
        if raw.contains("-1728") || raw.localizedCaseInsensitiveContains("account") {
            return "Messages isn't signed in to iMessage on this Mac."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Messages couldn't send the message." : "Messages couldn't send it: \(trimmed)"
    }
}
