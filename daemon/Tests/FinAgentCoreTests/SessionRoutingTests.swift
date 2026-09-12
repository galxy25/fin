import XCTest
@testable import FinAgentCore

/// The Swift router scored against evals/tmux-routing/scenarios.json. Scenario IDs in
/// the test names refer to that corpus — it is the spec, and the baseline these were
/// ported from goes 26/26 on it. If a decision here needs to change, change the corpus
/// and baseline first.
final class SessionRoutingTests: XCTestCase {

    // Mirrors evals/tmux-routing/registry.example.json.
    private let registry = RegistryDocument(sessions: [
        SessionRegistration(
            session: "fin",
            agent: "claude-code",
            cwd: "~/forges/levi/fin",
            tasks: ["fin", "ios app", "tvos", "widget", "testflight", "voice intent", "app store"],
            registeredBy: "levi"
        ),
        SessionRegistration(
            session: "pocketdj",
            agent: "claude-code",
            cwd: "~/forges/levi/pocketdj",
            tasks: ["pocketdj", "dj", "screen recording", "audio engine"],
            registeredBy: "levi"
        ),
        SessionRegistration(
            session: "africanintellect",
            agent: "claude-code",
            cwd: "~/forges/levi/africanintellect",
            tasks: ["africanintellect", "grants", "newsletter", "nonprofit", "board packet"],
            registeredBy: "levi"
        ),
    ])

    private let defaultLive = ["fin", "pocketdj", "africanintellect"]

    private func decide(_ query: String, live: [String]? = nil) -> RoutingDecision {
        SessionRouter.decide(query: query, registry: registry, liveSessions: live ?? defaultLive)
    }

    private func assertRoutes(_ query: String, to session: String, live: [String]? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        let decision = decide(query, live: live)
        guard case .route(let routed, _) = decision else {
            return XCTFail("expected route to '\(session)', got \(decision)", file: file, line: line)
        }
        XCTAssertEqual(routed, session, file: file, line: line)
    }

    // MARK: - route

    func testR01FinTaskWordsLandOnFinSession() {
        // The motivating case: "widget" belongs to fin's vocabulary.
        assertRoutes("fix the fin widget build", to: "fin")
    }

    func testR02TestflightVocabularyRoutesToFin() {
        assertRoutes("the testflight upload failed again, take a look", to: "fin")
    }

    func testR03MultiWordPhraseRoutesToPocketdj() {
        // "audio engine" only matches as a whole phrase — "engine" alone is nobody's.
        assertRoutes("add a crossfade to the audio engine", to: "pocketdj")
    }

    func testR06DirectRegisteredNameMentionRoutes() {
        assertRoutes("in the pocketdj session, rerun the tests", to: "pocketdj")
    }

    func testR07NamingFinRoutesToFin() {
        assertRoutes("tell fin to rebuild the tvos target", to: "fin")
    }

    func testR11UnregisteredNameWithoutSessionContextDoesNotRefuse() {
        // Negative guardrail test: "main" is live but unregistered, yet the sentence
        // has no session-context word — it must route on "fin", not trip refuse.
        assertRoutes(
            "the main thing is the widget - fix it in fin",
            to: "fin",
            live: ["fin", "pocketdj", "africanintellect", "main"]
        )
    }

    // MARK: - start

    func testS01ExplicitNewAgentStarts() {
        let decision = decide("start a new agent to prototype a rust rewrite")
        guard case .start(let task, _) = decision else {
            return XCTFail("expected start, got \(decision)")
        }
        // No vocabulary matched, so the new session gets no inherited task label.
        XCTAssertEqual(task, "unspecified")
    }

    func testS01bExplicitNewWithEmptyFirstTaskSeedsUnspecified() {
        // Baseline parity: Python's `task or "unspecified"` treats an empty-string
        // first task as falsy. A registry whose matched session leads with "" must
        // still seed "unspecified", not "".
        let degenerate = RegistryDocument(sessions: [
            SessionRegistration(session: "deploys", tasks: ["", "deploy work"])
        ])
        let decision = SessionRouter.decide(
            query: "start a new agent for deploy work",
            registry: degenerate,
            liveSessions: ["deploys"]
        )
        guard case .start(let task, _) = decision else {
            return XCTFail("expected start, got \(decision)")
        }
        XCTAssertEqual(task, "unspecified")
    }

    func testS02ExplicitNewOutranksExistingTaskMatch() {
        // "newsletter" matches africanintellect, but "spin up a fresh session" is an
        // explicit start and must win.
        guard case .start = decide("spin up a fresh session for the newsletter work") else {
            return XCTFail("expected start")
        }
    }

    func testS05TaskMatchingDeadSessionRecreatesIt() {
        let decision = decide("work on the pocketdj mixing bug", live: ["fin", "africanintellect"])
        guard case .start(let task, _) = decision else {
            return XCTFail("expected start, got \(decision)")
        }
        XCTAssertEqual(task, "pocketdj")
    }

    func testS06DirectNameOfDeadSessionRecreatesIt() {
        let decision = decide(
            "in the pocketdj session, continue where we left off",
            live: ["fin", "africanintellect"]
        )
        guard case .start(let task, _) = decision else {
            return XCTFail("expected start, got \(decision)")
        }
        XCTAssertEqual(task, "pocketdj")
    }

    // MARK: - clarify

    func testC01NoVocabularyMatchAsksInsteadOfGuessing() {
        guard case .clarify = decide("run the tests") else {
            return XCTFail("expected clarify")
        }
    }

    func testC02GenericBuildFixAsks() {
        guard case .clarify = decide("fix the build") else {
            return XCTFail("expected clarify")
        }
    }

    func testC03NamingTwoRegisteredSessionsAsks() {
        let decision = decide("sync ideas between pocketdj and africanintellect")
        guard case .clarify(let question, _) = decision else {
            return XCTFail("expected clarify, got \(decision)")
        }
        // Both candidates must be surfaced so the user can answer in one word.
        XCTAssertTrue(question.contains("pocketdj"))
        XCTAssertTrue(question.contains("africanintellect"))
    }

    // MARK: - refuse

    func testF01LiveUnregisteredSessionIsOffLimits() {
        let decision = decide(
            "type ls into the main window",
            live: ["fin", "pocketdj", "africanintellect", "main"]
        )
        guard case .refuse(let reason) = decision else {
            return XCTFail("expected refuse, got \(decision)")
        }
        XCTAssertTrue(reason.contains("main"))
        XCTAssertTrue(reason.contains("register"))
    }

    func testF03TmuxContextWordArmsTheGuardrail() {
        guard case .refuse = decide(
            "use tmux to talk to the deploy window",
            live: ["fin", "pocketdj", "africanintellect", "deploy"]
        ) else {
            return XCTFail("expected refuse")
        }
    }

    // MARK: - JSON contract

    func testDecisionEncodingMatchesEvalHarnessContract() throws {
        let decisions: [(RoutingDecision, [String: String])] = [
            (.route(session: "fin", reason: "r"), ["action": "route", "session": "fin", "reason": "r"]),
            (.start(task: "widget", reason: "r"), ["action": "start", "task": "widget", "reason": "r"]),
            (.clarify(question: "which?", reason: "r"), ["action": "clarify", "question": "which?", "reason": "r"]),
            (.refuse(reason: "r"), ["action": "refuse", "reason": "r"]),
        ]
        for (decision, expected) in decisions {
            let data = try JSONEncoder().encode(decision)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(object, expected)
            XCTAssertEqual(try JSONDecoder().decode(RoutingDecision.self, from: data), decision)
        }
    }

    func testRegistryDecodesTheExampleSchema() throws {
        let json = Data("""
        {
          "version": 1,
          "sessions": [
            {
              "session": "fin",
              "kind": "coding-agent",
              "agent": "claude-code",
              "cwd": "~/forges/levi/fin",
              "tasks": ["fin", "widget"],
              "registered_by": "levi",
              "created_by_fin": false
            }
          ]
        }
        """.utf8)
        let document = try JSONDecoder().decode(RegistryDocument.self, from: json)
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.sessions.first?.session, "fin")
        XCTAssertEqual(document.sessions.first?.registeredBy, "levi")
        XCTAssertEqual(document.sessions.first?.createdByFin, false)
    }

    // MARK: - registry persistence

    func testRegistryActorRoundTripsAndLearnsVocabulary() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionRoutingRegistry(fileURL: url)
        // A registry that has never been written must load as empty, not throw.
        let empty = try await store.load()
        XCTAssertTrue(empty.isEmpty)

        try await store.register(SessionRegistration(
            session: "fin",
            cwd: "~/forges/levi/fin",
            tasks: ["fin", "widget"],
            createdByFin: true
        ))
        // Duplicates and case variants must not inflate the phrase-length scoring.
        try await store.appendTasks(["TestFlight", "widget", "  "], toSession: "fin")

        let reloaded = try await SessionRoutingRegistry(fileURL: url).load()
        XCTAssertEqual(reloaded.sessions.count, 1)
        XCTAssertEqual(reloaded.sessions.first?.tasks, ["fin", "widget", "testflight"])
        XCTAssertEqual(reloaded.sessions.first?.createdByFin, true)
    }

    // MARK: - observeDiscoveredSession / setActivityNote

    private func makeStore() -> (store: SessionRoutingRegistry, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
        return (SessionRoutingRegistry(fileURL: url), url)
    }

    func testObserveDiscoveredSessionRegistersANewSessionAsCreatedByFin() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.observeDiscoveredSession(
            session: "newthing", kind: "coding-agent", cwd: "/Users/levi/newthing",
            agent: nil, agentPaneTarget: "newthing:0.0", registeredBy: "fin-agentd (auto)"
        )

        let doc = await store.document
        XCTAssertEqual(doc.sessions.count, 1)
        let entry = doc.sessions[0]
        XCTAssertEqual(entry.session, "newthing")
        XCTAssertEqual(entry.kind, "coding-agent")
        XCTAssertEqual(entry.cwd, "/Users/levi/newthing")
        XCTAssertEqual(entry.agentPaneTarget, "newthing:0.0")
        XCTAssertTrue(entry.createdByFin)
    }

    func testObserveDiscoveredSessionNeverClobbersAHandRegisteredEntry() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.register(SessionRegistration(
            session: "fin", kind: "coding-agent", cwd: "~/forges/levi/fin",
            tasks: ["fin"], registeredBy: "levi", createdByFin: false
        ))

        // A scan sees this session running a plain shell now — must not downgrade kind
        // or rewrite cwd on a hand-registered entry. It MAY attach the pane target
        // (once): that is how the activity summarizer learns where a hand-registered
        // coding-agent session's agent lives.
        try await store.observeDiscoveredSession(
            session: "fin", kind: "shell", cwd: "/somewhere/else",
            agent: nil, agentPaneTarget: "fin:0.0",
            discoveredTasks: ["widget"], registeredBy: "fin-agentd (auto)"
        )

        let doc = await store.document
        XCTAssertEqual(doc.sessions.count, 1)
        let entry = doc.sessions[0]
        XCTAssertEqual(entry.kind, "coding-agent", "kind must stay as the human set it")
        XCTAssertEqual(entry.cwd, "~/forges/levi/fin", "cwd must stay as the human set it")
        XCTAssertEqual(entry.agentPaneTarget, "fin:0.0", "discovery may tell a hand-registered entry where its agent lives")
        // …but never overwrites one already set.
        try await store.observeDiscoveredSession(
            session: "fin", kind: "shell", cwd: nil, agent: nil, agentPaneTarget: "fin:9.9",
            registeredBy: "fin-agentd (auto)"
        )
        let after = await store.document
        XCTAssertEqual(after.sessions[0].agentPaneTarget, "fin:0.0")
        // Vocabulary IS allowed to grow additively — same rule a successful route uses.
        XCTAssertEqual(entry.tasks, ["fin", "widget"])
    }

    func testObserveDiscoveredSessionUpdatesAFinCreatedEntryAndUnionsTasks() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.register(SessionRegistration(
            session: "fin-auto", kind: "shell", cwd: "/old/cwd",
            tasks: ["alpha"], createdByFin: true
        ))

        try await store.observeDiscoveredSession(
            session: "fin-auto", kind: "coding-agent", cwd: "/new/cwd",
            agent: "claude-code", agentPaneTarget: "fin-auto:1.0",
            discoveredTasks: ["alpha", "beta"], registeredBy: "fin-agentd (auto)"
        )

        let doc = await store.document
        let entry = doc.sessions[0]
        XCTAssertEqual(entry.kind, "coding-agent")
        XCTAssertEqual(entry.cwd, "/new/cwd")
        XCTAssertEqual(entry.agent, "claude-code")
        XCTAssertEqual(entry.agentPaneTarget, "fin-auto:1.0")
        XCTAssertEqual(entry.tasks, ["alpha", "beta"], "union, never a replace")
    }

    func testSetActivityNoteWritesNoteAndTimestampForARegisteredSession() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.register(SessionRegistration(session: "fin", createdByFin: true))
        try await store.setActivityNote("Refactoring the routing registry.", forSession: "fin")

        let doc = await store.document
        XCTAssertEqual(doc.sessions[0].activityNote, "Refactoring the routing registry.")
        XCTAssertNotNil(doc.sessions[0].activityNoteUpdatedAt)
    }

    func testSetActivityNoteIsANoOpForAnUnregisteredSession() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Must not throw, must not create an entry.
        try await store.setActivityNote("some note", forSession: "ghost")
        let doc = await store.document
        XCTAssertTrue(doc.sessions.isEmpty)
    }

    // MARK: - synchronous load for prompt composition

    /// Both "no file yet" and "file mangled beyond the lenient decoder" must read as
    /// no registry: dropping the routing section beats bricking prompt composition.
    func testLoadIfPresentTreatsAbsentAndCorruptFilesAsNoRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(RegistryDocument.standardFileName)

        XCTAssertNil(RegistryDocument.loadIfPresent(at: url))
        try Data("not a registry".utf8).write(to: url)
        XCTAssertNil(RegistryDocument.loadIfPresent(at: url))
    }

    func testLoadIfPresentReadsAWrittenRegistry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-routing-load-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(registry).write(to: url)

        let loaded = try XCTUnwrap(RegistryDocument.loadIfPresent(at: url))
        XCTAssertEqual(loaded, registry)
    }

    // MARK: - prompt gating

    func testPromptSectionIsNilForEmptyRegistry() {
        XCTAssertNil(SessionRouter.promptSection(registry: RegistryDocument()))
    }

    func testPromptSectionRendersEverySessionAndTheGuardrail() throws {
        let section = try XCTUnwrap(SessionRouter.promptSection(registry: registry))
        for name in ["fin", "pocketdj", "africanintellect"] {
            XCTAssertTrue(section.contains(name))
        }
        XCTAssertTrue(section.contains("OFF-LIMITS"))
        XCTAssertTrue(section.contains("audio engine"))
    }

    /// Regression guard: on the daemon's private socket EVERY session it might
    /// coordinate with (the human's, another agent's) is by construction "not on its
    /// own server" — visible only through read_session. An earlier draft of the
    /// `.readSessionTool` variant marked exactly that combination (registered, seen via
    /// read_session) OFF-LIMITS for writing, which made send_session — documented in
    /// TmuxSessionSend.swift as "the deliberate, owner-approved exception" for talking
    /// to another agent's session — unreachable for the one case it exists to serve.
    /// The corrected text must route a registered session to send_session and reserve
    /// OFF-LIMITS for the session that is live but NOT registered.
    func testReadSessionToolVariantRoutesARegisteredOffServerSessionToSendSession() throws {
        let section = try XCTUnwrap(
            SessionRouter.promptSection(registry: registry, otherSessions: .readSessionTool)
        )
        XCTAssertTrue(
            section.contains("send_session is how you write to a session that"),
            "a registered session must route to send_session: \(section)"
        )
        XCTAssertFalse(
            section.contains("OFF-LIMITS for writing"),
            "a registered session read_session can see must not be off-limits to write to: \(section)"
        )
        XCTAssertTrue(
            section.contains("Live but not registered → OFF-LIMITS"),
            "an unregistered session must still be off-limits: \(section)"
        )
    }
}
