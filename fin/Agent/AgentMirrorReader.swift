import Foundation
import os

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

    /// See `MirrorRecords.parseLines` — kept here so existing call sites read the same.
    static func parseLines(_ content: String) -> [AgentMirrorRecord] { MirrorRecords.parseLines(content) }

    /// See `MirrorRecords.merge`.
    static func merge(_ groups: [[AgentMirrorRecord]]) -> [AgentMirrorRecord] { MirrorRecords.merge(groups) }

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
