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
}
