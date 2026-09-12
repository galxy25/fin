import Foundation
import FinAgentCore

/// Per-coding-agent-session "what is this working on and how" notes — the
/// terminal-scraping half of the request, built to `DaemonMemoryConsolidator`'s exact
/// pattern: injectable completion closure, injectable audit closure, redact-then-persist,
/// an acceptance guard that is the real decision-maker (not the prompt).
///
/// Scope: only registry entries with `kind == "coding-agent"` AND a known
/// `agentPaneTarget` — set exclusively by `SessionInventoryScanner.observeDiscoveredSession`.
/// A plain shell has nothing to summarize (that's the whole point of
/// `TmuxSessionInventory.kind`'s allowlist check), and a hand-registered coding-agent
/// session with no discovered pane target is left untouched — auto-summarizing a
/// session the user registered by hand for HIS OWN reasons is not this feature's job.
@MainActor
final class SessionActivitySummarizer {
    nonisolated static let defaultIntervalSeconds: TimeInterval = 15 * 60
    /// Raw captured pane text is cut to this many characters BEFORE redaction — one
    /// screenful of scrollback, not a whole session's history. Mirrors
    /// `DaemonMemoryConsolidator.perHitCap`'s role.
    static let captureCharacterCap = 4000
    /// The stored note's ceiling. Small on purpose: several sessions' notes must fit
    /// inside the profile's own 2000-char total alongside conversation hits.
    static let maxNoteCharacters = 280
    nonisolated static let defaultCaptureLines = 200

    private let registry: SessionRoutingRegistry
    private let intervalSeconds: TimeInterval
    private let captureLines: Int
    private let audit: (String) -> Void

    /// Injected so tests never touch the network — defaults to the real completion call.
    var completion: (_ instruction: String, _ input: String) async throws -> String
    /// Injected so tests never touch tmux/SSH — defaults to the real fixed-argv capture
    /// over the daemon's existing exec channel (same mechanism `read_session` uses).
    var capturePane: (_ paneTarget: String) async throws -> String

    private var lastRunAt: Date?
    private var isRunning = false

    init(
        registry: SessionRoutingRegistry,
        session: HeadlessTerminalSession,
        intervalSeconds: TimeInterval = SessionActivitySummarizer.defaultIntervalSeconds,
        captureLines: Int = SessionActivitySummarizer.defaultCaptureLines,
        endpointURL: String, modelIdentifier: String, apiKey: String?,
        temperature: Double, maxOutputTokens: Int,
        audit: @escaping (String) -> Void
    ) {
        self.registry = registry
        self.intervalSeconds = intervalSeconds
        self.captureLines = captureLines
        self.audit = audit
        self.completion = { instruction, input in
            try await rawCompletion(
                instruction: instruction, input: input,
                endpointURL: endpointURL, model: modelIdentifier, apiKey: apiKey,
                temperature: temperature, maxOutputTokens: maxOutputTokens
            )
        }
        self.capturePane = { paneTarget in
            let commandLine = TmuxSessionRead.commandLine(
                TmuxSessionRead.captureArguments(session: paneTarget, lines: captureLines)
            )
            let result = try await session.runFixedCommand(
                commandLine, maxResponseBytes: TmuxSessionRead.maxResponseBytes
            )
            return result.output
        }
    }

    func tickIfDue(now: Date = Date()) {
        guard !isRunning else { return }
        let due = lastRunAt.map { now.timeIntervalSince($0) >= intervalSeconds } ?? true
        guard due else { return }
        isRunning = true
        Task { [weak self] in
            await self?.run()
            self?.isRunning = false
        }
    }

    /// Internal so tests can await one pass directly, bypassing the fire-and-forget Task.
    func run() async {
        lastRunAt = Date()
        let sessions = await registry.document.sessions.filter {
            $0.kind == "coding-agent" && $0.agentPaneTarget != nil
        }
        for entry in sessions {
            await summarize(entry)
        }
    }

    private func summarize(_ entry: SessionRegistration) async {
        guard let paneTarget = entry.agentPaneTarget else { return }
        let raw: String
        do {
            raw = try await capturePane(paneTarget)
        } catch {
            audit("[session-activity] capture failed for \"\(entry.session)\": \(error.localizedDescription)")
            return
        }
        let capped = String(raw.suffix(Self.captureCharacterCap))
        let redacted = MemoryRedactor.redact(capped)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let previous = (entry.activityNote?.isEmpty == false) ? entry.activityNote! : "(none)"
        let input = "Session \"\(entry.session)\" (kind: coding-agent). Previous note: \(previous)"
            + "\n\nRecent terminal activity (input and output, oldest first):\n\(redacted)"

        do {
            let text = try await completion(Self.instructionText, input)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.acceptableNote(trimmed) else {
                audit("[session-activity] note skipped for \"\(entry.session)\": model returned unusable text")
                return
            }
            let bounded = String(MemoryRedactor.redact(trimmed).prefix(Self.maxNoteCharacters))
            try await registry.setActivityNote(bounded, forSession: entry.session)
            audit("[session-activity] \"\(entry.session)\": \(bounded)")
        } catch {
            audit("[session-activity] completion failed for \"\(entry.session)\": \(error.localizedDescription)")
        }
    }

    static let instructionText =
        "In one or two short sentences, summarize what this terminal session is " +
        "currently working on and HOW — the concrete task and approach, not a " +
        "transcript. Never mention hostnames, usernames, IP addresses, file paths, " +
        "or literal shell commands — describe the work, not the machinery. If the " +
        "session looks idle or the content is unclear, say that plainly instead of " +
        "guessing. Keep under 280 characters. Output only the summary."

    /// The real decision-maker, not the instruction — a prompt rule is advisory
    /// (same principle stated elsewhere in this codebase, e.g. `SessionRouting.swift`'s
    /// own routing-decision comments). Mirrors `DaemonMemoryConsolidator.acceptableProfile`'s
    /// shape (length floor + rejection set) but checks for LEAK shape, since this is the
    /// one place raw terminal content is one bad model answer away from the profile text
    /// a person reads.
    nonisolated static func acceptableNote(_ candidate: String) -> Bool {
        guard candidate.count >= 10 else { return false }
        let lowered = candidate.lowercased()
        let leakMarkers = ["/users/", "/home/", "~/", "ssh ", "http://", "https://", "127.0.0.1"]
        if leakMarkers.contains(where: lowered.contains) { return false }
        if candidate.range(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }
}
