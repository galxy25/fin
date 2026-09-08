// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// THE WRITE HALF OF THE PRIVATE-SOCKET DESIGN — and a real change to the threat model
// `TmuxSessionRead.swift` describes, not an extension of it. Reading another session was
// judged safe because it is read-only: nothing this agent does can reach out and touch
// somebody else's terminal. `send_session` is the deliberate, owner-approved exception —
// real keystrokes, typed into a pane this process does not otherwise control, so that
// two Claude Code sessions (this one and, say, another project's) can actually talk to
// each other instead of Fin only ever being able to watch.
//
// Because the risk is real — the wrong target gets somebody's literal keystrokes, not
// just a wrong-but-harmless read — this file is deliberately MORE restrictive than
// `TmuxSessionRead`, not equally permissive:
//   - No bare-name resolution. `TmuxSessionResolution`'s fuzzy/classification matching
//     is for READING, where a wrong guess costs a wasted look. Sending requires an
//     EXPLICIT `session:window` target, so the model has already positively identified
//     the destination (normally via `read_session`, which DOES resolve a bare name) —
//     `validateTarget` refuses anything without a colon outright, on purpose.
//   - The text itself is bounded (`maxTextLength`) — a runaway or malicious wall of text
//     is not "a message", and typing it into somebody else's pane is not reversible.
//   - Delivery still goes through the same fixed-argv, validated-name discipline as
//     every other tmux command this daemon issues: one word (the target) is the model's,
//     everything else is fixed, and `-l --` keeps the free-form message text from ever
//     being read as a `send-keys` flag (a text starting with `-` is exactly the shape
//     that would otherwise misparse — verified live against tmux on this machine before
//     writing this file, not assumed from documentation).
public enum TmuxSessionSend {

    public static let maxTextLength = 2000

    /// No wait by default: `send_session` without `await_output_seconds` sends and
    /// returns immediately, honestly reporting only that the keystrokes went in. A model
    /// that wants to see what followed asks for it explicitly.
    public static let defaultAwaitSeconds = 0
    /// A real reply from another agent can take real time to think — this is a
    /// deliberately generous ceiling compared to `send_input`'s own-terminal wait, since
    /// polling a REMOTE pane every second is the only way to observe it at all (there is
    /// no live event stream the way there is for this daemon's own PTY).
    public static let maxAwaitSeconds = 120
    public static let pollInterval: TimeInterval = 1.0
    /// The pane counts as settled once this many consecutive polls returned identical
    /// content — a coarse approximation of `AgentTurnLogic`'s own-terminal settle window,
    /// the best available without a live stream for somebody else's pane.
    public static let quietPollsToSettle = 2

    public static func clampAwaitSeconds(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultAwaitSeconds }
        return min(requested, maxAwaitSeconds)
    }

    /// Validates a model-supplied SEND target. Stricter than `TmuxSessionRead.validate`:
    /// that function alone would accept a bare session name, but a bare name here is
    /// exactly the ambiguity `read_session`'s bare-name resolver exists to absorb for
    /// READS — sending has no such absorber, and must not silently pick "the active
    /// window" the way the OLD read path used to. A target must name both.
    public static func validateTarget(name raw: String) -> String? {
        guard let validated = TmuxSessionRead.validate(name: raw), validated.contains(":") else {
            return nil
        }
        return validated
    }

    public static func targetRejectionMessage(for raw: String) -> String {
        "Error: send_session's \"session\" must be an EXACT \"session:window\" target — "
            + "not a bare name, even one read_session would resolve. \"\(TmuxSessionRead.summarize(raw))\" "
            + "is not one. Call read_session first (a bare name is fine there) to find and confirm "
            + "the exact window, then send to that same \"session:window\" target."
    }

    /// REJECTS an embedded newline — this is not cosmetic. `sendTextArguments` sends
    /// `text` through `send-keys -l`, which delivers it to the target pty as literal
    /// BYTES, not a queued string `sendEnterArguments`'s later, separate Enter then
    /// submits as a whole: an embedded `\n` (or `\r`) IS itself a real newline byte at
    /// the pty layer, which the target's own line discipline treats exactly like a
    /// keypress — submitting everything before it immediately, with zero involvement
    /// from the deliberate Enter call. Confirmed live against real tmux: `send-keys -l`
    /// with `"line one\nline two"` ran `line one` and printed its output before any
    /// Enter command was ever issued. So "one send_session call, one message, submitted
    /// once" is only true for single-line text — multi-line content must be rejected
    /// here, not silently fragmented into N separately-submitted lines (or, worse,
    /// treated as N attacker-controlled commands if the text ever originated from
    /// something this agent read rather than composed itself).
    public static func validateText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTextLength else { return nil }
        // unicodeScalars, NOT a `Character`/grapheme-cluster `contains` check — CR+LF is
        // ONE extended grapheme cluster in Swift's String model (Unicode's own rule), so
        // `trimmed.contains("\n")` and `.contains("\r")` each independently evaluate to
        // FALSE against a string whose only line break is "\r\n": neither needle equals
        // that combined cluster as a Character. A Windows-style-newline message would
        // have sailed straight through the very check meant to stop it — caught by a
        // test that actually exercised "\r\n" instead of "\n" and "\r" separately.
        guard !trimmed.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        return trimmed
    }

    public static func textRejectionMessage(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Error: send_session's \"text\" was empty after trimming — nothing to send."
        }
        if trimmed.count > maxTextLength {
            return "Error: send_session's \"text\" is \(trimmed.count) characters, over the "
                + "\(maxTextLength)-character limit. Send a shorter message."
        }
        return "Error: send_session's \"text\" contains a newline. One send_session call submits "
            + "ONE line — a newline mid-text lands on the target pty as a real Enter and submits "
            + "everything before it immediately, before your intended Enter ever runs. Send it as "
            + "separate send_session calls, one line each, or rephrase as one line."
    }

    // MARK: - The fixed argv

    /// `-l` forces literal interpretation (no key-name lookup, so "Enter" or "C-c" typed
    /// as MESSAGE TEXT lands as those literal characters, not a keypress); `--` ends
    /// option parsing before the text, so a message beginning with `-` cannot be misread
    /// as a `send-keys` flag — confirmed against real tmux, not assumed.
    public static func sendTextArguments(session: String, text: String) -> [String] {
        ["tmux", "send-keys", "-l", "-t", session, "--", text]
    }

    /// A SEPARATE command, deliberately: "Enter" here is a real key name (no `-l`), sent
    /// only after the literal text above has landed, so the two can never be confused
    /// with each other regardless of what the message text contains.
    public static func sendEnterArguments(session: String) -> [String] {
        ["tmux", "send-keys", "-t", session, "Enter"]
    }
}

/// What a runner's `send_session` hook hands back. Mirrors `AgentReadSessionOutcome`'s
/// honesty rule: the tool reports what really happened, never dressing up "the text was
/// typed" as "the other agent replied," and never claiming a wait that wasn't requested.
public enum AgentSendSessionOutcome: Equatable, Sendable {
    /// Both the text and the Enter keypress were sent. `after` says whether — and how —
    /// the caller observed what followed.
    case sent(after: SendSessionAfter)
    /// The send did not fully happen — a transport/tmux failure on either the text or
    /// the Enter keypress. Text typed but never submitted is not "sent": this case
    /// covers that too.
    case failed(String)
}

/// The three genuinely different stories `send_session`'s wait can end with — kept apart
/// so none of them is misreported as another. Collapsing `.allAttemptsFailed` into a
/// plain `nil` (indistinguishable from `.notWaited`) was a real bug caught in review:
/// the model would have no way to tell "you didn't ask me to wait" from "I tried the
/// whole budget and every single read of that pane failed."
public enum SendSessionAfter: Equatable, Sendable {
    /// No wait was requested (`awaitSeconds` was 0) — the model didn't ask to see what
    /// followed, so there is nothing to report either way.
    case notWaited
    /// The pane's content once it settled or the wait budget ran out — exactly the same
    /// untrusted-pane-content shape `read_session` returns, redacted identically by the
    /// caller before this case is ever constructed.
    case observed(String)
    /// A wait WAS requested, but every attempt to read the pane back failed for the
    /// entire budget. The send itself is unaffected by this — that outcome is still
    /// `.sent`, honestly — but the model must be told the wait could not confirm
    /// anything, not left to assume nothing was requested.
    case allAttemptsFailed
}
