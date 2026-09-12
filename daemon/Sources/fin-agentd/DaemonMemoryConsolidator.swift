import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Daemon-side counterpart to `AgentRuntime.consolidateMemoriesIfDue()` (app-only, not
/// shared code): periodically folds recent episodic `/memory` entries into the single,
/// cross-agent cumulative profile at `/memory/profile`, and keeps a local cache of that
/// profile fresh for `Daemon.composedSystemPrompt` to inject synchronously (that
/// function is `nonisolated static` and reads local files, the same reason the goals
/// ledger and routing registry are local sibling files rather than live fetches).
///
/// Two independent cadences, both checked on every heartbeat-loop tick:
/// - **Cache refresh** (`cacheRefreshInterval`, ~5 min, in-memory paced): GET the
///   profile, write its content to `cacheFileURL` — cheap, keeps this daemon's own
///   prompt reasonably current with whatever anyone else last wrote, independent of
///   whether a rewrite is also due.
/// - **Compaction** (`consolidationFloor`, 24h since the profile's OWN `updatedAt` —
///   not a local stamp, so whichever client or daemon runs it first resets the clock
///   for everyone, matching "S3 as source of truth"; `consolidationPacing`, ~30 min
///   between local ATTEMPTS so a persistently failing backend doesn't retry every
///   tick): claim the cross-device lock, fetch episodic entries newer than the
///   profile's `updatedAt`, summarize with a raw (`tools: []`) completion call,
///   validate, redact, write, release the lock.
@MainActor
final class DaemonMemoryConsolidator {
    /// Mirrors `AgentWatchdog.consolidationFloor` (app-only, not in `FinAgentCore`) —
    /// duplicated rather than shared for one call site's sake; keep the two numbers in
    /// sync by hand if either changes.
    static let consolidationFloor: TimeInterval = 24 * 60 * 60
    /// Mirrors `AgentWatchdog.consolidationPacing`.
    static let consolidationPacing: TimeInterval = 30 * 60
    static let cacheRefreshInterval: TimeInterval = 5 * 60
    /// Mirrors the app's endpoint-path candidate cap (`onDevice ? 5 : 10`) — the daemon
    /// always talks to an OpenAI-compatible endpoint, never on-device.
    static let maxCandidates = 10
    static let perHitCap = 1500
    /// Mirrors `AgentRuntime.maxStoredProfileCharacters`.
    static let maxStoredProfileCharacters = 2000

    private let memory: DaemonMemoryClient
    private let cacheFileURL: URL
    private let holder: String
    private let endpointURL: String
    private let modelIdentifier: String
    private let apiKey: String?
    private let temperature: Double
    private let maxOutputTokens: Int
    private let audit: (String) -> Void
    /// Injected so tests never touch the network — defaults to the real completion
    /// call. Same seam every other daemon client here gives its transport.
    var completion: (_ instruction: String, _ input: String) async throws -> String
    /// Optional durable topology/environment facts learned from live terminal sessions
    /// (`SessionActivitySummarizer`), folded into the compaction prompt as their own
    /// section — NOT episodic conversation, so the model can tell "the user told me this"
    /// apart from "I observed this in a terminal." nil (default) = session-activity
    /// tracking is off; compact() behaves exactly as it did before this property existed.
    var sessionActivityNotesProvider: (() async -> [String])?
    /// Optional cross-device status snapshot (`DaemonDeviceStatusClient.otherDevices`),
    /// folded into the compaction prompt as its own labeled section — same "own section,
    /// own label" seam as `sessionActivityNotesProvider`. nil (default, e.g. an older
    /// build or an install with no control-plane config) = cross-device awareness off;
    /// compact() behaves byte-identically to before this property existed.
    var crossDeviceStatusProvider: (() async -> [String])?
    /// Optional live pane inventory — one line per tmux pane naming what it is
    /// doing (the pane title, which coding agents set to their current task),
    /// from `DaemonSiteClient`'s last capability scan. The freshest and most
    /// literal "what is each pane up to" signal there is; nil = not reported.
    var terminalPanesProvider: (() async -> [String])?

    private var lastCacheRefreshAt: Date?
    private var lastConsolidationAttemptAt: Date?
    private var isRunning = false

    init(
        memory: DaemonMemoryClient,
        cacheFileURL: URL,
        holder: String,
        endpointURL: String,
        modelIdentifier: String,
        apiKey: String?,
        temperature: Double,
        maxOutputTokens: Int,
        audit: @escaping (String) -> Void
    ) {
        self.memory = memory
        self.cacheFileURL = cacheFileURL
        self.holder = holder
        self.endpointURL = endpointURL
        self.modelIdentifier = modelIdentifier
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.audit = audit
        self.completion = { instruction, input in
            try await rawCompletion(
                instruction: instruction, input: input,
                endpointURL: endpointURL, model: modelIdentifier, apiKey: apiKey,
                temperature: temperature, maxOutputTokens: maxOutputTokens
            )
        }
    }

    /// Checked once per heartbeat-loop tick (~250ms); each half is separately paced, so
    /// calling this constantly is cheap. Dispatches into its own `Task` the caller
    /// doesn't await — same fire-and-forget shape as `transcript?.flushIfDue()` sitting
    /// right next to this call in the loop.
    func tickIfDue(now: Date = Date()) {
        guard !isRunning else { return }
        let cacheDue = lastCacheRefreshAt.map { now.timeIntervalSince($0) >= Self.cacheRefreshInterval } ?? true
        let attemptDue = lastConsolidationAttemptAt.map { now.timeIntervalSince($0) >= Self.consolidationPacing } ?? true
        guard cacheDue || attemptDue else { return }
        isRunning = true
        Task { [weak self] in
            await self?.run(refreshCache: cacheDue, attemptConsolidation: attemptDue)
            self?.isRunning = false
        }
    }

    /// Internal (not private) so tests can drive one pass directly and await it,
    /// bypassing `tickIfDue`'s fire-and-forget `Task` wrapping — same seam
    /// `AgentRelayApplier.applyPendingNow()` provides on the app side.
    func run(refreshCache: Bool, attemptConsolidation: Bool) async {
        guard case .found(let profile) = await memory.readProfile() else { return }
        if refreshCache {
            lastCacheRefreshAt = Date()
            try? profile.content.write(to: cacheFileURL, atomically: true, encoding: .utf8)
        }
        guard attemptConsolidation else { return }
        lastConsolidationAttemptAt = Date()
        let due = Date().timeIntervalSince(profile.updatedAt ?? .distantPast) >= Self.consolidationFloor
        guard due else { return }

        let candidates = await memory.episodicEntriesSince(profile.updatedAt, limit: Self.maxCandidates)
        guard case .found(let hits) = candidates, !hits.isEmpty else { return }

        guard case .claimed = await memory.claimProfileLock(holder: holder) else { return }
        await compact(candidates: hits)
        await memory.releaseProfileLock()
    }

    /// Everything that happens WHILE the lock is held. Always returns normally (never
    /// throws) so the caller's release is unconditional regardless of outcome.
    private func compact(candidates hits: [AgentRecallHit]) async {
        // Re-read now that the lock is held: another runner may have compacted while
        // this one was still fetching candidates or waiting on the claim.
        guard case .found(let profile) = await memory.readProfile() else { return }

        // Shared contract with the app's compactor (`ProfileCompaction`): every
        // input dated, observations labeled apart from conversation, current work
        // time-boxed in the instruction, and pruning allowed by the guard.
        var observed: [ProfileCompaction.ObservedSection] = []
        if let terminalPanesProvider {
            observed.append(.init(title: "Terminal panes right now (observed)", lines: await terminalPanesProvider()))
        }
        if let sessionActivityNotesProvider {
            observed.append(.init(
                title: "Session activity (from live terminal sessions Fin tracks)",
                lines: await sessionActivityNotesProvider()
            ))
        }
        if let crossDeviceStatusProvider {
            observed.append(.init(title: "Other devices right now", lines: await crossDeviceStatusProvider()))
        }
        let input = ProfileCompaction.input(
            currentProfile: profile.content,
            observed: observed,
            conversations: hits.map { .init(title: $0.title, date: $0.updatedAt, content: $0.content) },
            perConversationCap: Self.perHitCap
        )
        let instruction = ProfileCompaction.instruction()

        do {
            let text = try await completion(instruction, input)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.acceptableProfile(trimmed, replacing: profile.content) else {
                audit("[memory] profile compaction skipped: model returned unusable text")
                return
            }
            let bounded = String(MemoryRedactor.redact(trimmed).prefix(Self.maxStoredProfileCharacters))
            guard case .saved = await memory.writeProfile(bounded) else {
                audit("[memory] profile compaction failed: the control plane rejected the write")
                return
            }
            audit("[memory] profile compaction: merged \(hits.count) conversation(s) (\(bounded.count) chars)")
        } catch {
            audit("[memory] profile compaction failed: \(error.localizedDescription)")
        }
    }

    /// Mirrors `AgentRuntime.acceptableConsolidatedProfile` (app-only): guards the
    /// wholesale replacement against a refusal, an echo of the "(none)" placeholder
    /// text the prompt itself injects, or a drastic shrink. Omits the app's
    /// `AppleOnDeviceBackend.looksDegenerate` check — that guards a small on-device
    /// model's failure mode the daemon never hits (it always talks to an
    /// OpenAI-compatible endpoint).
    nonisolated static func acceptableProfile(_ candidate: String, replacing existing: String) -> Bool {
        ProfileCompaction.acceptable(candidate, replacing: existing)
    }
}
