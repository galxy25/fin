import Foundation
import FinAgentCore

/// The daemon's memory of which thread last relayed into which pane (docs/THREADS.md
/// §2, implicit membership): `pane target → (threadId, lastAt)`, persisted beside
/// `pane-inventory.json` so a restart keeps it. Two questions, both pure:
///
/// - `proposal(for:)` — the thread a message whose turn relayed into these panes
///   should join: the NEWEST thread among the panes' entries younger than
///   `window` (24 h). Older entries are forgotten on read: a request to "the claw
///   session" a day and a half later is a new conversation, not the ninth reply to
///   the last one. Reason strings are the wire vocabulary the control plane logs
///   as `thread.assigned`: `pane:<target>`.
/// - `record(targets:threadID:)` — what every finished message turn writes: each
///   pane it sent to now belongs to the thread the control plane settled on.
///
/// Persistence is best-effort; a map that cannot be written costs one thread
/// proposal, never a turn.
struct DaemonPaneThreadMap: Equatable {
    struct Entry: Codable, Equatable {
        var threadID: String
        var lastAt: Date

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case lastAt
        }
    }

    struct Proposal: Equatable {
        let threadID: String
        let target: String
        var reason: String { "pane:\(target)" }
    }

    /// The pane-match window: a pane relayed into more than this long ago no longer
    /// implies the same conversation.
    static let window: TimeInterval = 24 * 60 * 60
    /// The most panes remembered; the oldest entries go first. A machine has a
    /// handful of live panes, not hundreds — this only bounds a runaway.
    static let maxEntries = 200
    static let standardFileName = "pane-threads.json"
    /// The reason logged when no pane matched and the message roots its own thread.
    static let rootReason = "root"

    private(set) var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    // MARK: - Decisions

    /// The thread the newest fresh entry among `targets` names, or nil when none of
    /// them relayed within the window. Ties (two panes stamped in the same instant)
    /// break on the target name so the answer is deterministic.
    func proposal(for targets: [String], now: Date = Date()) -> Proposal? {
        let fresh = targets.compactMap { target -> (String, Entry)? in
            guard let entry = entries[target], now.timeIntervalSince(entry.lastAt) < Self.window
            else { return nil }
            return (target, entry)
        }
        guard let best = fresh.max(by: { lhs, rhs in
            if lhs.1.lastAt != rhs.1.lastAt { return lhs.1.lastAt < rhs.1.lastAt }
            return lhs.0 > rhs.0
        }) else { return nil }
        return Proposal(threadID: best.1.threadID, target: best.0)
    }

    /// The pane targets whose tmux session (the part before the first colon) is
    /// `session` and whose entry is still within the window — how a pre-turn
    /// routing decision naming a SESSION maps onto the pane-keyed memory.
    func freshTargets(inSession session: String, now: Date = Date()) -> [String] {
        entries.compactMap { target, entry in
            guard now.timeIntervalSince(entry.lastAt) < Self.window else { return nil }
            guard target.split(separator: ":", maxSplits: 1).first.map(String.init) == session else { return nil }
            return target
        }.sorted()
    }

    /// Every pane the finished turn sent to now belongs to `threadID`. Entries older
    /// than the window are dropped at the same time, so the file never grows with
    /// panes nobody has talked to in days.
    mutating func record(targets: [String], threadID: String, now: Date = Date()) {
        guard !threadID.isEmpty else { return }
        for target in targets where !target.isEmpty {
            entries[target] = Entry(threadID: threadID, lastAt: now)
        }
        entries = entries.filter { now.timeIntervalSince($0.value.lastAt) < Self.window }
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Loads the map at `path`; a missing or unreadable file is an empty map, never
    /// an error — the worst case is one root thread that could have been a reply.
    static func load(from path: String) -> DaemonPaneThreadMap {
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? decoder.decode([String: Entry].self, from: data)
        else { return DaemonPaneThreadMap() }
        return DaemonPaneThreadMap(entries: entries)
    }

    func save(to path: String) throws {
        let data = try Self.encoder.encode(entries)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
