// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

struct AgentToolSpec {
    let name: String
    let description: String
    /// JSON Schema for the arguments object.
    let parameters: [String: Any]

    var wireValue: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ],
        ]
    }

    static let readTerminal = AgentToolSpec(
        name: "read_terminal",
        description: "You MUST call this before answering anything about terminal output, "
            + "state, or history — e.g. \"what did that print?\", \"what was just echoed?\", "
            + "\"is it done yet?\". Never answer from memory or a guess; quote exact values "
            + "(markers, numbers, filenames) verbatim from the result. Returns recent activity, "
            + "oldest first, timestamped: \"[HH:mm:ss] > text\" is typed input, "
            + "\"[HH:mm:ss] < text\" is terminal output.",
        parameters: [
            "type": "object",
            "properties": [
                "lines": [
                    "type": "integer",
                    "description": "How many trailing lines to return. Defaults to the agent's configured window.",
                ],
            ],
            "required": [String](),
        ]
    )

    static let sendInput = AgentToolSpec(
        name: "send_input",
        description: "You MUST call this whenever the user asks you to run, type, or execute "
            + "something — e.g. \"run git status\", \"type pwd and press enter\" — even if the "
            + "text looks unfamiliar; don't describe it or ask to confirm first. Types the given "
            + "text into the live terminal, presses Return to submit it, waits for the terminal "
            + "to respond, and returns what it printed. One command per call, sent verbatim.",
        parameters: [
            "type": "object",
            "properties": [
                "input": [
                    "type": "string",
                    "description": "The literal command text to type. Return is pressed for you — no trailing newline needed.",
                ],
                "await_output_seconds": [
                    "type": "integer",
                    "description": "How long to wait for the terminal's response, in seconds. "
                        + "The tool returns as soon as output settles, so a generous value costs "
                        + "nothing when the response is fast. Pick it from what you sent: ~5 for "
                        + "an ordinary shell command, 30-120 when asking another agent or a "
                        + "long-running program a question that takes time to answer. Omit for "
                        + "the default (5).",
                ],
            ],
            "required": ["input"],
        ]
    )

    static let remember = AgentToolSpec(
        name: "remember",
        description: "Save an important fact to long-term memory when the user states a goal, "
            + "decision, preference, or detail worth keeping across conversations.",
        parameters: [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Short label for the fact.",
                ],
                "content": [
                    "type": "string",
                    "description": "The fact itself, one or two sentences.",
                ],
                "tags": [
                    "type": "string",
                    "description": "Comma-separated keywords. Empty for none.",
                ],
            ],
            "required": ["title", "content"],
        ]
    )

    static let recall = AgentToolSpec(
        name: "recall",
        description: "Search long-term memory when the user references past conversations or "
            + "previously saved facts. Empty query returns the most recent memories.",
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Words to search for. Empty for most recent.",
                ],
            ],
            "required": [String](),
        ]
    )

    static let monitor = AgentToolSpec(
        name: "monitor",
        description: "Arm or disarm your own unattended monitoring loop. When asked to "
            + "supervise, watch, or keep driving a task until done, call this with action "
            + "\"start\" — you will then be woken automatically at the interval to check "
            + "the terminal and act. Call with \"stop\" (or end a reply with TASK COMPLETE) "
            + "when the task is finished. Only works in auto mode.",
        parameters: [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "description": "\"start\" to arm monitoring, \"stop\" to disarm.",
                ],
                "interval_seconds": [
                    "type": "integer",
                    "description": "Seconds between checks when starting. Pick from the task's "
                        + "pace: 30-60 for active supervision, 120-300 for slow builds. "
                        + "Omit or 0 to keep the current setting.",
                ],
            ],
            "required": ["action"],
        ]
    )

    static let requestInput = AgentToolSpec(
        name: "request_input",
        description: "Ask the user a question when you are blocked without their answer — "
            + "a choice only they can make, a credential, an ambiguous instruction. "
            + "Notifies them and returns immediately; their next message is the answer.",
        parameters: [
            "type": "object",
            "properties": [
                "question": [
                    "type": "string",
                    "description": "The question the user must answer, one or two sentences.",
                ],
            ],
            "required": ["question"],
        ]
    )

    static let all: [AgentToolSpec] = [readTerminal, sendInput, remember, recall, requestInput, monitor]

    static let knownToolNames: Set<String> = Set(all.map(\.name))
}

/// Commands that get a confirmation prompt even in auto mode.
///
/// This is defense in depth, not a security boundary — it is trivially bypassable by an
/// obfuscated command and makes no attempt to parse shell grammar. Its job is to catch
/// the recognizable shape of an irreversible mistake (a hallucinated `rm -rf`, a model
/// steered by hostile text in terminal output) at the exact moment it would otherwise be
/// typed unattended. Anything it misses is still bounded by the session's own
/// credentials; anything it catches costs the user one tap.
enum DestructiveCommandHeuristic {
    private static let patterns: [String] = [
        #"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rf]"#,
        #"\brm\s+-[a-zA-Z]*[rf]"#,
        #"\bmkfs(\.\w+)?\b"#,
        #"\bdd\s+.*\bof=/dev/"#,
        #"\b(shutdown|reboot|halt|poweroff)\b"#,
        #">\s*/dev/[sh]d[a-z]"#,
        #"\bchmod\s+-R\s+777\s+/"#,
        #"\b(userdel|groupdel)\b"#,
        #"\bdrop\s+(database|table)\b"#,
        #"\btruncate\s+-s\s*0"#,
        #":\(\)\s*\{.*\|.*&\s*\}\s*;"#,   // fork bomb
        #"\bgit\s+push\b.*(--force|-f)\b"#,
        #"\bgit\s+reset\s+--hard\b"#,
        #"\bkill(all)?\s+-9\b"#,
    ]

    static func isDestructive(_ input: String) -> Bool {
        let normalized = input.lowercased()
        return patterns.contains { pattern in
            normalized.range(of: pattern, options: [.regularExpression]) != nil
        }
    }
}
