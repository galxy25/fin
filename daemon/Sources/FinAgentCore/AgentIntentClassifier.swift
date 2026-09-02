// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// Deterministically buckets a user message into one of the two unambiguous tool intents
/// the agent supports, or `.ambiguous` when it isn't confidently one of those.
///
/// This exists so `AgentRuntime` can force the matching tool call *before* asking the
/// model anything, rather than leaving invocation entirely up to the model's own judgment
/// — which measurably fails to call the tool at all for some backends (see
/// `AgentRuntime.forceToolCallIfNeeded`). Only the clear-cut cases are classified; anything
/// else falls through to the model's own tool-calling loop unchanged.
enum AgentIntentClassifier {
    enum Intent: Equatable {
        case ambiguous
        case readTerminal
        case sendInput(command: String)
    }

    /// Anchors "run/type/execute" to an imperative reading near the start of the message,
    /// with an optional polite prefix. Deliberately narrow: matching the verb anywhere in
    /// the sentence would also fire on descriptions and questions about running something
    /// ("I ran this earlier and it broke"), which must not force an unattended command.
    private static let sendInputPattern =
        #"(?i)^(please\s+|could you\s+|can you\s+|would you\s+)?(run|type|execute)\s+(.+)$"#

    private static let trailingPressEnterPattern =
        #"(?i),?\s*(then\s+|and\s+)?(press|hit)\s+enter\.?\s*$"#

    /// Generic phrasing about terminal state, output, history, or completion — never tied
    /// to any particular test's marker text.
    private static let readTerminalPatterns: [String] = [
        #"(?i)\b(what|did)\b.*\b(print|printed|output|echo(ed)?|say|said|show(ed)?)\b"#,
        #"(?i)\bis (it|that|this) (done|finished|ready)\b"#,
        #"(?i)\b(did|has) (it|that|this) (finish|complete|finished|completed)\b"#,
        #"(?i)\bwhat('?s| is| was) the (output|result)\b"#,
        #"(?i)\bshow (me )?the (terminal|output|screen)\b"#,
        #"(?i)\bwhat (does|did) the (terminal|screen) (say|show)\b"#,
    ]

    static func classify(_ message: String) -> Intent {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ambiguous }

        if let command = extractSendInputCommand(trimmed) {
            // "Run recall one more time with the same query" is an instruction to use
            // the agent's own tool, not text to type into the terminal — observed
            // live: the forced send_input typed the directive into the shell and the
            // agent had to self-correct a turn later. When the imperative's direct
            // object is one of the agent's own tools, defer to the model instead.
            if referencesOwnToolAsImperative(command) { return .ambiguous }
            return .sendInput(command: command)
        }

        for pattern in readTerminalPatterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return .readTerminal
            }
        }

        return .ambiguous
    }

    /// A question about running something ("should I run rm -rf?") is a question, not a
    /// directive — bailing out on any `?` anywhere in the message is a deliberate
    /// false-positive guard on the destructive side, even though it also rejects a rare
    /// legitimate "run X?" phrasing that happens to end in a question mark.
    private static func extractSendInputCommand(_ trimmed: String) -> String? {
        guard !trimmed.contains("?") else { return nil }

        // NSRegularExpression (rather than the String.range convenience) so the captured
        // tail group — the actual command text — is reachable directly.
        guard let regex = try? NSRegularExpression(pattern: sendInputPattern),
              let result = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              result.numberOfRanges >= 4,
              let tailRange = Range(result.range(at: 3), in: trimmed)
        else { return nil }

        var command = String(trimmed[tailRange])
        // "Run this exact command right now: echo hi" describes the command before naming
        // it, with a colon-space introducing the literal text — a common enough shape that
        // capturing the whole tail verbatim would type the description itself into the
        // terminal. Only "colon immediately followed by whitespace" qualifies, so this
        // doesn't clip a URL or host:port that happens to appear in the command.
        if let colonSpace = command.range(of: ": ", options: .backwards) {
            let afterColon = command[colonSpace.upperBound...].trimmingCharacters(in: .whitespaces)
            if !afterColon.isEmpty { command = afterColon }
        }
        command = command.replacingOccurrences(
            of: trailingPressEnterPattern,
            with: "",
            options: .regularExpression
        )
        command = stripWrapping(command)
        command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = command.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        command = command.trimmingCharacters(in: .whitespacesAndNewlines)

        return command.isEmpty ? nil : command
    }

    /// The agent's own tool names, as a user would say them ("request input" is the
    /// spoken form of request_input). read_terminal and send_input are deliberately
    /// absent: naming those still means terminal interaction, which the forced call
    /// serves correctly.
    private static let ownToolNames = ["recall", "remember", "request_input", "request input", "monitor"]

    /// True when a would-be send_input command is really "invoke one of my own
    /// tools". Chosen heuristic, deliberately narrow: the tool name must be the
    /// command's FIRST word (the imperative's direct object — "run recall …",
    /// "execute request_input …") at a word boundary (end, whitespace, comma, or
    /// colon follows), and the command must contain no path or shell tokens
    /// (`/ \ | ; & < > $ \``) anywhere — those mark a shell task even when it leads
    /// with a tool word ("run recall/refresh.sh").
    ///
    /// Accepted misses, on purpose:
    /// - "run the recall tool with query X" still forces send_input (first word is
    ///   "the"); the model self-corrects next turn, exactly as observed live.
    /// - "run recall --verbose" (a hypothetical shell binary named recall) reads as
    ///   the agent tool; on this surface the agent's own tool is overwhelmingly the
    ///   intended meaning, and the cost is only deferring to the model's judgment.
    private static func referencesOwnToolAsImperative(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\|;&<>$`")) != nil {
            return false
        }
        for tool in ownToolNames where lowered.hasPrefix(tool) {
            let boundary = lowered.index(lowered.startIndex, offsetBy: tool.count)
            if boundary == lowered.endIndex { return true }
            let next = lowered[boundary]
            if next == " " || next == "\t" || next == "\n" || next == "," || next == ":" {
                return true
            }
        }
        return false
    }

    /// Strips a single layer of wrapping backticks or matching quotes.
    private static func stripWrapping(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [(Character, Character)] = [("`", "`"), ("\"", "\""), ("'", "'")]
        for (open, close) in wrappers {
            if result.count >= 2, result.first == open, result.last == close {
                result = String(result.dropFirst().dropLast())
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
