// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// Goals ledger: the production port of evals/goals-ledger. The eval harness's baseline
// tick (policy_baseline.py), scenario corpus, and prompt block (prompts/tick.md) are the
// spec — the schema here must stay field-for-field identical to ledger.example.json, and
// the prompt text below must track prompts/tick.md decision-for-decision. Change the
// design there first, get the corpus green, then mirror the change here.
//
// The point of the ledger (Levi's directive): the heartbeat stops being a bare
// reflective question and becomes a goal-driving tick over PERSISTED state — the ledger,
// not the transcript, is the durable record of what the user wants, so no conversation
// ever starts from scratch and the agent drives the mission between messages.

/// A goal's lifecycle state. `open` accepted but not started, `active` in flight,
/// `blocked` waiting on the thing named in `blocked_on`, `done` finished.
public enum GoalState: String, Codable, Equatable, Sendable {
    case open, active, blocked, done

    /// Live goals are the ones the tick may still drive or ask about.
    public var isLive: Bool { self == .open || self == .active }
}

/// The kind taxonomy of a ledger update — the update log is what makes the tick
/// idempotent-ish: "was this blocker already surfaced?", "was this done goal already
/// closed?" are ledger questions, never memory-of-the-conversation questions.
public enum UpdateKind: String, Codable, Equatable, Sendable {
    /// Work happened.
    case progress
    /// Why the goal stopped.
    case blocker
    /// The user was told something.
    case report
    /// A done goal closed out with its report.
    case close
    /// Anything else.
    case note
}

/// One timestamped ledger entry (`{"at", "kind", "text"}` in ledger.example.json).
public struct Update: Codable, Equatable, Sendable {
    /// ISO8601 UTC, kept as the schema's string form: the ledger is a user-editable
    /// working-memory artifact, and string timestamps round-trip hand edits verbatim.
    public var at: String
    public var kind: UpdateKind
    public var text: String

    public init(at: String = Update.timestamp(), kind: UpdateKind, text: String) {
        self.at = at
        self.kind = kind
        self.text = text
    }

    /// Lenient by hand, like `SessionRegistration`: a trimmed or typo'd entry must not
    /// brick loading the whole document. An unknown kind reads as `note` — the one kind
    /// every decision helper treats as inert, so leniency can never fake a surfaced
    /// blocker or a closed goal.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decodeIfPresent(String.self, forKey: .at) ?? ""
        kind = (try? container.decode(UpdateKind.self, forKey: .kind)) ?? .note
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    /// The ledger's timestamp format ("2026-09-05T16:45:00Z"), matching
    /// ledger.example.json and what the eval baseline parses.
    public static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// One goal — the schema of a `goals[]` entry in `ledger.example.json`.
public struct Goal: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var state: GoalState
    /// 1 = highest; ties broken by ledger order.
    public var priority: Int
    /// What the user wants AND how we know it is done — the tick can recognize a user
    /// message announcing that a goal's `why` came true.
    public var why: String?
    /// The single concrete next step; a goal without one never stalls the tick.
    public var nextAction: String?
    /// The named waiter when state == blocked.
    public var blockedOn: String?
    /// The matching vocabulary (house pattern from the tmux registry): phrases the user
    /// is likely to use for this goal.
    public var tags: [String]
    /// The user-message id that created the goal.
    public var source: String?
    public var createdAt: String?
    public var updates: [Update]

    enum CodingKeys: String, CodingKey {
        case id, title, state, priority, why
        case nextAction = "next_action"
        case blockedOn = "blocked_on"
        case tags, source
        case createdAt = "created_at"
        case updates
    }

    public init(
        id: String,
        title: String,
        state: GoalState = .open,
        priority: Int = 1,
        why: String? = nil,
        nextAction: String? = nil,
        blockedOn: String? = nil,
        tags: [String] = [],
        source: String? = nil,
        createdAt: String? = Update.timestamp(),
        updates: [Update] = []
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.priority = priority
        self.why = why
        self.nextAction = nextAction
        self.blockedOn = blockedOn
        self.tags = tags
        self.source = source
        self.createdAt = createdAt
        self.updates = updates
    }

    /// Lenient by hand: the ledger is user-editable working memory, and the tick only
    /// truly needs `id` + `title` — a hand-trimmed goal must not brick the document.
    /// An unrecognized `state` reads as `open`, the conservative reading: it never
    /// drives the wrong next action, never closes anything, never invents a blocker.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        state = (try? container.decode(GoalState.self, forKey: .state)) ?? .open
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 1
        why = try container.decodeIfPresent(String.self, forKey: .why)
        nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
        blockedOn = try container.decodeIfPresent(String.self, forKey: .blockedOn)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try container.decodeIfPresent(String.self, forKey: .source)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updates = try container.decodeIfPresent([Update].self, forKey: .updates) ?? []
    }

    // MARK: - Decision helpers (mirroring policy_baseline.py)

    /// Whether a done goal has had its closing report recorded — priority rule 2's
    /// dedupe: a `done` goal without this still owes the user its closing report.
    public var hasCloseUpdate: Bool {
        updates.contains { $0.kind == .close }
    }

    /// Whether the latest blocker has never been followed by a `report` update — the
    /// baseline's `_needs_blocker_surface`: an unsurfaced blocker is reported once; a
    /// surfaced one sits quiet, never driven, never re-nagged.
    public var needsBlockerSurface: Bool {
        let afterLastBlocker: ArraySlice<Update>
        if let lastBlocker = updates.lastIndex(where: { $0.kind == .blocker }) {
            afterLastBlocker = updates[updates.index(after: lastBlocker)...]
        } else {
            afterLastBlocker = updates[...]
        }
        return !afterLastBlocker.contains { $0.kind == .report }
    }
}

/// The persisted goals-ledger document (`{"version": 1, "updated_at": …, "goals": […]}`).
/// A first-class artifact, not prompt text: it survives restarts and reloads into every
/// turn, on every device, so the user never starts a conversation from scratch.
public struct LedgerDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Stamped by `GoalsLedgerStore.save`; informational, never load-bearing.
    public var updatedAt: String?
    public var goals: [Goal]

    enum CodingKeys: String, CodingKey {
        case version, goals
        case updatedAt = "updated_at"
    }

    public init(
        version: Int = LedgerDocument.currentVersion,
        updatedAt: String? = nil,
        goals: [Goal] = []
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.goals = goals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? LedgerDocument.currentVersion
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        goals = try container.decodeIfPresent([Goal].self, forKey: .goals) ?? []
    }

    public var isEmpty: Bool { goals.isEmpty }

    /// The ledger's on-disk basename, identical on every platform. The app keeps it in
    /// Application Support (`GoalsLedgerLocation`); fin-agentd keeps it in its state
    /// directory, next to the audit log. Unlike the routing registry the ledger is NOT
    /// machine-scoped in principle — goals belong to the user, not to a host — but
    /// syncing it (like `AgentMemory` records, through `MemoryRedactor`) is a future
    /// lane; today each process reads its local file.
    public static let standardFileName = "goals-ledger.json"

    public static func load(from url: URL) throws -> LedgerDocument {
        try JSONDecoder().decode(LedgerDocument.self, from: Data(contentsOf: url))
    }

    /// Synchronous best-effort read for prompt composition and the heartbeat tick.
    /// Absent file → nil, the "no ledger, zero prompt change" gate. A file that exists
    /// but won't decode is ALSO nil: the per-entry decoders are already lenient, so
    /// what's left here is a ledger mangled beyond salvage, and dropping the mission
    /// section beats bricking prompt composition.
    public static func loadIfPresent(at url: URL) -> LedgerDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? load(from: url)
    }
}

/// The goal-driving tick's prompt surface: the system-prompt mission section and the
/// per-beat tick text. Both are derived from evals/goals-ledger/prompts/tick.md — edit
/// THERE first, re-score the corpus, then sync here.
public enum GoalsTick {
    /// The system-prompt block that teaches the model the ledger, the decision
    /// taxonomy, the priority rules, and copilot conduct, with the live goals rendered
    /// inline. Nil for an empty ledger: an agent with no goals must see zero prompt
    /// change — the section would only invite the model to invent a mission it was
    /// never given. The "Mission ledger:" marker is load-bearing: the prompt-gating
    /// tests key on it.
    public static func promptSection(ledger: LedgerDocument) -> String? {
        guard !ledger.isEmpty else { return nil }
        return """
        Mission ledger: you are a copilot, not a chatbot. Between the user's messages you \
        keep their goals moving. Your working memory holds this goals ledger — the persisted \
        list of everything the user is trying to get done — and it reloads into every turn, \
        so you never start from scratch and never ask the user to repeat what the ledger \
        already records.

        Current goals:
        \(renderGoals(ledger))

        Each goal carries its state (open accepted but not started, active in flight, \
        blocked waiting on the thing named as blocked on, done finished), its priority \
        (1 is highest, ties broken by ledger order), its why (what the user wants and how \
        you will know it is done), its single concrete next action, and its update log \
        (progress, blocker, report, close, note). The ledger is the durable record; the \
        conversation is not.

        Each heartbeat tick, decide exactly ONE of — the cheapest correct action:
        - ingest — an unprocessed user message creates a goal or updates one. Prefer \
        updating: a message about work the ledger already tracks — however paraphrased, \
        typo'd, or terse — attaches to that goal. Only genuinely new work gets a new goal. \
        A message delivering what a goal is blocked on unblocks it; a message matching a \
        goal's why coming true marks it done.
        - drive — no message waits; pick the most important drivable goal and execute its \
        next action. Deadlines named in a goal outrank ledger order; otherwise priority, \
        then order.
        - report — something is worth the user's attention: a goal newly done (close it \
        out), a blocker not yet surfaced, a stall (no real progress for ~30 minutes — \
        repeated identical failures are a stall even with fresh timestamps), or a status \
        question the ledger can answer.
        - idle — nothing owed, nothing drivable. Say so in one cheap line and spend \
        nothing. An empty or fully-blocked-and-surfaced ledger idles.
        - clarify — a message or a goal is genuinely ambiguous: it could attach to two \
        goals about equally, or the only live goal has no usable next action. Ask one \
        short question; name the candidates.

        Priority rules: the user preempts everything — handle the oldest unprocessed \
        message before driving, reporting, or idling. Done goals owe a closing report \
        before anything else is driven. Blocked goals are surfaced once, then sit quiet: \
        never spin on a blocker, never re-nag it, and when the user pushes on a goal \
        blocked on THEM, remind them what it waits on rather than pretending to act. A \
        surfaced stall goes back to being driven next tick, not re-reported. A goal \
        without a next action never stalls the tick — drive what is drivable; ask about \
        the vague goal only when nothing else remains.

        Conduct: advance the mission between messages — the heartbeat is your initiative, \
        use it to finish things. Surface blockers and completions; otherwise work quietly. \
        Never re-ask anything the ledger knows (its states, its blockers, what was already \
        reported). Never create a duplicate of a goal that already exists. Record every \
        material step as a ledger update so the next tick — on any device, after any \
        restart — picks up exactly where this one left off.
        """
    }

    /// The per-beat tick text that replaces the reflective heartbeat question when a
    /// ledger with goals exists — nil otherwise, so no-ledger agents keep the exact old
    /// beat. The goals render fresh into every beat (the continuity requirement: the
    /// ledger reloads into every turn), so mid-conversation ledger edits land on the
    /// next tick, not the next conversation. The "[heartbeat]" prefix is load-bearing
    /// (history restore, trajectory digests, and the console all key on it), and TASK
    /// COMPLETE keeps its existing meaning — monitor disarm — so it is reserved for the
    /// whole mission being done, not one goal: single-goal completion is a `report`
    /// that closes the goal out.
    public static func heartbeatPrompt(ledger: LedgerDocument) -> String? {
        guard !ledger.isEmpty else { return nil }
        return """
        [heartbeat] Mission tick. Review the goals ledger against what actually happened \
        since the last tick, then make exactly ONE decision — ingest, drive, report, idle, \
        or clarify — the cheapest correct action, per the Mission ledger rules in your \
        instructions.

        Ledger now:
        \(renderGoals(ledger))

        Emit the decision as JSON — {"decision": "ingest|drive|report|idle|clarify", \
        "goal_id"?: "<id or null for a new goal>", "message_id"?: "<inbox id>", "reason": \
        "<one line>"} — then carry it out: call read_terminal to check real state, send \
        input to drive, and call request_input when a report or clarify needs the user. \
        Only if EVERY goal in the ledger is done and closed out, end with TASK COMPLETE.
        """
    }

    /// One compact block per goal: identity and state on the first line, then only the
    /// facts the tick's decisions hinge on — the next action, the blocker and whether it
    /// was already surfaced, whether a done goal was closed out, and the latest update
    /// (what the stall judgment reads).
    private static func renderGoals(_ ledger: LedgerDocument) -> String {
        ledger.goals.map { goal -> String in
            var lines = ["- \(goal.id) [\(goal.state.rawValue), p\(goal.priority)] \(goal.title)"]
            if let why = goal.why, !why.isEmpty {
                lines.append("  why: \(why)")
            }
            if let next = goal.nextAction, !next.isEmpty {
                lines.append("  next: \(next)")
            }
            if let blocked = goal.blockedOn, !blocked.isEmpty {
                lines.append("  blocked on: \(blocked)"
                    + (goal.needsBlockerSurface
                        ? " (NOT yet surfaced to the user)"
                        : " (already surfaced — sit quiet)"))
            }
            if goal.state == .done {
                lines.append(goal.hasCloseUpdate
                    ? "  closed out with the user"
                    : "  done but NOT yet reported — owes its closing report")
            }
            if let last = goal.updates.last {
                lines.append("  last update (\(last.kind.rawValue), \(last.at)): \(last.text)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// Owns the on-disk ledger file. An actor because the tick's ingest/close paths and any
/// future sync applier all mutate it, and interleaved read-modify-write would silently
/// drop goals or updates — the exact continuity the ledger exists to guarantee.
public actor GoalsLedgerStore {
    private let fileURL: URL
    public private(set) var document: LedgerDocument

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.document = LedgerDocument()
    }

    /// A missing file is an empty ledger, not an error — nothing has been ingested yet
    /// on a fresh install, and the prompt gate treats both the same.
    @discardableResult
    public func load() throws -> LedgerDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            document = LedgerDocument()
            return document
        }
        document = try LedgerDocument.load(from: fileURL)
        return document
    }

    /// Upsert by goal id: re-adding an existing id replaces the goal wholesale, so a
    /// re-ingested goal's fresh fields never merge with stale ones — same semantics as
    /// `SessionRoutingRegistry.register`.
    public func addGoal(_ goal: Goal) throws {
        if let index = document.goals.firstIndex(where: { $0.id == goal.id }) {
            document.goals[index] = goal
        } else {
            document.goals.append(goal)
        }
        try save()
    }

    /// Appends one update to a goal's log — every material step becomes an update, so
    /// the next tick (any device, any restart) picks up exactly where this one left off.
    /// An unknown goal id is a silent no-op, matching `appendTasks`.
    public func appendUpdate(_ update: Update, toGoal id: String) throws {
        guard let index = document.goals.firstIndex(where: { $0.id == id }) else { return }
        document.goals[index].updates.append(update)
        try save()
    }

    /// State transitions live in the ledger, never in conversation memory. An unknown
    /// goal id is a silent no-op.
    public func setState(_ state: GoalState, forGoal id: String) throws {
        guard let index = document.goals.firstIndex(where: { $0.id == id }) else { return }
        document.goals[index].state = state
        try save()
    }

    /// Atomic write so a crash mid-save can never leave a half-written ledger — a
    /// corrupt ledger would silently amnesia the whole mission. Pretty-printed because
    /// the file doubles as a user-editable artifact.
    private func save() throws {
        document.updatedAt = Update.timestamp()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
