import XCTest
@testable import FinAgentCore

/// The Swift ledger scored against evals/goals-ledger. `ledger.example.json` is the
/// schema spec and the corpus is the decision spec — if a rendering or helper here
/// needs to change, change the eval design first, get the corpus green, then mirror
/// the change in GoalsLedger.swift.
final class GoalsLedgerTests: XCTestCase {

    /// The real eval artifact, reached from this file: the schema round-trip must run
    /// against the byte-for-byte example the eval harness itself starts from, so the
    /// Swift types and the corpus can never quietly fork.
    private var exampleLedgerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // → FinAgentCoreTests/
            .deletingLastPathComponent() // → Tests/
            .deletingLastPathComponent() // → daemon/
            .deletingLastPathComponent() // → repo root
            .appendingPathComponent("evals/goals-ledger/ledger.example.json")
    }

    /// A compact ledger with each decision-relevant shape: an active goal with a next
    /// action, a blocked-and-surfaced goal, and a done-but-unclosed goal.
    private let ledger = LedgerDocument(goals: [
        Goal(
            id: "g-voice-intent",
            title: "Ship the voice intent flow",
            state: .active,
            priority: 1,
            why: "Trigger a run from the Action Button.",
            nextAction: "Wire StartAgentTaskIntent to AgentRuntime.submit.",
            tags: ["voice intent", "siri"],
            updates: [Update(at: "2026-09-05T16:45:00Z", kind: .progress, text: "Capture sheet UI done.")]
        ),
        Goal(
            id: "g-appstore-rejection",
            title: "Clear the App Store 2.1 rejection",
            state: .blocked,
            priority: 1,
            blockedOn: "Levi must record the demo video.",
            tags: ["app store", "rejection"],
            updates: [
                Update(at: "2026-09-04T14:10:00Z", kind: .blocker, text: "Needs Levi's device."),
                Update(at: "2026-09-04T14:12:00Z", kind: .report, text: "Surfaced to Levi."),
            ]
        ),
        Goal(
            id: "g-cloud-worker",
            title: "Cloud-worker control plane",
            state: .done,
            priority: 2,
            tags: ["cloud worker"],
            updates: [Update(at: "2026-09-05T11:02:00Z", kind: .progress, text: "Autoscale verified.")]
        ),
    ])

    // MARK: - schema round-trip vs ledger.example.json

    func testExampleLedgerRoundTripsThroughTheSwiftSchema() throws {
        let data = try Data(contentsOf: exampleLedgerURL)
        let document = try JSONDecoder().decode(LedgerDocument.self, from: data)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.goals.count, 4)
        XCTAssertEqual(
            document.goals.map(\.id),
            ["g-voice-intent", "g-appstore-rejection", "g-routing-registry", "g-cloud-worker"]
        )
        XCTAssertEqual(
            document.goals.map(\.state),
            [.active, .blocked, .open, .done]
        )

        // Every snake_case field survives the trip through the Swift names.
        let blocked = try XCTUnwrap(document.goals.first { $0.id == "g-appstore-rejection" })
        XCTAssertEqual(blocked.priority, 1)
        XCTAssertTrue(try XCTUnwrap(blocked.nextAction).contains("Resolution Center"))
        XCTAssertTrue(try XCTUnwrap(blocked.blockedOn).contains("demo video"))
        XCTAssertEqual(blocked.source, "m-102")
        XCTAssertEqual(blocked.createdAt, "2026-09-04T13:55:00Z")
        XCTAssertEqual(blocked.tags.first, "app store")
        XCTAssertEqual(blocked.updates.map(\.kind), [.blocker, .report])

        // Encode → decode lands on an equal document: nothing is lost or renamed.
        let reencoded = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(LedgerDocument.self, from: reencoded), document)
    }

    /// Lenient decoding, house rule: a hand-trimmed goal (id + title only) loads with
    /// safe defaults, and a typo'd state/kind degrades conservatively (open / note)
    /// instead of bricking the document.
    func testHandEditedLedgerDecodesLeniently() throws {
        let json = Data("""
        {
          "goals": [
            { "id": "g-min", "title": "Minimal goal" },
            { "id": "g-typo", "title": "Typo'd", "state": "actve",
              "updates": [ { "at": "2026-09-05T10:00:00Z", "kind": "progess", "text": "x" } ] }
          ]
        }
        """.utf8)
        let document = try JSONDecoder().decode(LedgerDocument.self, from: json)
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.goals[0].state, .open)
        XCTAssertEqual(document.goals[0].priority, 1)
        XCTAssertEqual(document.goals[0].updates, [])
        XCTAssertEqual(document.goals[1].state, .open)
        XCTAssertEqual(document.goals[1].updates.first?.kind, .note)
    }

    // MARK: - decision helpers (policy_baseline.py parity)

    func testCloseAndBlockerSurfaceHelpersMatchTheBaseline() {
        // done + no close update → still owes its closing report.
        XCTAssertFalse(ledger.goals[2].hasCloseUpdate)
        var closed = ledger.goals[2]
        closed.updates.append(Update(kind: .close, text: "Closed and reported."))
        XCTAssertTrue(closed.hasCloseUpdate)

        // blocker followed by report → surfaced, sits quiet.
        XCTAssertFalse(ledger.goals[1].needsBlockerSurface)
        // report BEFORE the latest blocker doesn't count (_needs_blocker_surface
        // scans only past the last blocker).
        var renagged = ledger.goals[1]
        renagged.updates.append(Update(kind: .blocker, text: "Still stuck, new twist."))
        XCTAssertTrue(renagged.needsBlockerSurface)
        // A blocked goal with no updates at all has never been surfaced.
        XCTAssertTrue(Goal(id: "g", title: "t", state: .blocked).needsBlockerSurface)
    }

    // MARK: - store persistence

    func testStoreRoundTripsAddAppendAndSetState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-tests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = GoalsLedgerStore(fileURL: url)
        // A ledger that has never been written must load as empty, not throw.
        let empty = try await store.load()
        XCTAssertTrue(empty.isEmpty)

        try await store.addGoal(Goal(id: "g-1", title: "First goal", state: .open, priority: 2))
        try await store.appendUpdate(
            Update(at: "2026-09-05T12:00:00Z", kind: .progress, text: "Started."),
            toGoal: "g-1"
        )
        try await store.setState(.active, forGoal: "g-1")
        // Unknown ids are silent no-ops, not corruption.
        try await store.appendUpdate(Update(kind: .note, text: "lost"), toGoal: "g-nope")
        try await store.setState(.done, forGoal: "g-nope")
        // Re-adding an existing id replaces the goal wholesale (upsert, like
        // SessionRoutingRegistry.register) — but here we add a second goal instead.
        try await store.addGoal(Goal(id: "g-2", title: "Second goal"))

        let reloaded = try await GoalsLedgerStore(fileURL: url).load()
        XCTAssertEqual(reloaded.goals.map(\.id), ["g-1", "g-2"])
        XCTAssertEqual(reloaded.goals[0].state, .active)
        XCTAssertEqual(reloaded.goals[0].updates.map(\.text), ["Started."])
        XCTAssertNotNil(reloaded.updatedAt)
    }

    func testStoreUpsertsByGoalID() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-upsert-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = GoalsLedgerStore(fileURL: url)
        try await store.addGoal(Goal(id: "g-1", title: "Old title", state: .active))
        try await store.addGoal(Goal(id: "g-1", title: "New title", state: .open))

        let reloaded = try await GoalsLedgerStore(fileURL: url).load()
        XCTAssertEqual(reloaded.goals.count, 1)
        // Wholesale replacement: fresh fields never merge with stale ones.
        XCTAssertEqual(reloaded.goals.first?.title, "New title")
        XCTAssertEqual(reloaded.goals.first?.state, .open)
    }

    // MARK: - synchronous load for prompt composition

    /// Both "no file yet" and "file mangled beyond the lenient decoders" must read as
    /// no ledger: dropping the mission section beats bricking prompt composition.
    func testLoadIfPresentTreatsAbsentAndCorruptFilesAsNoLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(LedgerDocument.standardFileName)

        XCTAssertNil(LedgerDocument.loadIfPresent(at: url))
        try Data("not a ledger".utf8).write(to: url)
        XCTAssertNil(LedgerDocument.loadIfPresent(at: url))
    }

    func testLoadIfPresentReadsAWrittenLedger() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-goals-load-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(ledger).write(to: url)

        let loaded = try XCTUnwrap(LedgerDocument.loadIfPresent(at: url))
        XCTAssertEqual(loaded, ledger)
    }

    // MARK: - prompt gating

    func testPromptSectionIsNilForEmptyLedger() {
        XCTAssertNil(GoalsTick.promptSection(ledger: LedgerDocument()))
    }

    func testPromptSectionRendersEveryGoalAndTheTaxonomy() throws {
        let section = try XCTUnwrap(GoalsTick.promptSection(ledger: ledger))
        XCTAssertTrue(section.hasPrefix("Mission ledger:"))
        for title in ["Ship the voice intent flow", "Clear the App Store 2.1 rejection", "Cloud-worker control plane"] {
            XCTAssertTrue(section.contains(title))
        }
        // The five-decision taxonomy and the copilot conduct ride in whole.
        for decision in ["ingest", "drive", "report", "idle", "clarify"] {
            XCTAssertTrue(section.contains("- \(decision) — "))
        }
        // The idempotency facts the ledger knows are rendered, not left to memory.
        XCTAssertTrue(section.contains("already surfaced — sit quiet"))
        XCTAssertTrue(section.contains("owes its closing report"))
    }

    func testTickHeartbeatPromptIsNilForEmptyLedger() {
        XCTAssertNil(GoalsTick.heartbeatPrompt(ledger: LedgerDocument()))
    }

    /// The tick beat keeps every load-bearing piece of the plain heartbeat's contract
    /// — the "[heartbeat]" prefix (history restore, digests, and the console key on
    /// it), request_input, and TASK COMPLETE — while carrying the fresh ledger and the
    /// one-decision instruction.
    func testTickHeartbeatPromptKeepsTheBeatContractAndRendersGoals() throws {
        let tick = try XCTUnwrap(GoalsTick.heartbeatPrompt(ledger: ledger))
        XCTAssertTrue(tick.hasPrefix("[heartbeat]"))
        XCTAssertTrue(tick.contains("request_input"))
        XCTAssertTrue(tick.contains("TASK COMPLETE"))
        XCTAssertTrue(tick.contains("g-voice-intent"))
        XCTAssertTrue(tick.contains("Ship the voice intent flow"))
        XCTAssertTrue(tick.contains(#""decision": "ingest|drive|report|idle|clarify""#))
    }
}
