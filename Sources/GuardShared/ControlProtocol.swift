import Foundation

/// Line-delimited JSON over a unix socket between `bg-mcp` (or any local client) and the app.
/// There is intentionally no disarm command: disarming requires the owner's code or Touch ID in person.
public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case arm, status, events, lastSession, postUpdate
    }

    public var command: Command
    public var countdownSeconds: Int?
    public var note: String?
    public var expectedBackMinutes: Int?
    public var limit: Int?
    public var since: Date?
    public var message: String?

    public init(command: Command, countdownSeconds: Int? = nil, note: String? = nil, expectedBackMinutes: Int? = nil,
                limit: Int? = nil, since: Date? = nil, message: String? = nil) {
        self.command = command
        self.countdownSeconds = countdownSeconds
        self.note = note
        self.expectedBackMinutes = expectedBackMinutes
        self.limit = limit
        self.since = since
        self.message = message
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: GuardStatus?
    public var events: [GuardEvent]?
    public var session: SessionSummary?

    public init(ok: Bool, error: String? = nil, status: GuardStatus? = nil, events: [GuardEvent]? = nil, session: SessionSummary? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
        self.events = events
        self.session = session
    }
}

public struct GuardStatus: Codable, Sendable {
    public var state: String
    public var detail: String?
    public var armedSince: Date?
    public var expectedBack: Date?
    public var note: String?
    public var peopleSeen: Int
    public var peopleInView: Int
    public var lidClosed: Bool
    public var onACPower: Bool
    /// What will actually set the alarm off right now.
    public var protections: [String]
    /// What isn't covered, in plain words, so the agent can tell the owner before they walk away.
    public var gaps: [String]
    public var kioskFocused: Bool
    public var passcodeSet: Bool

    public init(state: String, detail: String?, armedSince: Date?, expectedBack: Date?, note: String?, peopleSeen: Int, peopleInView: Int,
                lidClosed: Bool, onACPower: Bool, protections: [String], gaps: [String], kioskFocused: Bool, passcodeSet: Bool) {
        self.state = state
        self.detail = detail
        self.armedSince = armedSince
        self.expectedBack = expectedBack
        self.note = note
        self.peopleSeen = peopleSeen
        self.peopleInView = peopleInView
        self.lidClosed = lidClosed
        self.onACPower = onACPower
        self.protections = protections
        self.gaps = gaps
        self.kioskFocused = kioskFocused
        self.passcodeSet = passcodeSet
    }
}

public struct GuardEvent: Codable, Sendable {
    public var date: Date
    public var kind: String
    public var message: String
    /// Local file path of an alarm photo. Never sent to agents (see bg-mcp).
    public var snapshotPath: String?

    public init(date: Date = Date(), kind: String, message: String, snapshotPath: String? = nil) {
        self.date = date
        self.kind = kind
        self.message = message
        self.snapshotPath = snapshotPath
    }
}

/// One armed → disarmed stretch, for the welcome-back debrief and `last_session`.
public struct SessionSummary: Codable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var peopleWalkedBy: Int
    public var gotClose: Int
    public var lingered: Int
    public var warnings: [String]
    public var alarms: [String]
    public var wrongCodes: Int
    public var disarmedWith: String?
    public var agentUpdates: [String]
    public var photoTaken: Bool

    public var isActive: Bool { endedAt == nil }
    public var minutes: Int { Int(((endedAt ?? Date()).timeIntervalSince(startedAt) / 60).rounded()) }

    public init(startedAt: Date) {
        self.startedAt = startedAt
        peopleWalkedBy = 0
        gotClose = 0
        lingered = 0
        warnings = []
        alarms = []
        wrongCodes = 0
        agentUpdates = []
        photoTaken = false
    }

    /// For the event log: "after 7 minutes. 14 people walked by. Nobody touched it."
    public var sentence: String {
        var parts: [String] = []
        parts.append(minutes < 1 ? "after under a minute." : "after \(minutes) minute\(minutes == 1 ? "" : "s").")
        parts.append(peopleWalkedBy == 1 ? "1 person walked by." : "\(peopleWalkedBy) people walked by.")
        if !alarms.isEmpty {
            parts.append("The alarm went off (\(alarms[0].lowercased())).")
        } else if !warnings.isEmpty {
            parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s").")
        } else {
            parts.append("Nobody touched it.")
        }
        return parts.joined(separator: " ")
    }

    /// "7 min · 14 walked by · 2 got close · nobody touched it"
    public var headline: String {
        var parts = ["\(minutes) min", "\(peopleWalkedBy) walked by"]
        if gotClose > 0 { parts.append("\(gotClose) got close") }
        if !alarms.isEmpty {
            parts.append("ALARM: \(alarms[0].lowercased())")
        } else if !warnings.isEmpty {
            parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
        } else {
            parts.append("nobody touched it")
        }
        return parts.joined(separator: " · ")
    }
}

public enum ControlCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Text that came from an agent and will be shown on screen / stored. Plain, short, one line.
public enum AgentText {
    public static func sanitize(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let cleaned = text.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength - 1)) + "…" : cleaned
    }
}
