// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// Session routing: the production port of evals/tmux-routing. The eval harness's
// baseline router (router_baseline.py) and scenario corpus are the spec — the rules
// here must stay decision-for-decision identical to it, because the corpus is the
// regression suite that keeps this port honest. Change the rules there first, get the
// corpus green, then mirror the change here.

/// One registered task→session mapping — the schema of `registry.example.json`.
///
/// Registration is a ROUTING fact, not a security boundary — it was described as one here
/// until the private-socket design landed, and that description is now simply false. What
/// keeps the daemon out of the human's sessions is the socket: its shell runs on its own
/// tmux server, where those sessions do not exist. `TmuxSendGuard` never reads a session
/// name out of this file (it checks only whether the file exists, as one of three reasons
/// to arm), and the app enforces nothing at all. What registration decides is which
/// sessions the model is told are its own work.
public struct SessionRegistration: Codable, Equatable, Sendable {
    public var session: String
    public var kind: String
    public var agent: String?
    public var cwd: String?
    /// The routing vocabulary: lowercase phrases the user is likely to use for work
    /// belonging to this session. One task phrase should belong to exactly one
    /// session — collisions surface as `clarify`, never a silent pick.
    public var tasks: [String]
    public var registeredBy: String?
    /// True for sessions Fin itself spawned (auto-registered), so the registry can
    /// distinguish them from ones the user handed over explicitly.
    public var createdByFin: Bool

    enum CodingKeys: String, CodingKey {
        case session, kind, agent, cwd, tasks
        case registeredBy = "registered_by"
        case createdByFin = "created_by_fin"
    }

    public init(
        session: String,
        kind: String = "coding-agent",
        agent: String? = nil,
        cwd: String? = nil,
        tasks: [String] = [],
        registeredBy: String? = nil,
        createdByFin: Bool = false
    ) {
        self.session = session
        self.kind = kind
        self.agent = agent
        self.cwd = cwd
        self.tasks = tasks
        self.registeredBy = registeredBy
        self.createdByFin = createdByFin
    }

    /// Lenient by hand: the registry is a user-editable working-memory artifact, and
    /// the router only truly needs `session` + `tasks` — a hand-trimmed entry must
    /// not brick loading the whole document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "coding-agent"
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        tasks = try container.decodeIfPresent([String].self, forKey: .tasks) ?? []
        registeredBy = try container.decodeIfPresent(String.self, forKey: .registeredBy)
        createdByFin = try container.decodeIfPresent(Bool.self, forKey: .createdByFin) ?? false
    }
}

/// The persistent task→session registry document (`{"version": 1, "sessions": [...]}`).
/// A first-class artifact, not prompt text: it survives restarts and is what both the
/// router and the send-keys guardrail consult.
public struct RegistryDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sessions: [SessionRegistration]

    public init(version: Int = RegistryDocument.currentVersion, sessions: [SessionRegistration] = []) {
        self.version = version
        self.sessions = sessions
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// The registry's on-disk basename, identical on every platform. Each platform
    /// picks its own MACHINE-SCOPED directory — a tmux session exists on exactly one
    /// machine, so this file must never travel through CloudKit or any other synced
    /// store, or every other device would learn to route into sessions it can't
    /// reach. The app uses Application Support (`RoutingRegistryLocation`);
    /// fin-agentd uses its state directory, next to the audit log.
    public static let standardFileName = "routing-registry.json"

    public static func load(from url: URL) throws -> RegistryDocument {
        try JSONDecoder().decode(RegistryDocument.self, from: Data(contentsOf: url))
    }

    /// Synchronous best-effort read for prompt composition, where the async
    /// `SessionRoutingRegistry` actor can't be awaited. Absent file → nil, the
    /// "no registry, zero prompt change" gate. A file that exists but won't decode
    /// is ALSO nil: the per-entry decoder is already lenient, so what's left here is
    /// a registry mangled beyond salvage, and dropping the routing section beats
    /// bricking prompt composition.
    public static func loadIfPresent(at url: URL) -> RegistryDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? load(from: url)
    }
}

/// One routing decision, serializing to the exact JSON contract the eval harness
/// scores (`{"action": "route"|"start"|"clarify"|"refuse", "session"?, "task"?,
/// "question"?, "reason"}`) — a model-backed router and this deterministic one must
/// be interchangeable on the wire.
public enum RoutingDecision: Equatable, Sendable {
    /// Deliver to an existing, registered session.
    case route(session: String, reason: String)
    /// Create a new coding-agent session for this task.
    case start(task: String, reason: String)
    /// Ambiguous — ask the user instead of guessing.
    case clarify(question: String, reason: String)
    /// Target exists but is not registered/fin-created — off-limits.
    case refuse(reason: String)

    /// The JSON discriminator, exposed so callers (and tests) can bucket decisions
    /// without pattern-matching every payload.
    public var action: String {
        switch self {
        case .route: return "route"
        case .start: return "start"
        case .clarify: return "clarify"
        case .refuse: return "refuse"
        }
    }

    public var reason: String {
        switch self {
        case .route(_, let reason), .start(_, let reason),
             .clarify(_, let reason), .refuse(let reason):
            return reason
        }
    }
}

extension RoutingDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case action, session, task, question, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let reason = try container.decode(String.self, forKey: .reason)
        switch action {
        case "route":
            self = .route(session: try container.decode(String.self, forKey: .session), reason: reason)
        case "start":
            self = .start(task: try container.decode(String.self, forKey: .task), reason: reason)
        case "clarify":
            self = .clarify(question: try container.decode(String.self, forKey: .question), reason: reason)
        case "refuse":
            self = .refuse(reason: reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "unknown routing action '\(action)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(reason, forKey: .reason)
        switch self {
        case .route(let session, _): try container.encode(session, forKey: .session)
        case .start(let task, _): try container.encode(task, forKey: .task)
        case .clarify(let question, _): try container.encode(question, forKey: .question)
        case .refuse: break
        }
    }
}

/// Deterministic session router — a faithful port of `router_baseline.py`, whose four
/// rules went 26/26 on the scenario corpus. Pure function of (query, registry, live
/// sessions); the caller supplies `liveSessions` from `tmux list-sessions`, so the
/// router handles registry entries whose sessions died (route → start) and live
/// sessions the registry has never heard of (never route to them).
public enum SessionRouter {
    /// Phrasing that explicitly asks for a NEW session/agent — this outranks any
    /// existing task-vocabulary match ("spin up a fresh session for the newsletter
    /// work" is a start, not a route to africanintellect).
    private static let newSessionPattern =
        #"(?i)\b(start|spin up|launch|create|open)\b.{0,24}\b(new|fresh|another)\b"#
        + #"|(?i)\b(new|fresh)\b.{0,16}\b(session|agent|window|terminal)\b"#

    /// Session-ish context words that arm the guardrail check. Deliberate
    /// simplification, inherited from the baseline: a live session named "main" and
    /// the sentence "the main thing is ..." must NOT trip refuse (no session word),
    /// but "type this into the main window" must — which is the case that matters.
    private static let sessionContextPattern = #"(?i)\b(session|window|tmux|terminal)\b"#

    public static func decide(
        query: String,
        registry: RegistryDocument,
        liveSessions: [String]
    ) -> RoutingDecision {
        let sessions = registry.sessions
        // Last entry wins on a duplicate name, mirroring the baseline's dict build.
        let registered = Dictionary(sessions.map { ($0.session, $0) }, uniquingKeysWith: { _, last in last })

        // 1. Guardrail surface: live-but-unregistered session named in a session-ish
        //    context. Fin never types into sessions nobody registered.
        if matches(sessionContextPattern, in: query) {
            for name in liveSessions where registered[name] == nil && wordMentioned(name, in: query) {
                return .refuse(
                    reason: "'\(name)' exists but is not registered with Fin; "
                        + "register it before Fin will send keys there."
                )
            }
        }

        // 2. Explicit request for a new session. The best task match only seeds the
        //    new session's task label; first strictly-greater score wins, matching
        //    Python max()'s first-maximum semantics.
        if matches(newSessionPattern, in: query) {
            var bestScore = 0
            var bestFirstTask: String?
            for entry in sessions {
                let score = taskScore(entry, query: query)
                if score > bestScore {
                    bestScore = score
                    bestFirstTask = entry.tasks.first
                }
            }
            // `?? "unspecified"` alone would keep an empty-string first task; the
            // baseline's `task or "unspecified"` treats "" as falsy, so mirror that.
            let seed = bestScore > 0 ? bestFirstTask : nil
            return .start(
                task: seed.flatMap { $0.isEmpty ? nil : $0 } ?? "unspecified",
                reason: "query explicitly asks for a new session/agent"
            )
        }

        // 3. Direct mention of a registered session's name. Naming TWO registered
        //    sessions is inherently ambiguous — ask, don't pick whichever the loop
        //    happened to reach first.
        var named: [String] = []
        for entry in sessions where !named.contains(entry.session) && wordMentioned(entry.session, in: query) {
            named.append(entry.session)
        }
        if named.count > 1 {
            return .clarify(
                question: "This mentions \(named.joined(separator: " and ")) — which session should act?",
                reason: "query names more than one registered session"
            )
        }
        if let name = named.first {
            if liveSessions.contains(name) {
                return .route(session: name, reason: "query names registered session '\(name)'")
            }
            return .start(
                task: registered[name]?.tasks.first ?? "unspecified",
                reason: "registered session '\(name)' is not running; recreate it"
            )
        }

        // 4. Task-vocabulary scoring. The index tiebreak keeps the sort stable the
        //    way Python's list.sort is — Swift's sort makes no stability promise,
        //    and the tie check below compares the top two IN registry order.
        var scored: [(index: Int, entry: SessionRegistration, score: Int)] = []
        for (index, entry) in sessions.enumerated() {
            let score = taskScore(entry, query: query)
            if score > 0 { scored.append((index: index, entry: entry, score: score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        guard let top = scored.first else {
            return .clarify(
                question: "Which project/session is this for?",
                reason: "no registered task vocabulary matched"
            )
        }
        if scored.count > 1, top.score == scored[1].score {
            let names = scored.prefix(2).map { $0.entry.session }
            return .clarify(
                question: "This could belong to \(names.joined(separator: " or ")) — which one?",
                reason: "task vocabulary matched multiple sessions equally"
            )
        }
        let name = top.entry.session
        if liveSessions.contains(name) {
            return .route(session: name, reason: "task vocabulary matched '\(name)'")
        }
        return .start(
            task: top.entry.tasks.first ?? "unspecified",
            reason: "task matched '\(name)' but that session is not running"
        )
    }

    /// Whole-word, case-insensitive mention — names and phrases are escaped so a
    /// registry entry can never smuggle regex syntax into the match.
    private static func wordMentioned(_ name: String, in query: String) -> Bool {
        let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        return matches(pattern, in: query)
    }

    /// Sum of lengths of matched task phrases — longer phrases are stronger
    /// evidence, and multiple hits accumulate.
    private static func taskScore(_ entry: SessionRegistration, query: String) -> Int {
        let lowered = query.lowercased()
        var score = 0
        for phrase in entry.tasks {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase.lowercased()) + #"\b"#
            if matches(pattern, in: lowered) {
                score += phrase.count
            }
        }
        return score
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

extension SessionRouter {
    /// How this host lets the model look at a session that is not its own. The paragraph
    /// the model reads is different in the two cases, and shipping the wrong one is not a
    /// cosmetic slip: on the daemon's private socket `tmux capture-pane -p -t main` prints
    /// `can't find session: main`, so a model told to read that way reports the human's
    /// live session as dead instead of calling `read_session`.
    public enum OtherSessionAccess {
        /// The Fin app: one SSH session, one tmux server, every session on it visible to
        /// the shell.
        case sameTmuxServer
        /// The daemon on a private socket: the shell sees only Fin's own server, and
        /// `read_session` is the one path to the rest of the machine.
        case readSessionTool
    }

    /// The system-prompt block that teaches the model the routing taxonomy and the
    /// guardrail (derived from evals/tmux-routing/prompts/router.md), with the live
    /// registry rendered inline so the model can actually route. Nil for an empty
    /// registry: an agent with no registered sessions must see zero prompt change —
    /// the section would only invite the model to invent terminal work it cannot do.
    public static func promptSection(
        registry: RegistryDocument,
        otherSessions: OtherSessionAccess = .sameTmuxServer
    ) -> String? {
        guard !registry.isEmpty else { return nil }
        let entries = registry.sessions.map { entry -> String in
            var line = "- \(entry.session) (\(entry.kind)"
            if let agent = entry.agent { line += ", \(agent)" }
            line += ")"
            if let cwd = entry.cwd { line += " in \(cwd)" }
            if !entry.tasks.isEmpty {
                line += " — tasks: \(entry.tasks.joined(separator: ", "))"
            }
            return line
        }
        // Guidance text tracks evals/tmux-routing/prompts/router.md (round-3
        // prompt, 49/51 on the corpus) — edit THERE first, re-score, then sync
        // here. The "Session routing:" and "OFF-LIMITS" markers are load-bearing:
        // the prompt-gating tests key on them, so BOTH variants below carry them.
        //
        // The "sessions you start yourself" sentence below was corrected in both
        // places on 2026-09-06: the old wording claimed created sessions were
        // registered automatically, which nothing in this codebase has ever done
        // (SessionRegistryStore.register has no caller), so once TmuxCommandGuard
        // began enforcing the allow-list a created session could not be driven at
        // all. `fin-` is the namespace that makes `start` work end to end.
        //
        // ONE DELIBERATE EXCEPTION: the "OFF-LIMITS means writing, not looking"
        // paragraph is production-only and is NOT mirrored into router.md. It
        // describes a mechanism the eval harness implements separately (its
        // GuardedTmuxExecutor) rather than a routing rule the corpus scores, and the
        // corpus grades ROUTING DECISIONS, not tool syntax — adding it there would
        // change the scored prompt without changing any decision it grades. Its
        // production counterpart is TmuxCommandGuard, whose own tests are the
        // regression suite for what it claims.
        //
        // THIS PARAGRAPH STATES THE RULE; IT MUST NOT CLAIM CODE ENFORCEMENT. Its
        // first draft said "the write half is enforced in code… that refusal is
        // final" — but this section is not daemon-only: AgentRuntime renders it in
        // the Fin app too (fin/Agent/AgentRuntime.swift, wired at finApp.swift from
        // the app's own registry), and the app's send path has no TmuxCommandGuard
        // at all (`AgentTurnEngine.tmuxGuard` defaults to `.unenforced` and nothing
        // app-side assigns it). An app user in auto-approve mode would have been
        // promised a gate that does not exist there — the same false "enforced, not
        // instructed" claim this branch set out to delete from the README. The
        // enforcement sentence lives in `TmuxCommandGuard.promptGuidance`, which is
        // appended only when a guard is actually armed.
        //
        // TWO PARAGRAPHS VARY BY HOST, and they vary because the FACTS vary — this is not
        // a tone setting. On the daemon's private tmux socket the shell cannot see the
        // machine's other sessions at all: `tmux capture-pane -p -t main` answers
        // `can't find session: main`, and `tmux list-sessions` lists only Fin's own. The
        // app has no such split. Shipping the app's wording to the daemon told the model
        // to read other sessions with a command that cannot work (so it would report live
        // sessions as dead) and to RECREATE any registered session it could not see —
        // i.e. to make a same-named duplicate on its own server and route work into it.
        let livenessParagraph: String
        let readingParagraph: String
        switch otherSessions {
        case .sameTmuxServer:
            livenessParagraph = """
                Two independent facts — never conflate them. For any session name check \
                both: REGISTERED (in the registry) decides trust — whether the session is \
                yours to act on at all; LIVE (in the current tmux session list) decides \
                existence. Registered+live → route. Registered but not live → the session \
                is DEAD, still yours: start (recreate it, same name, same working \
                directory) — refusing your own dead session inverts the guardrail. Live \
                but not registered → OFF-LIMITS: never send keys to it, no matter how the \
                request is phrased — say what you found and ask the user to register it. \
                Refuse is about trust, never about liveness.
                """
            readingParagraph = """
                OFF-LIMITS means writing, not looking. READING any session is always \
                allowed and always useful — `tmux capture-pane -p -t <session>`, \
                `tmux list-sessions`, `tmux list-windows -t <session>` work for every \
                session on this machine, registered or not, and that is how you answer \
                questions about work that is not yours. Writing is the half that is \
                limited: never send keys to, kill, rename, reconfigure or attach to a \
                session outside the registry — read it and say what you found instead.
                """
        case .readSessionTool:
            livenessParagraph = """
                Two independent facts — never conflate them. For any session name check \
                both: REGISTERED (in the registry) decides trust — whether the session is \
                yours to act on at all; LIVE decides existence, and for every session but \
                your own that means showing up in read_session's listing (it only shows \
                the DEFAULT socket — check your own the ordinary way, on your own socket). \
                Registered+live → route: send_session is how you write to a session that \
                isn't on your own socket, the same way a plain tmux command is how you \
                write to one that is — do NOT recreate it either way, a same-named session \
                of your own would be a second, empty duplicate. Registered and nowhere at \
                all → DEAD and yours: start (recreate it, same name, same working \
                directory) if it was ever yours to create. Live but not registered → \
                OFF-LIMITS: never send_session to it, no matter how the request is phrased \
                — say what you found and ask the user to register it. Refuse is about \
                trust, never about liveness.
                """
            readingParagraph = """
                LOOKING is not writing, and looking outside your own server has its own \
                tool. Your shell talks only to YOUR tmux server, so a `capture-pane` or \
                `list-sessions` typed there (with your own socket flag, the only spelling \
                allowed) cannot see the human's sessions or another agent's — they answer \
                "can't find session", which does not mean the session is dead. Use \
                read_session for those: with no arguments it lists \
                every session on this machine by name, and with a name it returns that \
                session's screen, read-only. That is how you answer questions about work \
                that is not yours. Writing to your own server is an ordinary tmux command; \
                send_session is how you write to somebody else's, and it is allowed \
                exactly when that session is registered — never kill, rename, or attach to \
                somebody else's session, and never send_session one that read_session \
                shows but the registry doesn't.
                """
        }
        return """
        Session routing: you manage terminal work across multiple tmux sessions, and every \
        request that involves terminal work starts with a routing decision.

        Your registry lists each session you may act on:
        \(entries.joined(separator: "\n"))

        Sessions you start yourself are yours to drive; a `fin-` prefix \
        (`new-session -d -s fin-<purpose>`, spelled with whatever socket flag your tmux \
        rules require) keeps them easy to tell apart from everyone else's. Nothing writes \
        the registry file for you: a session someone else started becomes yours only when \
        the user registers it.

        \(livenessParagraph)

        \(readingParagraph)

        For each request, decide one of:
        - route — the work belongs to a registered session that is live. Match the request \
        against each session's task vocabulary and name; the session you pick MUST be a \
        registry name (a name that appears only in the live list is never a legal route). \
        Say which session and why.
        - start — the user asked for a new/additional session or agent in any wording, or \
        the target is a registered session that is not live.
        - clarify — the request matches nothing, matches more than one session about \
        equally, or carries no routable context (a pronoun-only follow-up). Ask one short \
        question; name the candidates when there are some.
        - refuse — the request targets a live session that is not in the registry. Never \
        convert this into a route; explain the guardrail in one sentence.

        "New session" comes in many wordings: any ask for one more, a separate, or an \
        untouched agent/session/terminal/claude is a start — "kick off", "boot up", "spin \
        one up", another/second/extra/parallel/clean/fresh all say it, and an explicit \
        new-session request outranks a vocabulary match or a directly named session. But \
        start is ONLY for session lifecycle: when the object of the verb is a feature, \
        rollout, process, or config — not a session — "set up"/"create"/"build" is \
        ordinary work; route it to the session that owns the domain.

        A mention is not a target. Find the main imperative first: temporal, contrastive, \
        or comparative clauses ("while X runs...", "unlike X...", "like we did for X") may \
        name other sessions but never set the target. Vocabulary is evidence, not a \
        whitelist — a paraphrase plainly describing a session's domain routes there with \
        zero word overlap, but generic engineering words ("tests", "build", "logs", \
        "status") carry no signal alone: with no domain word to anchor them, clarify. \
        Never refuse on a word collision — an ordinary word equal to an unregistered \
        session's name only trips the guardrail when the user points at it AS a terminal \
        ("the X session", "type ... into X"). Requests about the physical world (booking \
        people, buying things) are not terminal work — clarify. And when the user \
        genuinely wants work in two registered sessions, a single route is wrong either \
        way — clarify which first, naming them.

        When you drive a coding agent in a session you routed to: send one instruction at \
        a time as a single line; wait for the agent's response (its prompt returning, or \
        an acknowledgement) before sending the next; quote the agent's actual output when \
        reporting back rather than paraphrasing from memory; and never send interrupts or \
        control sequences unless the user asked for them. If the agent seems stuck, \
        surface that — do not improvise recovery in someone else's session.

        Keep the registry current: when you create a session, record it (name, kind, cwd, \
        initial task words). When the user's words route successfully, you may add them to \
        that session's vocabulary. When a registered session drops out of the live list, \
        keep its entry — that is exactly what lets you recreate it on demand.
        """
    }
}

/// Owns the on-disk registry file. An actor because both the runtime (prompt refresh,
/// vocabulary learning) and future session-creation paths mutate it, and interleaved
/// read-modify-write would silently drop registrations.
public actor SessionRoutingRegistry {
    private let fileURL: URL
    public private(set) var document: RegistryDocument

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.document = RegistryDocument()
    }

    /// A missing file is an empty registry, not an error — nothing has been
    /// registered yet on a fresh install, and the prompt gate treats both the same.
    @discardableResult
    public func load() throws -> RegistryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            document = RegistryDocument()
            return document
        }
        document = try RegistryDocument.load(from: fileURL)
        return document
    }

    /// Upsert by session name: re-registering an existing session replaces its entry
    /// wholesale, so a recreated session's fresh cwd/tasks never merge with stale ones.
    public func register(_ entry: SessionRegistration) throws {
        if let index = document.sessions.firstIndex(where: { $0.session == entry.session }) {
            document.sessions[index] = entry
        } else {
            document.sessions.append(entry)
        }
        try save()
    }

    /// Vocabulary learning: append phrases that routed successfully. Lowercased to
    /// match how `taskScore` compares, deduped so repeat routes don't inflate the
    /// phrase-length scoring.
    public func appendTasks(_ phrases: [String], toSession name: String) throws {
        guard let index = document.sessions.firstIndex(where: { $0.session == name }) else { return }
        var appended = false
        for raw in phrases {
            let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !phrase.isEmpty, !document.sessions[index].tasks.contains(phrase) {
                document.sessions[index].tasks.append(phrase)
                appended = true
            }
        }
        if appended { try save() }
    }

    /// Atomic write so a crash mid-save can never leave a half-written registry —
    /// a corrupt registry would silently disarm the send-keys guardrail's data source.
    /// Pretty-printed because the file doubles as a user-editable artifact.
    private func save() throws {
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
