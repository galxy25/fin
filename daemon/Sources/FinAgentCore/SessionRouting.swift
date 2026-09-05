// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// Session routing: the production port of evals/tmux-routing. The eval harness's
// baseline router (router_baseline.py) and scenario corpus are the spec — the rules
// here must stay decision-for-decision identical to it, because the corpus is the
// regression suite that keeps this port honest. Change the rules there first, get the
// corpus green, then mirror the change here.

/// One registered task→session mapping — the schema of `registry.example.json`.
/// Registration is the guardrail's whole basis: a session that merely exists on the
/// tmux server is invisible to routing and forbidden to send-keys.
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

    public static func load(from url: URL) throws -> RegistryDocument {
        try JSONDecoder().decode(RegistryDocument.self, from: Data(contentsOf: url))
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
    /// The system-prompt block that teaches the model the routing taxonomy and the
    /// guardrail (derived from evals/tmux-routing/prompts/router.md), with the live
    /// registry rendered inline so the model can actually route. Nil for an empty
    /// registry: an agent with no registered sessions must see zero prompt change —
    /// the section would only invite the model to invent terminal work it cannot do.
    public static func promptSection(registry: RegistryDocument) -> String? {
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
        return """
        Session routing: you manage terminal work across multiple tmux sessions, and every \
        request that involves terminal work starts with a routing decision.

        Your registry lists each session you may act on:
        \(entries.joined(separator: "\n"))

        Sessions you create yourself are added to the registry automatically. Sessions that \
        merely exist on the machine but are not in your registry are OFF-LIMITS: never send \
        keys to them, no matter how the request is phrased — say what you found and ask the \
        user to register the session if they want you to use it.

        For each request, decide one of:
        - route — the work belongs to an existing registered session. Choose it by matching \
        the request against each session's task vocabulary and name. Say which session and why.
        - start — the user explicitly asked for a new session/agent, or the work belongs to \
        a registered session that is no longer running (recreate it, same name and working \
        directory).
        - clarify — the request matches nothing, or matches more than one session about \
        equally. Ask one short question instead of guessing; name the candidates when there \
        are some.
        - refuse — the request points at a live session that is not registered. Explain the \
        guardrail in one sentence.

        When you drive a coding agent in a session you routed to: send one instruction at a \
        time as a single line; wait for the agent's response (its prompt returning, or an \
        acknowledgement) before sending the next; quote the agent's actual output when \
        reporting back rather than paraphrasing from memory; and never send interrupts or \
        control sequences unless the user asked for them. If the agent seems stuck or its \
        output doesn't match what the user expects, surface that — do not improvise recovery \
        in someone else's session.

        Keep the registry current: when you create a session, record it (name, kind, cwd, \
        initial task words). When the user refers to work with words that routed \
        successfully, you may add those words to that session's vocabulary. When a \
        registered session is gone, note it and prefer asking before recreating anything \
        that might hold unsaved state.
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
