// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// The pure decision logic of one agent↔terminal exchange, extracted from the app's
/// `AgentRuntime` so the headless `AgentTurnEngine` drives the exact same behavior.
/// `AgentRuntime` forwards to everything here — there is one implementation of each rule.
/// Public (with mostly-internal members) so the daemon executable can reach the few
/// decisions it shares with the app, like `containsTaskComplete`.
public enum AgentTurnLogic {
    /// Fallback wait when the model doesn't choose one: long enough for an ordinary shell
    /// command to finish and settle, short enough that fire-and-forget typing isn't stuck.
    static let defaultAwaitOutputSeconds = 5
    /// Ceiling on a model-chosen wait, so a wild value can't hang a turn for an hour.
    static let maxAwaitOutputSeconds = 300
    /// The terminal counts as settled once output has stopped growing for this long. Has
    /// to comfortably exceed the event log's chunk gap (0.35s) and ride out a TUI's
    /// spinner frames, while staying short enough that quick commands return promptly.
    static let outputSettleWindow: TimeInterval = 1.2
    /// Once output exists but all of it still classifies as echo, this longer quiet
    /// window settles anyway — the echo heuristic is deliberately conservative and a
    /// response that happens to restate the whole command (or a one-character input whose
    /// echo check matches everything) must degrade to a short extra wait, not a stall
    /// through the entire model-chosen budget.
    static let echoOnlySettleWindow: TimeInterval = 3.0

    /// Whether new output amounts to more than our own keystrokes reflected back.
    ///
    /// The PTY echoes typed input immediately, so "output appeared and went quiet" is
    /// satisfied by the echo alone — for a command that thinks before printing (sleep,
    /// a build, another agent), settling on that would return before the actual response.
    /// A line counts as a response unless it contains one of the sent lines (the echo,
    /// usually behind a shell prompt prefix — compared per line because a multi-line send
    /// echoes as multiple lines, none of which contain the whole text) or carries no
    /// alphanumeric content at all (a bare prompt redraw). Deliberately NOT the
    /// reverse-substring check: `echo X`'s real output is X, a substring of what was
    /// sent — rejecting that direction would classify every echo command's output as its
    /// own echo.
    static func containsResponse(_ outputText: String, beyond input: String) -> Bool {
        let sentLines = input
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for rawLine in outputText.split(separator: "\n") {
            var line = String(rawLine)
            // Strip the event log's "[HH:mm:ss] < " rendering prefix where present.
            if let markerRange = line.range(of: "] < "), line.hasPrefix("[") {
                line = String(line[markerRange.upperBound...])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            if sentLines.contains(where: { line.contains($0) }) { continue }
            return true
        }
        return false
    }

    /// An approved send_input is always actually submitted, exactly like pressing Return.
    ///
    /// Two failure modes led here: the model often omits the trailing newline its tool
    /// description asked for, leaving the command typed but unsent; and even when it
    /// includes one, it's `\n` — a real Return keypress sends `\r`, and TUI apps (unlike a
    /// shell's line discipline) frequently only submit on `\r`. Interior newlines are the
    /// command's own content and are preserved; only the tail is normalized.
    static func submittable(_ input: String) -> String {
        typedBody(input) + "\r"
    }

    /// The command text as it should be typed, before the separately-sent Return: trailing
    /// newlines stripped (models add them inconsistently, and a `\n` is not a Return
    /// keypress anyway), interior newlines preserved as the command's own content.
    static func typedBody(_ input: String) -> String {
        var text = input
        // CRLF is a single grapheme cluster in Swift, so it matches neither a bare-\n nor
        // a bare-\r suffix check on its own — the same trap TerminalEventLog's stripper hit.
        while let last = text.last, last == "\n" || last == "\r" || last == "\r\n" {
            text.removeLast()
        }
        return text
    }

    /// Wraps a raw terminal snapshot in directive framing before it reaches the model, so a
    /// small/unstable model is told plainly to quote this exact content rather than
    /// continue the pattern of shell-like text with an invented value. Shared by both the
    /// deterministic forced path and the model-initiated path.
    static func frameTerminalResult(_ snapshot: String) -> String {
        guard !snapshot.isEmpty else {
            return "TERMINAL OUTPUT: the terminal is empty. There is nothing to report -- say so plainly. Do not invent any command, output, or value."
        }
        return "TERMINAL OUTPUT (authoritative -- use this exact content when you answer; do not invent, guess, or substitute any other value, word, or number):\n\n\(snapshot)\n\nEND OF TERMINAL OUTPUT. Quote values above verbatim in your next reply."
    }

    /// Frames delivery plus whatever the terminal printed in response, so the model can
    /// answer from the real response instead of a follow-up read_terminal racing the
    /// program — the exact failure a live transcript showed: read 600ms after asking a
    /// question, see stale screen content, reason in circles over it.
    static func frameSendInputResult(
        _ summary: String,
        response: String,
        connectionDropped: Bool
    ) -> String {
        if connectionDropped {
            return "INPUT SENT, BUT THE CONNECTION DROPPED while waiting for the response. \"\(summary)\" was typed and submitted; whether it ran is unknown, and any output captured after the drop may be a reconnect screen redraw rather than the command's response. Tell the user the connection was interrupted -- do not claim the command succeeded or invent its output."
        }
        guard !response.isEmpty else {
            return "INPUT SENT (confirmed -- do not repeat this action): \"\(summary)\" was typed and submitted, but nothing new was printed before the wait ran out. The program may still be working -- call read_terminal later to check; do not guess or assume the output."
        }
        return "INPUT SENT (confirmed -- do not repeat this action): \"\(summary)\" was typed and submitted. The terminal printed this in response (authoritative -- use this exact content when you answer; do not invent, guess, or substitute any other value, word, or number):\n\n\(response)\n\nEND OF RESPONSE. If more output may arrive later, call read_terminal to check again."
    }

    /// The unattended-completion contract, exactly as the system and heartbeat prompts
    /// state it: the model ENDS a reply with the exact phrase TASK COMPLETE once — and
    /// only once — the task is verified done. Detection is therefore suffix-anchored,
    /// not substring: trailing whitespace and trailing punctuation (markdown emphasis
    /// and a closing period are common — `.` `!` `*` `_` `` ` `` `"` `'`) are trimmed,
    /// then the reply must end with the exact case-sensitive phrase. A reply that merely
    /// MENTIONS the phrase mid-sentence must not complete: live-proven false positive —
    /// a model restating its instructions ("I will only reply TASK COMPLETE when
    /// instructed…") completed the task and shut the daemon down.
    public static func containsTaskComplete(_ text: String) -> Bool {
        let trailingPunctuation: Set<Character> = [".", "!", "*", "_", "`", "\"", "'"]
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace || trailingPunctuation.contains(last) {
            trimmed = trimmed.dropLast()
        }
        return trimmed.hasSuffix("TASK COMPLETE")
    }

    static func summarize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(whitespace)" : trimmed
    }

    /// A dropped connection or an overloaded server is worth another try; a 4xx means the
    /// request itself is wrong and will fail identically forever.
    static func isRetryableEndpointError(_ error: Error) -> Bool {
        switch error {
        case AgentEndpointError.transport:
            return true
        case AgentEndpointError.http(let status, _):
            return status == 408 || status == 429 || (500..<600).contains(status)
        case AgentEndpointError.malformedResponse:
            return true
        default:
            return false
        }
    }

    static func elapsedMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
