import Foundation

/// One parsed line of the iCloud log mirror — the same JSONL shape
/// `AgentLogMirror.line(for:)` writes via `AgentLogEntry.jsonlLine()`, decoded
/// tolerantly (unknown fields ignored, missing optionals defaulted) so an older
/// device's files still render.
struct AgentMirrorRecord: Identifiable, Equatable {
    let id: String
    let kind: AgentLogKind
    let text: String
    let timestamp: Date
    let sequence: Int
    let runID: String
    let toolName: String?
    /// Which body wrote this line (docs/SITES.md §7) — its `siteId8`, and the
    /// display name it reported. Optional: lines from before sites existed
    /// carry neither, and render exactly as they always did.
    let siteID8: String?
    let siteName: String?
    /// For a user line the daemon injected from the control-plane queue: the
    /// message id it applied. Two lines sharing one are the same message
    /// applied twice (the at-least-once window) and are collapsed in `merge`.
    let inReplyTo: String?

    /// Synthetic row, for reader-generated notices (e.g. an oversized file that
    /// was skipped rather than read) — never parsed from a mirror line.
    init(
        id: String, kind: AgentLogKind, text: String, timestamp: Date,
        sequence: Int = 0, runID: String = "", toolName: String? = nil,
        siteID8: String? = nil, siteName: String? = nil, inReplyTo: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.sequence = sequence
        self.runID = runID
        self.toolName = toolName
        self.siteID8 = siteID8
        self.siteName = siteName
        self.inReplyTo = inReplyTo
    }

    /// Decodes one JSONL line; nil for blank lines, the truncation marker, or
    /// anything else that isn't a mirror object.
    init?(jsonlLine line: String) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = object["kind"] as? String,
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = AgentMirrorRecord.timestampFormatter.date(from: timestampRaw)
        else { return nil }
        self.id = object["id"] as? String ?? UUID().uuidString
        self.kind = AgentLogKind(rawValue: kindRaw) ?? .notice
        self.text = object["text"] as? String ?? ""
        self.timestamp = timestamp
        self.sequence = object["sequence"] as? Int ?? 0
        self.runID = object["run_id"] as? String ?? ""
        self.toolName = object["tool_name"] as? String
        self.siteID8 = object["site_id8"] as? String
        self.siteName = object["site_name"] as? String
        self.inReplyTo = object["in_reply_to"] as? String
    }

    /// `AgentLogEntry.jsonlLine()` writes plain ISO8601 without fractional seconds.
    static let timestampFormatter = ISO8601DateFormatter()
}

/// Pure transcript-line helpers shared by every target (the tvOS app has no
/// iCloud mirror files, but reads the same lines from the control plane).
enum MirrorRecords {
    /// All parseable records in one file's content, in file order.
    static func parseLines(_ content: String) -> [AgentMirrorRecord] {
        content
            .components(separatedBy: "\n")
            .compactMap { AgentMirrorRecord(jsonlLine: $0) }
    }

    /// One timeline from several per-device files: ordered by timestamp, with the
    /// run/sequence pair breaking ties — entries inside one run share seconds
    /// constantly, and their sequence is the real order.
    ///
    /// Two dedupes on the way: the same `id` seen twice (an hour fetched twice,
    /// a file mirrored by two devices) keeps its first occurrence; and two user
    /// lines sharing an `in_reply_to` — one message applied by two bodies in the
    /// at-least-once window — keep the earlier, with the later's site named in
    /// the survivor's text so the double application is stated, not hidden.
    static func merge(_ groups: [[AgentMirrorRecord]]) -> [AgentMirrorRecord] {
        let sorted = groups
            .flatMap { $0 }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.runID == $1.runID { return $0.sequence < $1.sequence }
                return $0.runID < $1.runID
            }
        var seenIDs = Set<String>()
        var replyIndex: [String: Int] = [:]
        var result: [AgentMirrorRecord] = []
        for record in sorted {
            guard seenIDs.insert(record.id).inserted else { continue }
            if record.kind == .userMessage, let reply = record.inReplyTo {
                if let index = replyIndex[reply] {
                    let first = result[index]
                    let names = [first.siteName ?? first.siteID8, record.siteName ?? record.siteID8]
                        .compactMap { $0 }
                    result[index] = AgentMirrorRecord(
                        id: first.id, kind: first.kind,
                        text: first.text + "\n(handled by \(names.joined(separator: " and ")))",
                        timestamp: first.timestamp, sequence: first.sequence, runID: first.runID,
                        toolName: first.toolName, siteID8: first.siteID8, siteName: first.siteName,
                        inReplyTo: first.inReplyTo
                    )
                    continue
                }
                replyIndex[reply] = result.count
            }
            result.append(record)
        }
        return result
    }

}
