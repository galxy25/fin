import Foundation
import os

/// Mirrors the agent audit trail into the app's iCloud Drive container as JSONL, so a
/// supervisor with filesystem access on another device (a Claude Code session on the
/// Mac, reading ~/Library/Mobile Documents) can see what a wedged agent saw. The
/// SwiftData trail itself stays local-only; this is a parallel, file-shaped copy.
///
/// Layout: `Documents/AgentLogs/<agent-slug>/<yyyy-MM-dd>.<deviceID8>.jsonl` — one
/// folder per agent, one append-only file per UTC day *per device*, greppable with
/// nothing but the shell.
///
/// Every mirrored line's `text` and `tool_arguments` pass through `MemoryRedactor`
/// first: unlike the local store, these files leave the device, and they quote the
/// same raw terminal output that keeps `AgentLogEntry` out of CloudKit — the same
/// deliberate residual risk documented on `AgentMemory`. Mirroring defaults ON — the
/// feature exists precisely so a supervisor can read the logs without setup — which
/// deliberately relaxes `AgentLogEntry`'s local-only stance behind that redaction
/// plus the explicit per-agent toggle disclosed in the agent editor.
final class AgentLogMirror: @unchecked Sendable {
    static let shared = AgentLogMirror(ubiquityBacked: true)

    private static let logger = Logger(subsystem: "dev.levischoen.fin", category: "AgentLogMirror")

    /// Day files older than this are deleted by the per-launch sweep.
    static let retentionDays = 14
    /// Soft cap per day file; once exceeded the file gets one truncation marker and no
    /// further appends for the rest of its UTC day.
    static let defaultSoftCapBytes = 5 * 1024 * 1024
    static let truncationMarker = "[mirror truncated for today]"
    /// How long a "iCloud Drive is off" answer is trusted before re-asking, so a user
    /// who enables iCloud mid-run gets a live mirror without relaunching.
    private static let nilRootRetryInterval: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "dev.levischoen.fin.AgentLogMirror", qos: .utility)
    private let containerURL: () -> URL?
    /// True only for the shared production instance targeting the real ubiquity
    /// container. Test-constructed mirrors write to injected temp directories.
    private let ubiquityBacked: Bool
    private let deviceID8: String
    private let softCapBytes: Int
    /// `.some(nil)` means iCloud Drive is off; retried after `nilRootRetryInterval`.
    private var cachedRoot: URL??
    private var lastNilResolutionAt: Date?
    /// Agent directories already retention-swept this launch.
    private var sweptDirectories: Set<String> = []
    /// Day files that hit the soft cap this launch; appends to them are dropped.
    private var truncatedPaths: Set<String> = []

    init(
        containerURL: @escaping () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        },
        deviceID8: String = DeviceIdentity.short,
        softCapBytes: Int = AgentLogMirror.defaultSoftCapBytes,
        ubiquityBacked: Bool = false
    ) {
        self.containerURL = containerURL
        self.ubiquityBacked = ubiquityBacked
        self.deviceID8 = deviceID8
        self.softCapBytes = softCapBytes
        // An iCloud sign-out/switch invalidates every previously-resolved container
        // URL; without this, appends would keep landing in the previous identity's
        // (now dead or foreign) container.
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.cachedRoot = nil
                self.lastNilResolutionAt = nil
            }
        }
    }

    /// Fire-and-forget; failures are logged, never surfaced — a sync file problem must
    /// not break the app.
    func append(_ record: AgentLogRecord) {
        // Test processes must never write to the real ubiquity mirror: render and
        // lifecycle tests boot real app wiring through the shared instance, and
        // their audit lines were observed polluting the production agent's iCloud
        // log directory. Test-constructed mirrors (temp directories) still write.
        if ubiquityBacked,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        queue.async { self.write(record) }
    }

    /// Blocks until every append enqueued so far has been written. Test hook.
    func flush() {
        queue.sync {}
    }

    private func write(_ record: AgentLogRecord) {
        guard let root = resolveRoot() else { return }

        guard let line = Self.line(for: record) else {
            Self.logger.error("failed to encode mirror line for run \(record.runID)")
            return
        }
        let fileURL = Self.fileURL(root: root, record: record, date: Date(), deviceID8: deviceID8)
        sweepExpiredFilesIfNeeded(in: fileURL.deletingLastPathComponent())
        guard !truncatedPaths.contains(fileURL.path) else { return }

        // Coordinated write so appends interleave correctly with the iCloud sync daemon.
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: .forMerging, error: &coordinationError
        ) { url in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    // A file that exists in the cloud but not on disk is only a
                    // ".<name>.icloud" placeholder; creating a fresh file at the real
                    // path would fork away its earlier content. Rare with per-device
                    // names (this device's own file was evicted), but never clobber:
                    // request the download and drop this line instead.
                    let placeholder = url.deletingLastPathComponent()
                        .appendingPathComponent(".\(url.lastPathComponent).icloud")
                    if FileManager.default.fileExists(atPath: placeholder.path) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                        Self.logger.warning("day file is an undownloaded iCloud placeholder; skipping mirror line")
                        return
                    }
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.size] as? Int } ?? 0
                if size >= self.softCapBytes {
                    self.truncatedPaths.insert(url.path)
                    // Tail check so a relaunch against an already-truncated file
                    // doesn't stack a second marker.
                    if !Self.tailContainsTruncationMarker(url, fileSize: size) {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data((Self.truncationMarker + "\n").utf8))
                    }
                    return
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                Self.logger.error("mirror append failed: \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            Self.logger.error("mirror coordination failed: \(coordinationError.localizedDescription)")
        }
    }

    /// Resolves (and caches) the ubiquity container root on the mirror's queue —
    /// url(forUbiquityContainerIdentifier:) must be called off the main thread.
    private func resolveRoot() -> URL? {
        if let cached = cachedRoot {
            if let cached { return cached }
            // Cached "off": stay dark until the retry window elapses.
            if let last = lastNilResolutionAt,
               Date().timeIntervalSince(last) < Self.nilRootRetryInterval {
                return nil
            }
        }
        let resolved = containerURL()
        cachedRoot = .some(resolved)
        if resolved == nil {
            lastNilResolutionAt = Date()
            Self.logger.warning("iCloud container unavailable; log mirror is dark (will re-check)")
        } else {
            lastNilResolutionAt = nil
        }
        return resolved
    }

    /// Deletes day files past retention. Once per agent directory per launch.
    private func sweepExpiredFilesIfNeeded(in directory: URL) {
        guard !sweptDirectories.contains(directory.path) else { return }
        sweptDirectories.insert(directory.path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where Self.isExpiredDayFile(name, asOf: Date()) {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: directory.appendingPathComponent(name),
                options: .forDeleting, error: &coordinationError
            ) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Whether a day-file name is past retention. Unrecognized names never expire —
    /// deleting only what this mirror provably wrote is the fail-safe direction.
    static func isExpiredDayFile(_ fileName: String, asOf now: Date) -> Bool {
        guard fileName.hasSuffix(".jsonl"),
              let day = dayFormatter.date(from: String(fileName.prefix(10)))
        else { return false }
        return now.timeIntervalSince(day) > TimeInterval(retentionDays) * 86_400
    }

    private static func tailContainsTruncationMarker(_ url: URL, fileSize: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let tailLength = truncationMarker.utf8.count + 2
        try? handle.seek(toOffset: UInt64(max(0, fileSize - tailLength)))
        guard let data = try? handle.readToEnd() else { return false }
        return String(decoding: data, as: UTF8.self).contains(truncationMarker)
    }

    /// Same line shape as the local trail's `AgentLogEntry.jsonlLine()`, built from a
    /// transient (never-inserted) entry with the two free-text fields redacted.
    static func line(for record: AgentLogRecord) -> String? {
        let entry = AgentLogEntry(record: record)
        entry.text = MemoryRedactor.redact(entry.text)
        entry.toolArguments = entry.toolArguments.map(MemoryRedactor.redact)
        return entry.jsonlLine()
    }

    /// `agent-name-slug-<agentID prefix>` — the ID prefix keeps two agents with the
    /// same name from interleaving their trails.
    static func slug(agentName: String, agentID: UUID) -> String {
        let collapsed = agentName.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        let name = collapsed.isEmpty ? "agent" : collapsed
        return "\(name)-\(agentID.uuidString.lowercased().prefix(8))"
    }

    /// The device ID in the name is the anti-fork invariant: each device only ever
    /// appends to its own file, so iCloud never has two writers whose divergent copies
    /// it would "resolve" by discarding one — conflicts are impossible by construction.
    /// The supervisor greps the whole directory, so several files per day is fine.
    static func fileURL(root: URL, record: AgentLogRecord, date: Date, deviceID8: String) -> URL {
        root
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("AgentLogs", isDirectory: true)
            .appendingPathComponent(
                slug(agentName: record.agentName, agentID: record.agentID), isDirectory: true
            )
            .appendingPathComponent(dayFormatter.string(from: date) + ".\(deviceID8).jsonl")
    }

    /// UTC so a device's day boundary is the same everywhere and filenames sort by time.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
