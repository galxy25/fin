// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// Public so the daemon target (a separate module) can read `notifyPersonaGuidance` for
// its gated prompt; the app compiles these sources directly, where it's simply internal.
public struct AgentToolSpec {
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

    static let notify = AgentToolSpec(
        name: "notify",
        // The proactively-social lever, put in the MODEL's hands on purpose: nothing here
        // pushes on your behalf, so YOU decide when a moment is worth the owner's attention.
        // The description sells the copilot job (a remote owner sees only what you push) and
        // the discipline in the same breath — one clear note when there's news, never a
        // ping per trivial step or heartbeat tick.
        description: "Send a short push notification to the owner. You are their copilot and "
            + "they often can't see this terminal — a remote owner sees only what you push. "
            + "Call it to stay in the loop: your reply to what they asked, meaningful progress, "
            + "a blocker, or a finished goal. Delivers to their device and tells you whether it "
            + "was sent. Use judgment: one clear note when there is something worth telling them, "
            + "never a notify on every trivial step or on a heartbeat tick that found nothing new.",
        parameters: [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Short headline for the notification, a few words.",
                ],
                "body": [
                    "type": "string",
                    "description": "The message to the owner, one or two sentences.",
                ],
            ],
            "required": ["title", "body"],
        ]
    )

    /// The read half of the private-socket design, in the model's hands as a NAME, never
    /// as a command line (`TmuxSessionRead`). Fin's shell lives on its own tmux socket, so
    /// `tmux capture-pane -t main` typed into that shell reaches Fin's own server, where
    /// the human's sessions do not exist. This tool is the supported path to them: the
    /// runner runs a fixed `tmux capture-pane` argv on a separate channel against the
    /// machine's default socket, and the only thing the model contributes is one validated
    /// session name.
    ///
    /// The listing is folded into the same tool rather than split into a second one, so
    /// the discovery step is impossible to miss: no arguments lists, a name reads.
    static let readSession = AgentToolSpec(
        name: "read_session",
        description: "Look at ANOTHER terminal session on this machine — the owner's own work, "
            + "or another agent's session. Call it with NO arguments to list the sessions by name, "
            + "then call it again with a name to see a screen. That name does NOT have to be an "
            + "exact match from the listing, which only shows top-level session names: a project "
            + "or repo name (\"fin\", \"pocketdj\") is matched against every window on the machine "
            + "by its own name and its working directory, so try your best short guess even when "
            + "the listing didn't show it directly — do not give up just because nothing in the "
            + "listing matched literally. Use it whenever you are asked what is running, what "
            + "another session printed, or how someone else's work is going. read_terminal shows "
            + "only YOUR terminal; this is the only way to see the others, and it is read-only — "
            + "it cannot type into them.",
        parameters: [
            "type": "object",
            "properties": [
                "session": [
                    "type": "string",
                    "description": "The session's name, or your best short guess at one — a "
                        + "project/repo name works even if the listing didn't show it, since it "
                        + "is matched against every window's name and directory, not just exact "
                        + "session names. Omit to list the sessions instead of reading one. A "
                        + "name only — not a command, not a tmux argument.",
                ],
                "lines": [
                    "type": "integer",
                    "description": "How many trailing lines of that session's screen to return "
                        + "(1-\(TmuxSessionRead.maxLines)). Omit for the default "
                        + "(\(TmuxSessionRead.defaultLines)).",
                ],
            ],
            "required": [String](),
        ]
    )

    /// THE WRITE HALF — see `TmuxSessionSend.swift`'s design note for why this is a real
    /// change to the threat model, not an extension of `read_session`'s. Deliberately
    /// stricter in its own parameter shape too: no bare-name convenience, because a wrong
    /// guess here types real keystrokes into somebody else's pane instead of just
    /// returning a wrong-but-harmless read.
    static let sendSession = AgentToolSpec(
        name: "send_session",
        description: "Type a message into ANOTHER terminal session on this machine — e.g. "
            + "messaging another Claude Code agent working in a different project. Unlike "
            + "read_session, this REQUIRES the exact \"session:window\" target (call read_session "
            + "first, even with just a bare guess, to find and confirm it — a bare name here is "
            + "refused). Types your text, presses Return to submit it, and can optionally wait "
            + "and return what appeared afterward. This really sends real keystrokes to a real "
            + "pane — confirm you have the right target before calling it, don't guess.",
        parameters: [
            "type": "object",
            "properties": [
                "session": [
                    "type": "string",
                    "description": "The EXACT \"session:window\" target to type into — e.g. "
                        + "\"main:2\", copied from a read_session result. Not a bare name.",
                ],
                "text": [
                    "type": "string",
                    "description": "The message to type, verbatim. ONE LINE — no newlines; "
                        + "Return is pressed for you afterward, so don't include one. A "
                        + "multi-part message needs separate send_session calls, one line "
                        + "each. Up to \(TmuxSessionSend.maxTextLength) characters.",
                ],
                "await_output_seconds": [
                    "type": "integer",
                    "description": "How long to wait and watch that session's screen after "
                        + "sending, in seconds (0-\(TmuxSessionSend.maxAwaitSeconds)), returning "
                        + "what it shows once it stops changing. Omit (or 0) to send and return "
                        + "immediately without waiting — the natural choice if you'll check back "
                        + "with read_session later. Another agent composing a real answer can "
                        + "take real time; a short wait here often just shows it still working.",
                ],
            ],
            "required": ["session", "text"],
        ]
    )

    /// Creates or updates a goal in the persisted goals ledger — see `GoalsLedger.swift`
    /// and `evals/goals-ledger/prompts/tick.md` for the full decision taxonomy this tool
    /// exists to serve. Deliberately ONE upsert shape (id omitted = create, id given =
    /// update only the fields provided) rather than separate create/update tools: the
    /// tick's own instruction is "prefer updating... only genuinely new work gets a new
    /// goal," and a single call the model can use either way keeps that choice cheap.
    static let goalUpsert = AgentToolSpec(
        name: "goal_upsert",
        description: "Create or update a goal in your persisted goals ledger — the durable "
            + "record of what the user wants, which survives restarts and reloads into every "
            + "turn. Prefer UPDATING an existing goal (give its id) over creating a new one: a "
            + "message about work the ledger already tracks — however paraphrased, typo'd, or "
            + "terse — attaches to that goal. Only genuinely new work gets a new goal (omit id). "
            + "Use this on ingest (a new message creates or updates a goal) and whenever a "
            + "goal's state, next action, or blocker changes — not for routine progress notes, "
            + "which are goal_log instead.",
        parameters: [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "description": "A short slug you choose, e.g. \"g-pocketdj-indexer\". Give "
                        + "an EXISTING goal's id to update it — only the fields you provide "
                        + "change, the rest are left as they are. Give a NEW id (one not "
                        + "already in the ledger) to create a goal.",
                ],
                "title": ["type": "string", "description": "Short goal title. Required when creating a new id."],
                "state": [
                    "type": "string",
                    "enum": ["open", "active", "blocked", "done"],
                    "description": "open: accepted but not started. active: in flight. "
                        + "blocked: waiting on something — set blocked_on too. done: finished — "
                        + "log a close update too, via goal_log, to report it.",
                ],
                "why": ["type": "string", "description": "What the user wants and how you'll know it's done."],
                "next_action": ["type": "string", "description": "The single concrete next step."],
                "blocked_on": ["type": "string", "description": "What state == blocked is waiting on. Clear by setting state away from blocked."],
                "tags": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Phrases the user is likely to use for this goal, for future "
                        + "matching. REPLACES the whole existing list on update, not merged — "
                        + "include every tag you want kept, not just new ones.",
                ],
                "source": ["type": "string", "description": "The inbox/user message id that created or updated this goal, if any."],
            ],
            "required": ["id"],
        ]
    )

    /// Appends one timestamped entry to a goal's update log — the mechanism behind
    /// `hasCloseUpdate`/`needsBlockerSurface` (`GoalsLedger.swift`): a `close` entry is
    /// what makes a `done` goal's report owed-and-paid, a `report` entry is what makes a
    /// surfaced blocker sit quiet instead of being re-nagged. Kept separate from
    /// `goal_upsert` because most ticks log progress far more often than they change a
    /// goal's shape, and folding both into one call would make the common case verbose.
    static let goalLog = AgentToolSpec(
        name: "goal_log",
        description: "Record what happened on a goal — progress, a blocker, that you reported "
            + "something to the user, or a closing report on a done goal. This is what makes "
            + "the ledger idempotent across restarts: \"was this blocker already surfaced?\", "
            + "\"was this done goal already closed out?\" become ledger questions, never "
            + "memory-of-the-conversation questions. Log a close entry the same turn you set "
            + "a goal's state to done, or it will keep showing as owing its closing report.",
        parameters: [
            "type": "object",
            "properties": [
                "goal_id": ["type": "string", "description": "The goal this entry belongs to."],
                "kind": [
                    "type": "string",
                    "enum": ["progress", "blocker", "report", "close", "note"],
                    "description": "progress: work happened. blocker: why it stopped (also "
                        + "set the goal's state to blocked and blocked_on via goal_upsert). "
                        + "report: you told the user something (this is what stops a surfaced "
                        + "blocker from being re-nagged). close: a done goal's closing report. "
                        + "note: anything else.",
                ],
                "text": ["type": "string", "description": "What happened, one or two sentences."],
            ],
            "required": ["goal_id", "kind", "text"],
        ]
    )

    /// The artifacts filesystem: one flat, plain-text space per Fin account — "a second
    /// filesystem apart from the iOS native one" — shared by every agent, local or cloud.
    static let writeArtifact = AgentToolSpec(
        name: "write_artifact",
        description: "Write (create or overwrite) a plain-text file in your shared artifacts "
            + "folder — a place to save something the user or another one of your sessions "
            + "should be able to find later, separate from any one conversation.",
        parameters: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Relative file path, e.g. \"notes/todo.txt\". Letters, "
                        + "digits, \".\", \"_\", \"-\", \"/\" only.",
                ],
                "content": ["type": "string", "description": "The file's full text content."],
            ],
            "required": ["path", "content"],
        ]
    )

    static let readArtifact = AgentToolSpec(
        name: "read_artifact",
        description: "Read one file's content from your shared artifacts folder.",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "The file's relative path."],
            ],
            "required": ["path"],
        ]
    )

    static let listArtifacts = AgentToolSpec(
        name: "list_artifacts",
        description: "List every file path in your shared artifacts folder.",
        parameters: ["type": "object", "properties": [String: Any](), "required": [String]()]
    )

    static let deleteArtifact = AgentToolSpec(
        name: "delete_artifact",
        description: "Delete one file from your shared artifacts folder. Irreversible.",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "The file's relative path."],
            ],
            "required": ["path"],
        ]
    )

    static let all: [AgentToolSpec] = [
        readTerminal, sendInput, readSession, sendSession, goalUpsert, goalLog,
        remember, recall, requestInput, monitor, notify,
        writeArtifact, readArtifact, listArtifacts, deleteArtifact,
    ]

    /// The roster MINUS the tools a runtime cannot actually provide.
    ///
    /// A shared roster is the right default — the app and the daemon should not drift — but
    /// advertising a tool whose dispatch can only answer "not available here" is a trap the
    /// model walks into once per conversation: it costs a turn, prints a red error row, and
    /// the description ("this is the only way to see the others", "use it whenever you are
    /// asked what is running") is written to make it call. `read_session` is exactly that in
    /// the Fin app: it needs a second SSH exec channel against a machine whose tmux sessions
    /// the app is not managing, and the app's own routing prompt tells the model to use
    /// `tmux capture-pane` for that instead — two contradictory instructions, the
    /// tool-shaped one always failing.
    ///
    /// So the runtime that cannot serve it does not offer it. The dispatch's honest error
    /// stays as a backstop for a model that names the tool anyway.
    static func roster(
        readSession readAvailable: Bool, sendSession sendAvailable: Bool,
        goalsLedger ledgerAvailable: Bool = false, memory memoryAvailable: Bool = false,
        artifacts artifactsAvailable: Bool = false
    ) -> [AgentToolSpec] {
        let artifactNames: Set<String> = [
            writeArtifact.name, readArtifact.name, listArtifacts.name, deleteArtifact.name,
        ]
        return all.filter { spec in
            (readAvailable || spec.name != readSession.name)
                && (sendAvailable || spec.name != sendSession.name)
                && (ledgerAvailable || (spec.name != goalUpsert.name && spec.name != goalLog.name))
                && (memoryAvailable || (spec.name != remember.name && spec.name != recall.name))
                && (artifactsAvailable || !artifactNames.contains(spec.name))
        }
    }

    static let knownToolNames: Set<String> = Set(all.map(\.name))

    /// Fin's proactively-social persona, appended to the system prompt ONLY when the
    /// `notify` tool has a live delivery channel in this runtime (see the runner's gate).
    /// Gated on purpose: a prompt must never coach the model to lean on a capability the
    /// runner will just answer "unavailable" to. The guidance's whole job is Levi's brief —
    /// keep a remote owner in the loop, and never let that slow or spam the mission.
    public static let notifyPersonaGuidance = """
        You are Fin: proactively social while ruthlessly accomplishing the mission. You are the \
        owner's copilot, and they often can't see this terminal — a remote owner sees only what \
        you push to them. So use the notify tool with judgment: when you finish answering their \
        prompt, hit a blocker, complete a goal, or reach progress a remote owner would want, send \
        one clear notify. Be genuinely social and keep them in the loop. But never let notifying \
        slow the work, and never spam — no notify on every trivial internal step, and none on a \
        heartbeat or self-check tick that turned up nothing worth reporting. Keep driving the \
        mission to completion; notify is how you bring the owner along, not a reason to pause.
        """
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
