// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// One push the model composed with its `notify` tool and the runner actually sent.
public struct RecentNotify: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var at: Date

    public init(title: String, body: String, at: Date) {
        self.title = title
        self.body = body
        self.at = at
    }
}

/// Mechanical dedupe for the model's `notify` tool. The prompt already says "never
/// spam", and on 2026-09-12/13 the model still pushed "Audit Complete" with the same
/// audit summary ten times in four hours, once per heartbeat tick that re-decided to
/// report an already-closed goal. A prompt rule is advisory; this is the floor under
/// it: a push that repeats a recent one is not sent, and the tool tells the model so.
///
/// "Repeats" is deliberately loose — the ten pushes varied their wording ("The audit
/// is complete!", "Final results: …", "The pocketdj audit is complete! Key results…")
/// and their titles ("Audit Complete", "PocketDJ Audit Complete", "Security Audit
/// Complete"). Two pushes match when either their normalized titles are equal or
/// their bodies share most of their words (Jaccard on word sets). Different news
/// with a reused title ("Build done" twice for two builds) is the price; the tool
/// result tells the model to change the title when it really is new.
public enum NotifyDedupe {
    /// How far back a push counts as "recent".
    public static let window: TimeInterval = 2 * 60 * 60
    /// How many recent pushes the runner keeps.
    public static let keep = 20
    /// Word-set overlap at or above which two bodies are the same news.
    public static let bodySimilarityThreshold = 0.6

    /// The recent push this one duplicates, or nil when it is new. The newest match
    /// wins so the model is told the most recent time it said this.
    public static func duplicate(
        title: String, body: String, in recent: [RecentNotify], now: Date, window: TimeInterval = window
    ) -> RecentNotify? {
        let titleKey = normalizedTitle(title)
        let words = wordSet(body)
        return recent
            .filter { now.timeIntervalSince($0.at) <= window && now.timeIntervalSince($0.at) >= 0 }
            .sorted { $0.at > $1.at }
            .first { candidate in
                if !titleKey.isEmpty, normalizedTitle(candidate.title) == titleKey { return true }
                return similarity(words, wordSet(candidate.body)) >= bodySimilarityThreshold
            }
    }

    /// The list to keep after `sent` went out: pruned to the window and the cap.
    public static func remembering(_ sent: RecentNotify, in recent: [RecentNotify], now: Date) -> [RecentNotify] {
        var kept = recent.filter { now.timeIntervalSince($0.at) <= window }
        kept.append(sent)
        if kept.count > keep { kept.removeFirst(kept.count - keep) }
        return kept
    }

    public static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 })
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}

/// The recent-push list on disk, a sibling of the stall marker — it must survive the
/// process restarts a crash loop causes, or every restart forgets what it already
/// told the owner. Missing or corrupt reads as empty; writes are best-effort.
public enum RecentNotifyStore {
    public static func load(at path: String) -> [RecentNotify] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecentNotify].self, from: data)) ?? []
    }

    public static func save(_ recent: [RecentNotify], at path: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(recent) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
