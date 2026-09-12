// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// The shared goals ledger (docs/SITES.md §8): goals belong to the user, not to
/// a host, so the per-site `goals-ledger.json` stops forking. This is the pure
/// half — the version/If-Match protocol's decoder and the three-way merge —
/// with no transport, so the daemon and the app run one rule.
///
/// Merge rules, as written in the design: goals keyed by `id`; `updates[]`
/// unioned by `(at, kind, text)`; scalar fields (`state`, `priority`,
/// `next_action`, `blocked_on`, `tags`) from whichever side has the later
/// `updates.at`; no deletes — removal is `state: done` with a close update.
public enum GoalsLedgerSync {
    /// What `GET /agents/{agent}/goals` returns.
    public struct Remote: Equatable, Sendable {
        public var version: Int
        public var document: LedgerDocument?
        public init(version: Int, document: LedgerDocument?) {
            self.version = version
            self.document = document
        }
    }

    public static func decodeRemote(_ data: Data) -> Remote? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int
        else { return nil }
        var document: LedgerDocument?
        if let raw = object["document"] as? [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: raw) {
            document = try? JSONDecoder().decode(LedgerDocument.self, from: encoded)
        }
        return Remote(version: version, document: document)
    }

    public static func encodeForPut(_ document: LedgerDocument) -> Data? {
        guard let encoded = try? JSONEncoder().encode(document),
              let object = try? JSONSerialization.jsonObject(with: encoded)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["document": object])
    }

    /// Three-way merge of `local` and `remote` over `base` (the last version this
    /// side pulled; nil on a first sync, which degrades to a two-way union).
    public static func merge(base: LedgerDocument?, local: LedgerDocument, remote: LedgerDocument) -> LedgerDocument {
        var merged = LedgerDocument()
        merged.version = max(local.version, remote.version)
        var order: [String] = []
        var byID: [String: Goal] = [:]
        for goal in remote.goals + local.goals where byID[goal.id] == nil || true {
            if byID[goal.id] == nil { order.append(goal.id) }
            if let existing = byID[goal.id] {
                byID[goal.id] = mergeGoal(existing, goal)
            } else {
                byID[goal.id] = goal
            }
        }
        merged.goals = order.compactMap { byID[$0] }
        merged.updatedAt = [local.updatedAt, remote.updatedAt].compactMap { $0 }.max()
        return merged
    }

    static func mergeGoal(_ a: Goal, _ b: Goal) -> Goal {
        // Union of updates by (at, kind, text), ordered by `at` then insertion.
        var seen = Set<String>()
        var updates: [Update] = []
        for update in (a.updates + b.updates).sorted(by: { $0.at < $1.at }) {
            let key = update.at + "|" + update.kind.rawValue + "|" + update.text
            if seen.insert(key).inserted { updates.append(update) }
        }
        // Scalars from the side whose newest update is later; ties keep `a`
        // (remote first in `merge`'s ordering, so a fresh pull wins a tie).
        let aLatest = a.updates.map(\.at).max() ?? a.createdAt ?? ""
        let bLatest = b.updates.map(\.at).max() ?? b.createdAt ?? ""
        var winner = bLatest > aLatest ? b : a
        // "done" is sticky: a close on either side closes the goal (no deletes).
        if a.state == .done || b.state == .done { winner.state = .done }
        winner.updates = updates
        // Tags union, stable order.
        var tags = winner.tags
        for tag in (winner.id == a.id ? b.tags : a.tags) where !tags.contains(tag) { tags.append(tag) }
        winner.tags = tags
        return winner
    }

    /// A content fingerprint so a side only pushes when something changed.
    public static func fingerprint(_ document: LedgerDocument) -> String {
        var copy = document
        copy.updatedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(copy)) ?? Data()
        return String(data.count) + ":" + String(data.hashValue)
    }
}
