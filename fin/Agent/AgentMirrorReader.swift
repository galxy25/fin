import Foundation
import os

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

    /// Synthetic row, for reader-generated notices (e.g. an oversized file that
    /// was skipped rather than read) — never parsed from a mirror line.
    init(
        id: String, kind: AgentLogKind, text: String, timestamp: Date,
        sequence: Int = 0, runID: String = "", toolName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.sequence = sequence
        self.runID = runID
        self.toolName = toolName
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
    }

    /// `AgentLogEntry.jsonlLine()` writes plain ISO8601 without fractional seconds.
    static let timestampFormatter = ISO8601DateFormatter()
}

/// Read-only access to the iCloud log mirror for an agent whose runtime lives on
/// another device: finds that agent's recent day files across ALL device suffixes
/// and merges them into one timeline. Counterpart of `AgentLogMirror` (which only
/// ever appends to this device's own file) — kept separate because reading wants
/// none of the writer's caching/truncation state.
final class AgentMirrorReader: @unchecked Sendable {
    /// Files past this are skipped wholesale (with one synthetic notice row in
    /// their place): the writer caps its own day files at 5 MB, so anything
    /// bigger is not a legitimate mirror file, and this reader loads whole files
    /// into memory — it must not trust whatever sync happens to deliver.
    static let maxFileBytes = 6 * 1024 * 1024
    /// Text of the synthetic notice standing in for a skipped oversized file.
    static let oversizeNoticeText = "log file too large — skipped"

    private let containerURL: () -> URL?

    init(
        containerURL: @escaping () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }
    ) {
        self.containerURL = containerURL
    }

    /// The merged recent timeline for one agent. Blocking (file I/O plus the
    /// ubiquity-container resolution, which must stay off the main thread) — the
    /// view calls it from a detached task. Undownloaded iCloud placeholders get a
    /// download request and contribute nothing this pass; the next refresh picks
    /// them up.
    func loadRecent(agentName: String, agentID: UUID, days: Int = 2, now: Date = Date()) -> [AgentMirrorRecord] {
        guard let root = containerURL() else { return [] }
        let directory = root
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("AgentLogs", isDirectory: true)
            .appendingPathComponent(
                AgentLogMirror.slug(agentName: agentName, agentID: agentID), isDirectory: true
            )
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        var groups: [[AgentMirrorRecord]] = []
        for name in names {
            if let realName = Self.placeholderTarget(name),
               Self.isRecentDayFile(realName, days: days, now: now) {
                // ".<name>.icloud" — file exists in the cloud but not on disk yet.
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: directory.appendingPathComponent(realName)
                )
                continue
            }
            guard Self.isRecentDayFile(name, days: days, now: now) else { continue }
            let fileURL = directory.appendingPathComponent(name)
            if let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
               bytes > Self.maxFileBytes {
                // One synthetic notice per skipped file, so the timeline says why
                // that device's lines are missing instead of silently omitting them.
                groups.append([AgentMirrorRecord(
                    id: "oversize-\(name)",
                    kind: .notice,
                    text: Self.oversizeNoticeText,
                    timestamp: now
                )])
                continue
            }
            var content = ""
            var coordinationError: NSError?
            // Coordinated read, like the writer's coordinated append, so we never
            // race the sync daemon mid-transfer.
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: fileURL, options: [], error: &coordinationError
            ) { url in
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            groups.append(Self.parseLines(content))
        }
        return Self.merge(groups)
    }

    /// All parseable records in one file's content, in file order.
    static func parseLines(_ content: String) -> [AgentMirrorRecord] {
        content
            .components(separatedBy: "\n")
            .compactMap { AgentMirrorRecord(jsonlLine: $0) }
    }

    /// One timeline from several per-device files: ordered by timestamp, with the
    /// run/sequence pair breaking ties — entries inside one run share seconds
    /// constantly, and their sequence is the real order.
    static func merge(_ groups: [[AgentMirrorRecord]]) -> [AgentMirrorRecord] {
        groups
            .flatMap { $0 }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if $0.runID == $1.runID { return $0.sequence < $1.sequence }
                return $0.runID < $1.runID
            }
    }

    /// Whether a mirror day-file name (`yyyy-MM-dd.<deviceID8>.jsonl`, any device)
    /// falls within the recency window. Pure, for tests.
    static func isRecentDayFile(_ name: String, days: Int, now: Date) -> Bool {
        guard name.hasSuffix(".jsonl"), name.count > 10,
              let day = dayFormatter.date(from: String(name.prefix(10)))
        else { return false }
        return now.timeIntervalSince(day) < TimeInterval(days) * 86_400
    }

    /// The real file name behind an iCloud placeholder (".<name>.icloud"), or nil.
    static func placeholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Same UTC day format the writer uses for file names.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
