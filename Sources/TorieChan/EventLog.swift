import Foundation
import GuardShared

/// Append-only event log: kept in memory for the UI/MCP and mirrored to events.jsonl.
/// Events older than 30 days are dropped at launch; alarm photos follow the retention setting.
final class EventLog {
    static let maxAgeDays = 30

    private(set) var events: [GuardEvent] = []
    private let maxInMemory = 1000
    private let url = GuardIDs.eventLogURL

    init() {
        loadAndPrune()
    }

    func add(_ kind: String, _ message: String, snapshotPath: String? = nil) {
        let event = GuardEvent(kind: kind, message: message, snapshotPath: snapshotPath)
        events.append(event)
        if events.count > maxInMemory { events.removeFirst(events.count - maxInMemory) }
        append(event)
    }

    func recent(limit: Int, since: Date?) -> [GuardEvent] {
        let filtered = since.map { s in events.filter { $0.date > s } } ?? events
        return Array(filtered.suffix(max(1, min(limit, 500))))
    }

    func clear() {
        events.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ event: GuardEvent) {
        guard var line = try? ControlCoding.encoder.encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
    }

    private func loadAndPrune() {
        guard let data = try? Data(contentsOf: url) else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.maxAgeDays) * 86_400)
        let all = data.split(separator: 0x0A).compactMap { try? ControlCoding.decoder.decode(GuardEvent.self, from: Data($0)) }
        let kept = all.filter { $0.date > cutoff }
        if kept.count != all.count {
            var out = Data()
            for event in kept {
                if let line = try? ControlCoding.encoder.encode(event) { out.append(line); out.append(0x0A) }
            }
            try? out.write(to: url, options: .atomic)
        }
        events = Array(kept.suffix(maxInMemory))
    }
}

/// Alarm photo retention.
enum SnapshotRetention: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, forever = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .forever: "Forever"
        }
    }

    static var current: SnapshotRetention {
        get { SnapshotRetention(rawValue: UserDefaults.standard.object(forKey: "snapshotRetentionDays") as? Int ?? 7) ?? .week }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "snapshotRetentionDays") }
    }

    static func prune() {
        guard current != .forever else { return }
        let cutoff = Date().addingTimeInterval(-Double(current.rawValue) * 86_400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: GuardIDs.snapshotsDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
            if created < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
