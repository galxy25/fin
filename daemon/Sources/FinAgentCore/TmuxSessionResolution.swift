// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// THE FALLBACK HALF OF read_session's TARGETING.
//
// `TmuxSessionRead` trusts an explicit `session:window` target literally — the model was
// precise, so the daemon is too. But a BARE name (no colon) is ambiguous the moment a
// session hosts more than one window: `tmux capture-pane -t main` silently answers with
// whatever window happens to be ACTIVE, which is often not the one the requester meant.
// That is not a validation failure — it is a wrong-but-successful read, and nothing in
// `TmuxSessionRead` catches it, because it never sees a tmux error to react to.
//
// This file resolves a bare name to a specific window BEFORE that ambiguity is allowed to
// silently pick one. It works in two tiers:
//   1. STRUCTURAL — compare the name against every window's own name and the last path
//      component of its cwd (the repo directory a Claude Code session is almost always
//      running from). Cheap, deterministic, no network call, and everything it touches
//      comes from tmux's own listing, never a shell.
//   2. CLASSIFICATION — when structure alone does not settle on one answer, sample a
//      short capture from each remaining candidate and ask the model's own endpoint
//      which one the requester meant. This is the "read the room" fallback: content is
//      often more diagnostic than a label ("finclaude" is a name; a pane full of Swift
//      compiler output is evidence).
//
// Everything below is pure — window parsing, matching, prompt text, response parsing —
// so all of it is unit-testable without a live tmux server or a live model. The daemon
// (`Daemon.readSession`) is the only place that actually runs a command or calls the
// endpoint; this file only decides WHAT it should run and HOW to read the answer.
public enum TmuxSessionResolution {

    /// One row of `tmux list-windows -a`: a window on the DEFAULT socket, wherever it
    /// lives. `index` (not `name`) is what `target(for:)` builds the resolved argument
    /// from — a window's name can be almost anything tmux allows (including characters
    /// `TmuxSessionRead.validate` would refuse), but its index is always a small integer.
    public struct WindowInfo: Equatable, Sendable {
        public let session: String
        public let index: Int
        public let name: String
        public let cwd: String
        public let active: Bool

        public init(session: String, index: Int, name: String, cwd: String, active: Bool) {
            self.session = session
            self.index = index
            self.name = name
            self.cwd = cwd
            self.active = active
        }
    }

    /// How a candidate pool was assembled — carried through so the caller can decide
    /// whether a single survivor is confident enough to read without confirming it.
    public enum MatchTier: Equatable, Sendable {
        /// The window's own name, or its cwd's directory name, is EXACTLY the requested
        /// name once both sides are normalized. The strongest signal this file has.
        case exact
        /// A looser containment match — the requested name appears inside, or contains,
        /// a window's normalized name or directory. Real, but not proof: "fin" is a
        /// substring of "infinite" too. A tier-`.fuzzy` pool of one is still confirmed
        /// by classification before it is read.
        case fuzzy
        /// The requested name IS a live tmux session (case-sensitive, tmux's own rule),
        /// and none of its windows matched by name or directory — so every window that
        /// session owns is offered up rather than guessing which one is "current".
        case sessionMembership
    }

    // MARK: - Enumerating windows

    /// Fixed argv, no model input at all: every window on the default socket, one line
    /// each. This is what lets a bare name be resolved against windows that were never
    /// otherwise mentioned — the model only ever supplies the word being matched against.
    public static func listWindowsArguments() -> [String] {
        ["tmux", "list-windows", "-a", "-F", listWindowsFormat]
    }

    static let listWindowsFormat =
        "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_current_path}\t#{window_active}"

    /// Parses `listWindowsArguments()`'s output. A line that doesn't have exactly the
    /// expected shape is skipped rather than guessed at — a short read should mean fewer
    /// candidates, never a malformed one.
    public static func parseWindows(_ output: String) -> [WindowInfo] {
        output.components(separatedBy: "\n").compactMap { line -> WindowInfo? in
            guard !line.isEmpty else { return nil }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 5, let index = Int(fields[1]) else { return nil }
            return WindowInfo(
                session: fields[0], index: index, name: fields[2],
                cwd: fields[3], active: fields[4] == "1"
            )
        }
    }

    /// The resolved argument `TmuxSessionRead.captureArguments` should target. Built from
    /// `session` and `index` ONLY — never `name`, which is free-form tmux text and may
    /// contain characters `TmuxSessionRead.validate` would refuse. The caller still
    /// validates this string before using it (belt and braces: a session named something
    /// pathological should be unreadable, not silently let through because we built the
    /// string ourselves).
    public static func target(for window: WindowInfo) -> String {
        "\(window.session):\(window.index)"
    }

    // MARK: - Structural matching

    /// Lowercased letters-and-digits only. Punctuation, spaces and case are exactly the
    /// axes dictation and a typed guess are most likely to differ on — "fin-claude",
    /// "Fin Claude" and "finclaude" all collapse to the same string.
    static func normalize(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Minimum normalized length either side of a fuzzy comparison must clear before it
    /// is trusted at all — below this, "fin" ⊂ "infinite" and "ci" ⊂ "citadel" produce
    /// more noise than signal.
    static let minimumFuzzyLength = 3

    /// The best candidate pool this file can build from structure alone, and which tier
    /// produced it. `windows` is every window on the machine (from `parseWindows`);
    /// `requested` is the model's already-`TmuxSessionRead.validate`-passed name.
    ///
    /// Priority, most confident first: an exact normalized match beats a fuzzy one, which
    /// beats "windows this literal session owns" — because the caller only reaches for
    /// membership when neither name nor directory said anything, so it is the weakest
    /// signal, not a fallback of last resort AFTER classification fails.
    public static func candidates(
        for requested: String, in windows: [WindowInfo]
    ) -> (pool: [WindowInfo], tier: MatchTier)? {
        let needle = normalize(requested)
        guard !needle.isEmpty else { return nil }

        let exact = windows.filter { w in
            normalize(w.name) == needle || normalize(lastPathComponent(w.cwd)) == needle
        }
        if !exact.isEmpty { return (exact, .exact) }

        if needle.count >= minimumFuzzyLength {
            let fuzzy = windows.filter { w in
                let name = normalize(w.name)
                let dir = normalize(lastPathComponent(w.cwd))
                return (name.count >= minimumFuzzyLength
                        && (name.contains(needle) || needle.contains(name)))
                    || (dir.count >= minimumFuzzyLength
                        && (dir.contains(needle) || needle.contains(dir)))
            }
            if !fuzzy.isEmpty { return (fuzzy, .fuzzy) }
        }

        let owned = windows.filter { $0.session == requested }
        if !owned.isEmpty { return (owned, .sessionMembership) }

        return nil
    }

    // MARK: - Classification fallback

    /// How many windows sample-and-classify will ever spend a capture-pane call (and a
    /// slot in the classification prompt) on. A dev machine rarely has more live windows
    /// than this; the cap exists so a pathological number of tmux windows cannot turn one
    /// tool call into dozens of exec round trips plus an oversized prompt.
    public static let maxClassificationCandidates = 8

    /// Lines sampled per candidate for classification — enough to see what a pane is
    /// doing, far short of `TmuxSessionRead.defaultLines`: this text exists only to help
    /// PICK a window, not to answer the request, and the real capture (at the requester's
    /// own line count) runs afterward against whichever one wins.
    public static let sampleLines = 20

    public static let classificationSystemPrompt = """
        You are picking which terminal window a user meant, from a short reference name and \
        a content sample of each candidate. Reply with ONLY a single integer: the number of \
        the single best-matching candidate, or 0 if none of them plausibly match. No words, \
        no punctuation, no explanation — the number alone.
        """

    /// Frames every sample the same untrusted way `TmuxSessionRead.frameCapture` does: a
    /// pane's content is picked BY this prompt, but it still originates from somebody
    /// else's terminal, and text in it is data to compare against, never an instruction
    /// to this classification call.
    public static func classificationUserPrompt(
        requested: String, samples: [(window: WindowInfo, text: String)]
    ) -> String {
        var lines = [
            "Requested name: \"\(requested)\"",
            "Candidates:",
        ]
        for (offset, entry) in samples.enumerated() {
            let n = offset + 1
            // A window's name and cwd are exactly as untrusted as its content — anyone
            // who can rename a window on the default socket can put forged fence markers
            // in either — so both are sanitized here too, not just `entry.text`.
            let rawLabel = entry.window.name.isEmpty ? "(unnamed)" : entry.window.name
            let label = sanitizedForPrompt(rawLabel)
            let cwd = sanitizedForPrompt(entry.window.cwd)
            lines.append("")
            lines.append("[\(n)] \(target(for: entry.window)) — window \"\(label)\", "
                + "directory \"\(cwd)\"")
            lines.append(TmuxSessionRead.beginMarker)
            lines.append(sanitizedForPrompt(entry.text))
            lines.append(TmuxSessionRead.endMarker)
        }
        lines.append("")
        lines.append("Which candidate number best matches \"\(requested)\"? Reply with the "
            + "number alone, or 0 if none do.")
        return lines.joined(separator: "\n")
    }

    /// A window's own name and cwd, safe to interpolate into text a model reads directly
    /// — used wherever a candidate is DESCRIBED (a refusal message, a log line) rather
    /// than sampled into the classification prompt (which sanitizes inline; see
    /// `classificationUserPrompt`). Same defense, same reason: a window's name is exactly
    /// as untrusted as its content, and a runner's own honest report about a resolution
    /// attempt must not be forgeable by whatever renamed the window.
    public static func describeCandidate(_ window: WindowInfo) -> String {
        let label = window.name.isEmpty ? "(unnamed)" : sanitizedForPrompt(window.name)
        return "\(target(for: window)) (\"\(label)\", \(sanitizedForPrompt(window.cwd)))"
    }

    /// Strips any forged fence out of a sample before it goes into the prompt — the same
    /// defense `TmuxSessionRead.fenced` applies to what the model itself reads, applied
    /// here too since this text reaches an inference call even though it is never shown
    /// to the requesting model directly.
    static func sanitizedForPrompt(_ text: String) -> String {
        text
            .replacingOccurrences(of: TmuxSessionRead.beginMarker, with: "----- (marker removed) -----")
            .replacingOccurrences(of: TmuxSessionRead.endMarker, with: "----- (marker removed) -----")
    }

    /// Parses the classifier's reply into a zero-based index into `samples`, or nil for
    /// "no confident match" — 0, an out-of-range number, or anything that isn't a number
    /// at all. Tolerant of surrounding whitespace or a stray period a model adds despite
    /// the system prompt; NOT tolerant of extra prose, which reads as the model hedging
    /// rather than answering, and a hedge is not a pick.
    public static func parseClassificationIndex(_ raw: String, candidateCount: Int) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let n = Int(trimmed), n >= 1, n <= candidateCount else { return nil }
        return n - 1
    }

    // MARK: - Making the classification call

    /// The actual inference call, wrapping `AgentEndpointClient`/`AgentMessage` — both
    /// internal to this module — behind one public function, so `fin-agentd` (a
    /// different SPM target) never needs those types widened just for this. Zero
    /// temperature, a tiny output cap, no tools: this picks ONE of a short list, it does
    /// not converse. Returns nil on any transport/HTTP failure or an unparseable/"none of
    /// these" reply — the caller's job, not this function's, to decide what "nil" means.
    public static func classify(
        requested: String,
        samples: [(window: WindowInfo, text: String)],
        endpointURL: String,
        model: String,
        apiKey: String?,
        onFailure: (String) -> Void = { _ in }
    ) async -> Int? {
        let client = AgentEndpointClient(
            baseURL: endpointURL, model: model, apiKey: apiKey,
            temperature: 0, maxOutputTokens: 16
        )
        let messages = [
            AgentMessage(role: .system, text: classificationSystemPrompt),
            AgentMessage(role: .user, text: classificationUserPrompt(requested: requested, samples: samples)),
        ]
        do {
            let completion = try await client.complete(messages: messages, tools: [])
            return parseClassificationIndex(completion.text, candidateCount: samples.count)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            onFailure(reason)
            return nil
        }
    }
}
