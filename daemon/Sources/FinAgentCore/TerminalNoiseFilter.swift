// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
import Foundation

/// Strips Fin's OWN plumbing out of a capture of Fin's own control shell before the
/// model is ever shown it.
///
/// Live failure this exists for (2026-09-16, thread `m-b3bf22ae`): asked to look at
/// the owner's machine, the model called `read_terminal` — its own control pane — and
/// got back nothing but the shell-readiness handshake `HeadlessTerminalSession` and
/// `LocalTerminalSession` type on every connect (`echo FIN_READY_<n>`, `echo
/// FIN_ENV_<n>=$TMUX`, and their echoes). `frameTerminalResult` then labelled that
/// "authoritative … quote values above verbatim", so the answer pushed to the owner's
/// phone was a wall of `FIN_ENV_580869=/private/tmp/tmux-501/fin,25329,0`.
///
/// Fin's probes are not terminal content: no one typed them, they say nothing about
/// any work, and a capture made of only them means the control shell is IDLE — which
/// is the honest thing to report, and a very different sentence from "here is what
/// your computer is doing". Deliberately pure and line-at-a-time so it is scored the
/// same way every other guardrail here is.
public enum TerminalNoiseFilter {
    /// What `strip` found. `removedAll` is true when the capture held probe lines and
    /// nothing else — the signal the caller needs to say "idle" instead of quoting.
    public struct Result: Equatable {
        public let text: String
        public let removedAll: Bool

        public init(text: String, removedAll: Bool) {
            self.text = text
            self.removedAll = removedAll
        }
    }

    /// The probe tokens themselves, with the `=value` a `FIN_ENV_` echo carries.
    /// Bounded digits so a long random-looking run can never be swallowed as one.
    private static let tokenPattern = "FIN_(?:ENV|READY)_[0-9]{1,12}(?:=[^\\s]*)?"

    /// The `TerminalEventLog` marker `recentText` prefixes each line with.
    private static let markerPattern = "^\\[[0-9]{2}:[0-9]{2}:[0-9]{2}\\][ \\t]*[<>][ \\t]*"

    /// Characters a pane leaves around a bare token — the wrapped-line glyph among them.
    private static let trailingJunk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "⏎"))

    public static func strip(_ snapshot: String) -> Result {
        guard !snapshot.isEmpty else { return Result(text: snapshot, removedAll: false) }

        var kept: [String] = []
        var removed = 0
        for line in snapshot.components(separatedBy: "\n") {
            if isProbeLine(line) {
                removed += 1
            } else {
                kept.append(line)
            }
        }
        guard removed > 0 else { return Result(text: snapshot, removedAll: false) }

        let text = kept.joined(separator: "\n")
        // "Nothing but probes" has to tolerate what a pane leaves behind between them:
        // blank lines and the bare prompt a probe was typed at carry no information
        // either, so a capture of only those is still an idle shell.
        let residue = kept.contains { !isBlankOrPrompt($0) }
        return Result(text: text, removedAll: !residue)
    }

    /// True when the whole line is one of Fin's handshake probes — the command as typed,
    /// the shell's echo of it, or the token coming back on its own — and nothing else.
    /// Everything before the token must be blank, an `echo`, or a shell prompt; every-
    /// thing after it must be blank. A line that merely MENTIONS a token in prose (a log
    /// message, someone's grep output) keeps its other words and so is not a probe.
    static func isProbeLine(_ raw: String) -> Bool {
        let line = raw.replacingOccurrences(
            of: markerPattern, with: "", options: [.regularExpression]
        )
        guard let token = line.range(of: tokenPattern, options: [.regularExpression]) else {
            return false
        }
        guard line[token.upperBound...].trimmingCharacters(in: trailingJunk).isEmpty else {
            return false
        }
        var before = line[..<token.lowerBound].trimmingCharacters(in: trailingJunk)
        if before.hasSuffix("echo") {
            before = String(before.dropLast("echo".count)).trimmingCharacters(in: trailingJunk)
        }
        return before.isEmpty || endsWithPrompt(before)
    }

    /// A shell prompt's terminator, for fish/zsh/bash alike. The prompt body itself is a
    /// user's own `user@host ~/dir (branch)` and is never matched, only its last glyph.
    private static func endsWithPrompt(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == ">" || last == "$" || last == "%" || last == "#"
    }

    private static func isBlankOrPrompt(_ raw: String) -> Bool {
        let line = raw
            .replacingOccurrences(of: markerPattern, with: "", options: [.regularExpression])
            .trimmingCharacters(in: trailingJunk)
        return line.isEmpty || endsWithPrompt(line)
    }
}
