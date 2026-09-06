import XCTest
import CloudKit
import SwiftData
@testable import fin

/// Covers the cross-device layer: signal writes riding every notify path, the pure
/// CKQuerySubscription builder, relay-message application on the hosting device
/// (which must be the submit path — a relayed message gets no privilege a typed
/// one doesn't have), and the mirror reader's parse/merge. No CloudKit I/O
/// anywhere: subscriptions are built but never saved, and stores are in-memory.
final class AgentCrossDeviceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Self.scrubDurableState()
    }

    override func tearDown() {
        MainActor.assumeIsolated { AgentNotificationService.shared.persistSignal = nil }
        Self.scrubDurableState()
        super.tearDown()
    }

    /// Same hermeticity scrub the directive-channel tests use: runtime creation
    /// and submits touch the watchdog's durable per-agent keys.
    private static func scrubDurableState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("fin.watchdog.suppressedAt.")
                || key.hasPrefix("fin.watchdog.armSource.") {
            defaults.removeObject(forKey: key)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { MonitorSuppressionStore.shared.resetCachesForTesting() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { MonitorSuppressionStore.shared.resetCachesForTesting() }
            }
        }
    }

    /// Syntactically non-empty but unparseable as a URL, so an injected turn fails
    /// fast with a non-retryable badURL — no network, no retries, no timers.
    private static let unparseableEndpointURL = "http://[invalid/v1"

    /// Yield-plus-sleep drain: a failed endpoint turn can spend real wall time in
    /// retry backoff before settling, which pure yields never advance through.
    private func drainUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func makeRuntime(
        name: String = "Fin",
        notifyOnResponse: Bool = true,
        connected: Bool = true,
        log: @escaping (AgentLogRecord) -> Void = { _ in }
    ) -> (runtime: AgentRuntime, agent: Agent, session: TerminalSession) {
        let session = TerminalSession(serverID: UUID())
        if connected { session.simulateConnectedStateForTesting() }
        let agent = Agent(
            name: name,
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: .auto,
            notifyOnResponse: notifyOnResponse
        )
        let runtime = AgentRuntime(
            agent: agent, session: session, serverName: "box", log: log
        )
        return (runtime, agent, session)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Agent.self, AgentSignal.self, AgentRelayMessage.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    /// A per-test signal capture wired into the shared notification service.
    @MainActor
    private func captureSignals() -> () -> [(kind: AgentSignalKind, agentID: UUID, agentName: String, preview: String)] {
        var captured: [(AgentSignalKind, UUID, String, String)] = []
        AgentNotificationService.shared.persistSignal = { kind, agentID, agentName, preview in
            captured.append((kind, agentID, agentName, preview))
        }
        return { captured }
    }

    // MARK: - Signal writes

    @MainActor
    func testEachNotifyKindWritesOneSignal() {
        let signals = captureSignals()
        let agentID = UUID()

        AgentNotificationService.shared.notifyTurnFinished(
            agentName: "Fin", reply: "done", agentID: agentID
        )
        AgentNotificationService.shared.notifyInputRequested(
            agentName: "Fin", question: "which branch?", agentID: agentID
        )
        AgentNotificationService.shared.notifyAttention(
            agentName: "Fin", message: "still thinking", agentID: agentID
        )
        AgentNotificationService.shared.notifyAttention(
            agentName: "Fin", message: "monitor gave up", agentID: agentID,
            signalKind: .monitoringPaused
        )

        XCTAssertEqual(signals().map(\.kind), [.turnFinished, .inputRequested, .attention, .monitoringPaused])
        XCTAssertEqual(signals().map(\.preview), ["done", "which branch?", "still thinking", "monitor gave up"])
        XCTAssertTrue(signals().allSatisfy { $0.agentID == agentID })
    }

    @MainActor
    func testSignalPreviewIsRedactedAndCapped() {
        let signals = captureSignals()
        let secret = "the password=hunter2 leaked, and then " + String(repeating: "x", count: 300)
        AgentNotificationService.shared.notifyAttention(
            agentName: "Fin", message: secret, agentID: UUID()
        )

        let preview = signals().first?.preview ?? ""
        XCTAssertFalse(preview.contains("hunter2"), "signal previews leave the device; they must pass MemoryRedactor")
        XCTAssertTrue(preview.contains("[redacted]"))
        XCTAssertLessThanOrEqual(preview.count, 140, "hard cap, ellipsis included")

        // The pure helper agrees with what went through the closure.
        XCTAssertEqual(preview, AgentNotificationService.signalPreview(of: secret))
    }

    /// notifyOnResponse gating lives at the runtime call site, exactly like the
    /// local banner: a muted agent's finished turn writes no turnFinished signal.
    @MainActor
    func testTurnFinishedSignalRespectsNotifyOnResponseGate() async {
        let signals = captureSignals()

        let muted = makeRuntime(notifyOnResponse: false)
        muted.runtime.submit("hello")
        await drainUntil { !muted.runtime.isBusy }
        XCTAssertFalse(signals().contains { $0.kind == .turnFinished },
                       "notifyOnResponse=false must suppress the cross-device signal too")

        let loud = makeRuntime(notifyOnResponse: true)
        loud.runtime.submit("hello")
        await drainUntil { !loud.runtime.isBusy }
        XCTAssertEqual(signals().filter { $0.kind == .turnFinished }.count, 1)
    }

    /// request_input writes an inputRequested signal regardless of notifyOnResponse
    /// — the same asymmetry the local banner has.
    @MainActor
    func testRequestInputWritesInputRequestedSignal() {
        let signals = captureSignals()
        let (runtime, agent, _) = makeRuntime(notifyOnResponse: false)

        _ = runtime.executeRequestInput(question: "prod or staging?", rawArguments: "{}")

        XCTAssertEqual(signals().map(\.kind), [.inputRequested])
        XCTAssertEqual(signals().first?.preview, "prod or staging?")
        XCTAssertEqual(signals().first?.agentID, agent.id)
    }

    /// The model's `notify` tool is a deliberate, model-chosen push, so it writes its
    /// cross-device signal regardless of notifyOnResponse (that gate mutes only the
    /// automatic turn-finished banner) and confirms delivery — the app-local channel is
    /// always present.
    @MainActor
    func testNotifyToolWritesAttentionSignalAndConfirms() {
        let signals = captureSignals()
        let (runtime, agent, _) = makeRuntime(notifyOnResponse: false)

        let result = runtime.executeNotify(
            title: "Deploy done", body: "main is live on prod.", rawArguments: "{}"
        )

        XCTAssertEqual(result, "Sent to the owner.")
        XCTAssertEqual(signals().map(\.kind), [.attention])
        XCTAssertEqual(signals().first?.preview, "main is live on prod.")
        XCTAssertEqual(signals().first?.agentID, agent.id)
    }

    /// An empty body is a correctable tool error, not a silent no-op push: no signal, no
    /// banner, and the model is told to supply a body.
    @MainActor
    func testNotifyToolRequiresABody() {
        let signals = captureSignals()
        let (runtime, _, _) = makeRuntime()

        let result = runtime.executeNotify(title: "hi", body: "   ", rawArguments: "{}")

        XCTAssertTrue(result.contains("non-empty \"body\""), "got: \(result)")
        XCTAssertTrue(signals().isEmpty, "an empty-body notify must not write a signal")
    }

    /// A model-authored notification records its `.attention` signal with a redacted,
    /// capped preview — it leaves the device, exactly like every other signal here.
    @MainActor
    func testNotifyAgentUpdateSignalIsRedactedAndCapped() {
        let signals = captureSignals()
        let secret = "shipped with password=hunter2 and then " + String(repeating: "y", count: 300)

        AgentNotificationService.shared.notifyAgentUpdate(
            agentName: "Fin", title: "Shipped", body: secret, agentID: UUID()
        )

        let preview = signals().first?.preview ?? ""
        XCTAssertEqual(signals().first?.kind, .attention)
        XCTAssertFalse(preview.contains("hunter2"))
        XCTAssertTrue(preview.contains("[redacted]"))
        XCTAssertLessThanOrEqual(preview.count, 140)
    }

    // MARK: - Subscription builder

    func testSubscriptionBuilderIsUserLevelAndCoversEveryKind() {
        let subscriptions = AgentSignalSubscriber.makeSubscriptions()

        XCTAssertEqual(subscriptions.count, AgentSignalKind.allCases.count)
        XCTAssertEqual(
            Set(subscriptions.map(\.subscriptionID)),
            Set(AgentSignalKind.allCases.map { "fin-agent-signals-v2-\($0.rawValue)" }),
            "fixed, USER-level, per-kind ids, VERSIONED: the v2 bump is what guarantees the origin-carrying desiredKeys reach CloudKit for existing installs, whatever same-id re-save does server-side"
        )
        for subscription in subscriptions {
            XCTAssertEqual(subscription.recordType, "CD_AgentSignal")
            let format = subscription.predicate.predicateFormat
            XCTAssertTrue(format.contains("CD_kind =="))
            XCTAssertFalse(
                format.contains("CD_sourceDeviceID8"),
                "origin suppression is CloudKit's own originator exclusion, not a device predicate: \(format)"
            )
            XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation])

            let info = subscription.notificationInfo
            XCTAssertEqual(info?.shouldBadge, false)
            XCTAssertEqual(
                info?.desiredKeys,
                ["CD_agentID", "CD_kind", "CD_sourceDeviceID8"],
                "the origin device must ride every push — it is what routes the tap to the device whose transcript holds the conversation"
            )
            XCTAssertLessThanOrEqual(
                info?.desiredKeys?.count ?? .max, 3,
                "CloudKit rejects any subscription save carrying more than three desiredKeys — a fourth key silently zeroed every signal subscription on the account (build 33 outage)"
            )
            XCTAssertEqual(info?.alertLocalizationKey, AgentSignalSubscriber.previewLocalizationKey)
            XCTAssertEqual(info?.alertLocalizationArgs, ["CD_preview"])
            XCTAssertFalse(info?.title?.isEmpty ?? true, "each kind carries its own static title")
        }

        // The kind-specific titles actually differ.
        XCTAssertEqual(
            Set(subscriptions.compactMap(\.notificationInfo?.title)).count,
            AgentSignalKind.allCases.count
        )
    }

    /// The cleanup matcher must catch every retired id shape — the per-device
    /// ids (this install's AND orphans minted by deleted installs) and the
    /// unversioned user-level ids the v2 payload bump replaced — while never
    /// touching the current versioned ids.
    func testRetiredSubscriptionIDMatcher() {
        for kind in AgentSignalKind.allCases {
            XCTAssertTrue(
                AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-abcd1234-\(kind.rawValue)"),
                "per-device legacy shape"
            )
            XCTAssertTrue(
                AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-\(kind.rawValue)"),
                "the unversioned user-level ids lack CD_sourceDeviceID8 in their desiredKeys; leaving them would double-fire pushes AND keep origin-less taps alive"
            )
            XCTAssertFalse(
                AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-v2-\(kind.rawValue)"),
                "the current versioned ids must survive the cleanup"
            )
        }
        // Orphans from older builds may carry kinds this build never heard of.
        XCTAssertTrue(AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-00ff17aa-someRetiredKind"))
        // Non-hex or wrong-length device segments are not ours to delete, and an
        // unversioned id with an unknown kind is not provably ours either.
        XCTAssertFalse(AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-ABCD1234-attention"))
        XCTAssertFalse(AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-abcd123-attention"))
        XCTAssertFalse(AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-"))
        XCTAssertFalse(AgentSignalSubscriber.isRetiredSubscriptionID("fin-agent-signals-someFutureKind"))
        XCTAssertFalse(AgentSignalSubscriber.isRetiredSubscriptionID("some-other-app-abcd1234-attention"))
    }

    func testPushUserInfoParsingToleratesForeignPayloads() {
        XCTAssertNil(AgentSignalSubscriber.openTarget(fromPushUserInfo: [:]))
        XCTAssertNil(AgentSignalSubscriber.openTarget(fromPushUserInfo: ["aps": ["alert": "hi"] as NSObject]))
    }

    /// The pure half of the push parse: the agent id is load-bearing, the origin
    /// is best-effort — missing, empty, or garbage-typed degrades to a nil origin
    /// (routing then falls back to residence) without dropping the tap.
    func testPushOpenTargetExtractionTable() {
        let agentID = UUID()

        // v2 push: agent + origin.
        XCTAssertEqual(
            AgentSignalSubscriber.openTarget(
                subscriptionID: "fin-agent-signals-v2-inputRequested",
                recordFields: ["CD_agentID": agentID.uuidString, "CD_sourceDeviceID8": "abcd1234"]
            ),
            AgentSignalSubscriber.PushOpenTarget(agentID: agentID, originDeviceID8: "abcd1234")
        )
        // Pre-v2 push still in flight: no origin field, tap still routes.
        XCTAssertEqual(
            AgentSignalSubscriber.openTarget(
                subscriptionID: "fin-agent-signals-inputRequested",
                recordFields: ["CD_agentID": agentID.uuidString]
            ),
            AgentSignalSubscriber.PushOpenTarget(agentID: agentID, originDeviceID8: nil)
        )
        // Garbage origin types and empty strings degrade to nil, never drop the tap.
        XCTAssertEqual(
            AgentSignalSubscriber.openTarget(
                subscriptionID: "fin-agent-signals-v2-attention",
                recordFields: ["CD_agentID": agentID.uuidString, "CD_sourceDeviceID8": 42]
            ),
            AgentSignalSubscriber.PushOpenTarget(agentID: agentID, originDeviceID8: nil)
        )
        XCTAssertEqual(
            AgentSignalSubscriber.openTarget(
                subscriptionID: "fin-agent-signals-v2-attention",
                recordFields: ["CD_agentID": agentID.uuidString, "CD_sourceDeviceID8": ""]
            ),
            AgentSignalSubscriber.PushOpenTarget(agentID: agentID, originDeviceID8: nil)
        )
        // No parseable agent, foreign subscription, or no fields at all → nil.
        XCTAssertNil(AgentSignalSubscriber.openTarget(
            subscriptionID: "fin-agent-signals-v2-attention",
            recordFields: ["CD_agentID": "not-a-uuid", "CD_sourceDeviceID8": "abcd1234"]
        ))
        XCTAssertNil(AgentSignalSubscriber.openTarget(
            subscriptionID: "fin-agent-signals-v2-attention",
            recordFields: ["CD_agentID": 7]
        ))
        XCTAssertNil(AgentSignalSubscriber.openTarget(
            subscriptionID: "some-other-subscription",
            recordFields: ["CD_agentID": agentID.uuidString]
        ))
        XCTAssertNil(AgentSignalSubscriber.openTarget(
            subscriptionID: nil,
            recordFields: ["CD_agentID": agentID.uuidString]
        ))
        XCTAssertNil(AgentSignalSubscriber.openTarget(
            subscriptionID: "fin-agent-signals-v2-attention",
            recordFields: nil
        ))
    }

    // MARK: - Relay application

    /// Suite-backed defaults so the durable applied ledger is hermetic per test
    /// and inspectable across applier instances within one.
    private var ledgerSuites: [String] = []

    private func makeLedgerDefaults() -> UserDefaults {
        let suite = "fin-relay-test-\(UUID().uuidString)"
        ledgerSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws {
        for suite in ledgerSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        ledgerSuites = []
    }

    /// Full-id space for the armed-monitor claim; `.short`-style 8-char ids for
    /// stamps and authorship.
    private static let hostDeviceID = "host-device-full-id"

    @MainActor
    private func makeApplier(
        _ context: ModelContext,
        defaults: UserDefaults? = nil,
        targets: @escaping () -> [AgentRelayApplier.Target]
    ) -> AgentRelayApplier {
        let applier = AgentRelayApplier(
            context: context,
            deviceID8: "hostdev1",
            deviceID: Self.hostDeviceID,
            defaults: defaults ?? makeLedgerDefaults()
        )
        // Deterministic tests: no real jitter sleep unless a test injects one.
        applier.jitterSleep = { _ in }
        applier.liveTargets = targets
        return applier
    }

    @MainActor
    func testRelayMessageAppliesThroughSubmitAndStamps() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var logged: [AgentLogRecord] = []
        let (runtime, agent, _) = makeRuntime { logged.append($0) }

        let message = AgentRelayMessage(agentID: agent.id, text: "what changed overnight?", authorDeviceID8: "phone000")
        context.insert(message)
        try context.save()

        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: true)] }
        await applier.applyPendingNow()

        XCTAssertNotNil(message.appliedAt, "a submit that took must stamp appliedAt")
        XCTAssertEqual(message.appliedByDeviceID8, "hostdev1")
        XCTAssertTrue(runtime.isBusy, "applied means the runtime demonstrably took the message")
        XCTAssertEqual(
            runtime.transcript.messages.last(where: { $0.role == .user })?.text,
            "what changed overnight?",
            "the message enters through the exact same submit path a typed one takes"
        )
        await drainUntil { !runtime.isBusy }
        XCTAssertEqual(logged.filter { $0.kind == .userMessage }.map(\.text), ["what changed overnight?"])
        XCTAssertTrue(logged.contains { $0.kind == .notice && $0.text.contains("[relay] applied message") })
    }

    @MainActor
    func testRelayQueuesOnBusyAndDefersOnDisconnectedAndMissingRuntime() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (runtime, agent, _) = makeRuntime()

        // Disconnected session → defer.
        let message = AgentRelayMessage(agentID: agent.id, text: "second", authorDeviceID8: "phone000")
        context.insert(message)
        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: false)] }
        await applier.applyPendingNow()
        XCTAssertNil(message.appliedAt, "a disconnected session defers, never drops")

        // Message addressed to an agent not hosted here → defer forever on this device.
        let foreign = AgentRelayMessage(agentID: UUID(), text: "elsewhere", authorDeviceID8: "phone000")
        context.insert(foreign)

        // Busy runtime → the message QUEUES behind the in-flight turn and counts
        // as applied; the runtime's FIFO queue guarantees it runs, in order.
        runtime.submit("first")
        XCTAssertTrue(runtime.isBusy)
        applier.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        await applier.applyPendingNow()
        XCTAssertNotNil(message.appliedAt, "queued counts as applied")
        XCTAssertNil(foreign.appliedAt, "wrong-agent messages are another device's to apply")
        XCTAssertEqual(runtime.queuedPrompts, ["second"])

        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && runtime.transcript.messages.filter { $0.role == .user }.count == 2
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["first", "second"],
            "the queued relay message ran after the in-flight turn"
        )
    }

    @MainActor
    func testRelayAppliesInCreatedAtOrderAndDedupes() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var logged: [AgentLogRecord] = []
        let (runtime, agent, _) = makeRuntime { logged.append($0) }

        let later = AgentRelayMessage(agentID: agent.id, text: "later", authorDeviceID8: "phone000")
        later.createdAt = Date(timeIntervalSinceNow: 10)
        let earlier = AgentRelayMessage(agentID: agent.id, text: "earlier", authorDeviceID8: "phone000")
        earlier.createdAt = Date(timeIntervalSinceNow: -10)
        context.insert(later)
        context.insert(earlier)
        try context.save()

        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: true)] }
        await applier.applyPendingNow()
        XCTAssertNotNil(earlier.appliedAt, "oldest first")
        XCTAssertNotNil(
            later.appliedAt,
            "the submit made the runtime busy; the next message queues and counts as applied"
        )
        XCTAssertEqual(runtime.queuedPrompts, ["later"], "queued behind the in-flight turn")

        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && logged.filter { $0.kind == .userMessage }.count == 2
        }
        XCTAssertEqual(logged.filter { $0.kind == .userMessage }.map(\.text), ["earlier", "later"],
                       "createdAt order holds through the queue")

        // Dedupe: even if sync momentarily resurrects an unapplied stamp, the
        // in-memory applied set refuses a second injection.
        later.appliedAt = nil
        await applier.applyPendingNow()
        await drainUntil { !runtime.isBusy }
        XCTAssertEqual(logged.filter { $0.kind == .userMessage }.count, 2,
                       "an id already applied this launch never double-fires")
    }

    /// Over-length text resolves with the `rejected:length` sentinel — the full
    /// round trip: the applier stamps it, and the sender-side state derivation
    /// renders it as "not delivered" rather than a false "sent".
    @MainActor
    func testRelayHardSkipsEmptyAndOverlongTextWithRejectedSentinel() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (runtime, agent, _) = makeRuntime()

        let empty = AgentRelayMessage(agentID: agent.id, text: "   \n ", authorDeviceID8: "phone000")
        let overlong = AgentRelayMessage(
            agentID: agent.id,
            text: String(repeating: "x", count: AgentRelayApplier.maxTextLength + 1),
            authorDeviceID8: "phone000"
        )
        context.insert(empty)
        context.insert(overlong)

        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: true)] }
        await applier.applyPendingNow()

        XCTAssertNotNil(empty.appliedAt, "unappliable text resolves rather than pending forever")
        XCTAssertNotNil(overlong.appliedAt)
        XCTAssertEqual(overlong.appliedByDeviceID8, AgentRelayApplier.rejectedLength)
        XCTAssertFalse(runtime.isBusy, "neither message may reach submit")

        // Sender-side round trip: the sentinel renders as rejected, not sent.
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: overlong.appliedAt,
                appliedByDeviceID8: overlong.appliedByDeviceID8,
                createdAt: overlong.createdAt
            ),
            .rejected
        )
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: empty.appliedAt,
                appliedByDeviceID8: empty.appliedByDeviceID8,
                createdAt: empty.createdAt
            ),
            .sent
        )
    }

    /// The sender row's full state table: pending → "sending…" (with no vanish
    /// window on the applied side — a stamp arriving hours later still flips to
    /// a visible "sent"), rejected sentinel → rejected, past the 30-day
    /// unapplied floor → expired.
    @MainActor
    func testRelayRowStateDerivation() {
        let now = Date()
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: nil, appliedByDeviceID8: nil, createdAt: now, now: now
            ),
            .sending
        )
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: now, appliedByDeviceID8: "hostdev1",
                createdAt: now.addingTimeInterval(-3 * 3600), now: now
            ),
            .sent,
            "a stamp arriving hours after composition still shows as sent — no 1-hour vanish window"
        )
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: now, appliedByDeviceID8: AgentRelayApplier.rejectedLength,
                createdAt: now, now: now
            ),
            .rejected
        )
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: nil, appliedByDeviceID8: nil,
                createdAt: now.addingTimeInterval(-31 * 86_400), now: now
            ),
            .expired
        )
        XCTAssertEqual(
            AgentRemoteConsoleView.relayState(
                appliedAt: nil, appliedByDeviceID8: nil,
                createdAt: now.addingTimeInterval(-29 * 86_400), now: now
            ),
            .sending,
            "under the floor an unapplied row is still awaiting delivery"
        )
    }

    /// Sweep floors: signals and APPLIED relays go at 7 days; an unapplied relay
    /// survives the 7-day sweep (still deliverable) and is dropped only past the
    /// 30-day hard floor.
    @MainActor
    func testRetentionSweepFloors() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let oldSignal = AgentSignal(
            agentID: UUID(), agentName: "Fin", kind: .attention,
            preview: "old", sourceDeviceID8: "aaaa0000"
        )
        oldSignal.createdAt = Date(timeIntervalSinceNow: -8 * 86_400)
        let freshSignal = AgentSignal(
            agentID: UUID(), agentName: "Fin", kind: .attention,
            preview: "fresh", sourceDeviceID8: "aaaa0000"
        )

        let oldApplied = AgentRelayMessage(agentID: UUID(), text: "old applied", authorDeviceID8: "aaaa0000")
        oldApplied.createdAt = Date(timeIntervalSinceNow: -8 * 86_400)
        oldApplied.appliedAt = Date(timeIntervalSinceNow: -8 * 86_400)
        oldApplied.appliedByDeviceID8 = "bbbb0000"
        let oldPending = AgentRelayMessage(agentID: UUID(), text: "old pending", authorDeviceID8: "aaaa0000")
        oldPending.createdAt = Date(timeIntervalSinceNow: -8 * 86_400)
        let ancientPending = AgentRelayMessage(agentID: UUID(), text: "ancient pending", authorDeviceID8: "aaaa0000")
        ancientPending.createdAt = Date(timeIntervalSinceNow: -31 * 86_400)
        let freshMessage = AgentRelayMessage(agentID: UUID(), text: "fresh", authorDeviceID8: "aaaa0000")

        for model in [oldApplied, oldPending, ancientPending, freshMessage] { context.insert(model) }
        context.insert(oldSignal)
        context.insert(freshSignal)
        try context.save()

        makeApplier(context) { [] }.sweepExpiredCrossDeviceRecords()

        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentSignal>()).map(\.preview), ["fresh"])
        XCTAssertEqual(
            Set(try context.fetch(FetchDescriptor<AgentRelayMessage>()).map(\.text)),
            ["old pending", "fresh"],
            "applied rows sweep at 7 days; unapplied rows survive to the 30-day hard floor"
        )
    }

    // MARK: - Claim policy

    /// While a monitor is armed, its home device is the ONLY applier: a live
    /// runtime on any other device must leave the row pending, and the home
    /// device applies without jitter.
    @MainActor
    func testClaimPolicyArmedMonitorPinsApplierToHomeDevice() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (runtime, agent, _) = makeRuntime()
        agent.monitoringArmed = true
        agent.monitoringDeviceID = "some-other-device-id"
        context.insert(agent)
        try context.save()

        let message = AgentRelayMessage(agentID: agent.id, text: "status?", authorDeviceID8: "phone000")
        context.insert(message)

        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: true)] }
        var jitterCalls = 0
        applier.jitterSleep = { _ in jitterCalls += 1 }
        await applier.applyPendingNow()
        XCTAssertNil(message.appliedAt, "armed elsewhere: this device must refuse even with a live runtime")
        XCTAssertFalse(runtime.isBusy)

        // Re-home the armed monitor to THIS device: now it applies, jitter-free
        // (a deterministic single winner needs no stagger).
        agent.monitoringDeviceID = Self.hostDeviceID
        await applier.applyPendingNow()
        XCTAssertNotNil(message.appliedAt)
        XCTAssertEqual(message.appliedByDeviceID8, "hostdev1")
        XCTAssertEqual(jitterCalls, 0, "the armed home device claims without jitter")
        await drainUntil { !runtime.isBusy }
    }

    /// Unarmed claim: the applier jitters, then re-checks `appliedAt` — a stamp
    /// that synced in during the jitter window makes this device back off.
    @MainActor
    func testClaimPolicyUnarmedJitterRecheckBacksOff() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (runtime, agent, _) = makeRuntime()
        context.insert(agent)

        let message = AgentRelayMessage(agentID: agent.id, text: "who wins?", authorDeviceID8: "phone000")
        context.insert(message)
        try context.save()

        let applier = makeApplier(context) { [.init(runtime: runtime, sessionConnected: true)] }
        var jittered = false
        applier.jitterSleep = { _ in
            jittered = true
            // Another unarmed device's stamp lands mid-jitter.
            message.appliedAt = Date()
            message.appliedByDeviceID8 = "otherdev"
        }
        await applier.applyPendingNow()

        XCTAssertTrue(jittered, "the unarmed path must jitter before claiming")
        XCTAssertEqual(message.appliedByDeviceID8, "otherdev", "the other device's claim stands")
        XCTAssertFalse(runtime.isBusy, "this device backed off — nothing was injected")
    }

    /// The jitter is a pure, per-(device, message) deterministic value under 2s —
    /// stable across launches (unlike `Hasher`) so contenders stay staggered.
    func testClaimJitterIsDeterministicAndBounded() {
        let id = UUID()
        let a = AgentRelayApplier.claimJitterMillis(deviceID8: "aaaa1111", messageID: id)
        XCTAssertEqual(a, AgentRelayApplier.claimJitterMillis(deviceID8: "aaaa1111", messageID: id))
        XCTAssertTrue((0..<2000).contains(a))
        XCTAssertTrue((0..<2000).contains(
            AgentRelayApplier.claimJitterMillis(deviceID8: "bbbb2222", messageID: id)
        ))
    }

    /// Crash-before-save replay: the durable per-agent ledger makes a FRESH
    /// applier (new launch, empty in-memory set) recognize an already-delivered
    /// message — it restores the lost stamp without re-injecting.
    @MainActor
    func testDurableLedgerConsultedByFreshApplier() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var logged: [AgentLogRecord] = []
        let (runtime, agent, _) = makeRuntime { logged.append($0) }

        let message = AgentRelayMessage(agentID: agent.id, text: "deploy it", authorDeviceID8: "phone000")
        context.insert(message)
        try context.save()

        let sharedDefaults = makeLedgerDefaults()
        let first = makeApplier(context, defaults: sharedDefaults) {
            [.init(runtime: runtime, sessionConnected: true)]
        }
        await first.applyPendingNow()
        XCTAssertNotNil(message.appliedAt)
        await drainUntil { !runtime.isBusy }
        XCTAssertEqual(logged.filter { $0.kind == .userMessage }.count, 1)

        // Simulate the crash-before-save: the stamp is lost, the ledger is not.
        message.appliedAt = nil
        message.appliedByDeviceID8 = nil

        let relaunched = makeApplier(context, defaults: sharedDefaults) {
            [.init(runtime: runtime, sessionConnected: true)]
        }
        await relaunched.applyPendingNow()

        XCTAssertNotNil(message.appliedAt, "the relaunched applier restores the lost stamp")
        XCTAssertEqual(logged.filter { $0.kind == .userMessage }.count, 1,
                       "…but never re-injects a message this device already delivered")
        XCTAssertFalse(runtime.isBusy)
    }

    // MARK: - Notification-tap routing fork

    /// The full fork table `RootView`/`ControlStripView` share. The signal's
    /// origin device is authoritative when known: origin elsewhere → remote
    /// ALWAYS (each device keeps its own transcript for the same synced Agent,
    /// so a live local runtime is a DIFFERENT conversation — residence routing
    /// here was the live UX failure: the receiving iPhone auto-resumes its
    /// terminal session at launch, so its live runtime always won the tap and
    /// opened its own empty conversation); origin here → local ALWAYS. Only an
    /// origin-less pre-v2 push falls back to the residence rule.
    func testNotificationTapRouteTable() {
        typealias Row = (
            origin: String?, armed: Bool, deviceID: String, hasLocal: Bool,
            route: SessionManager.AgentNotificationRoute
        )
        let mine = "my-device"
        let mine8 = "aaaa1111"
        let elsewhere8 = "bbbb2222"
        let table: [Row] = [
            // Origin known and elsewhere → remote UNCONDITIONALLY. The live
            // local runtime row is the exact live failure being fixed.
            (elsewhere8, false, "", false, .remoteConsole),
            (elsewhere8, false, "", true, .remoteConsole),
            (elsewhere8, true, mine, true, .remoteConsole),
            (elsewhere8, true, mine, false, .remoteConsole),
            (elsewhere8, true, "other-device", false, .remoteConsole),
            // Origin known and here → local unconditionally, runtime or not.
            (mine8, false, "", true, .localConsole),
            (mine8, false, "", false, .localConsole),
            (mine8, true, "other-device", false, .localConsole),
            (mine8, true, mine, true, .localConsole),
            // Origin unknown: the pre-origin residence fallback, verbatim.
            // A live local runtime wins the tap.
            (nil, false, "", true, .localConsole),
            (nil, true, mine, true, .localConsole),
            (nil, true, "other-device", true, .localConsole),
            // Armed HERE with no runtime yet: cold-launch resume stays queued
            // for the local console, never an empty remote view of this device.
            (nil, true, mine, false, .localConsole),
            // No local runtime and not armed here → remote, armed or not.
            (nil, false, "", false, .remoteConsole),
            (nil, false, "other-device", false, .remoteConsole),
            (nil, true, "other-device", false, .remoteConsole),
            (nil, true, "", false, .remoteConsole),
        ]
        for row in table {
            XCTAssertEqual(
                SessionManager.notificationTapRoute(
                    originDeviceID8: row.origin,
                    localDeviceID8: mine8,
                    monitoringArmed: row.armed,
                    monitoringDeviceID: row.deviceID,
                    localDeviceID: mine,
                    hasLiveRuntimeLocally: row.hasLocal
                ),
                row.route,
                "origin=\(row.origin ?? "nil") armed=\(row.armed) device=\(row.deviceID) local=\(row.hasLocal)"
            )
        }
    }

    /// Plumbing check for the pending-open struct: the origin a tap queues is
    /// the origin the instance-level fork consumes, against live device identity.
    @MainActor
    func testPendingAgentOpenCarriesOriginThroughInstanceRoute() {
        let manager = SessionManager()
        let agent = Agent(name: "Fin", modelIdentifier: "m")

        // A cross-device tap: origin provably elsewhere → remote, even though
        // nothing is armed and no runtime exists (and regardless of either).
        manager.pendingAgentOpen = .init(agentID: agent.id, originDeviceID8: "bbbb2222")
        XCTAssertEqual(
            manager.notificationTapRoute(
                for: agent, originDeviceID8: manager.pendingAgentOpen?.originDeviceID8
            ),
            .remoteConsole
        )

        // A local banner's tap queues this device's own id → local console.
        manager.pendingAgentOpen = .init(agentID: agent.id, originDeviceID8: DeviceIdentity.short)
        XCTAssertEqual(
            manager.notificationTapRoute(
                for: agent, originDeviceID8: manager.pendingAgentOpen?.originDeviceID8
            ),
            .localConsole
        )
    }

    // MARK: - Cloud hosting

    /// The hosting switch's whole contract: local is the default and the
    /// fail-safe (an unknown raw value from a newer build hosts locally, never
    /// nowhere), cloud refuses local hosting, and moving to cloud disarms any
    /// persisted monitor so the arming device can't resume a heartbeat against
    /// an agent it no longer hosts.
    @MainActor
    func testHostingModeDefaultsGatesAndDisarmsOnCloudSwitch() {
        let agent = Agent(name: "Fin")
        XCTAssertEqual(agent.hostingMode, .local)
        XCTAssertTrue(agent.hostsLocally)

        agent.hostingModeRaw = "some-future-mode"
        XCTAssertTrue(agent.hostsLocally, "unknown modes fail toward the tested local path")

        agent.monitoringArmed = true
        agent.monitoringDeviceID = "device-1"
        agent.monitoringServerID = UUID()
        agent.updateHostingMode(.cloud)
        XCTAssertFalse(agent.hostsLocally)
        XCTAssertFalse(agent.monitoringArmed)
        XCTAssertTrue(agent.monitoringDeviceID.isEmpty)
        XCTAssertNil(agent.monitoringServerID)

        agent.updateHostingMode(.local)
        XCTAssertTrue(agent.hostsLocally, "switching back restores local hosting")
    }

    /// The inbox append is the cloud composer's whole write path: fresh document
    /// when nothing exists (the first compose IS the missing-object case),
    /// order-preserving append, hard entry cap, and recovery from garbage.
    func testCloudInboxAppendMergesCapsAndSurvivesGarbage() throws {
        func entries(_ data: Data) throws -> [[String: Any]] {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["version"] as? Int, 1)
            return try XCTUnwrap(object["directives"] as? [[String: Any]])
        }

        // Fresh document.
        let first = CloudAgentChannel.appendedInboxDocument(
            existing: nil, agentName: "Fin", text: "hello", id: "m-1"
        )
        let firstEntries = try entries(first)
        XCTAssertEqual(firstEntries.count, 1)
        XCTAssertEqual(firstEntries[0]["id"] as? String, "m-1")
        XCTAssertEqual(firstEntries[0]["agent"] as? String, "Fin")
        XCTAssertEqual(firstEntries[0]["kind"] as? String, "user_message")
        XCTAssertEqual(firstEntries[0]["text"] as? String, "hello")

        // Append preserves existing entries and order.
        let second = CloudAgentChannel.appendedInboxDocument(
            existing: first, agentName: "Fin", text: "again", id: "m-2"
        )
        let secondEntries = try entries(second)
        XCTAssertEqual(secondEntries.map { $0["id"] as? String }, ["m-1", "m-2"])

        // The cap drops the OLDEST entries — the harness's applied ledger is
        // what prevents replays, so old tail loss is safe.
        var capped = first
        for index in 0..<(CloudAgentChannel.maxInboxEntries + 10) {
            capped = CloudAgentChannel.appendedInboxDocument(
                existing: capped, agentName: "Fin", text: "n", id: "m-cap-\(index)"
            )
        }
        let cappedEntries = try entries(capped)
        XCTAssertEqual(cappedEntries.count, CloudAgentChannel.maxInboxEntries)
        XCTAssertEqual(
            cappedEntries.last?["id"] as? String,
            "m-cap-\(CloudAgentChannel.maxInboxEntries + 9)"
        )
        XCTAssertNil(
            cappedEntries.first(where: { ($0["id"] as? String) == "m-1" }),
            "oldest entries age out"
        )

        // Garbage existing data starts fresh instead of failing the compose.
        let recovered = CloudAgentChannel.appendedInboxDocument(
            existing: Data("not json".utf8), agentName: "Fin", text: "recover", id: "m-r"
        )
        XCTAssertEqual(try entries(recovered).count, 1)
    }

    // MARK: - Relay row / mirror handoff

    /// A sent relay row hands off to the mirror transcript only when the
    /// mirror provably shows THIS message (live bug: every sent relay rendered
    /// twice — once as the relay row, once as the applied user prompt in the
    /// merged mirror). The timestamp guard keeps an EARLIER identical message
    /// from swallowing a newer row the transcript isn't showing yet.
    func testRelayRowHandsOffToMirrorOnlyOnProvableMatch() {
        let composed = Date(timeIntervalSince1970: 1_000_000)
        func record(
            _ text: String, kind: AgentLogKind = .userMessage, offset: TimeInterval
        ) -> AgentMirrorRecord {
            AgentMirrorRecord(
                id: UUID().uuidString, kind: kind, text: text,
                timestamp: composed.addingTimeInterval(offset)
            )
        }

        // Applied prompt in the mirror, logged after composition → handoff.
        XCTAssertTrue(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "I'm ready", createdAt: composed, records: [record("I'm ready", offset: 40)]
        ))
        // The hosting device trims before logging; whitespace still matches.
        XCTAssertTrue(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "  I'm ready\n", createdAt: composed, records: [record("I'm ready", offset: 40)]
        ))
        // Same text but logged well BEFORE this row was composed: that's a
        // previous identical send — this row must stay visible.
        XCTAssertFalse(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "I'm ready", createdAt: composed, records: [record("I'm ready", offset: -400)]
        ))
        // Different text never matches.
        XCTAssertFalse(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "I'm ready", createdAt: composed, records: [record("proceed", offset: 40)]
        ))
        // Only user messages count — an assistant echo of the text is not the
        // applied prompt.
        XCTAssertFalse(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "I'm ready", createdAt: composed,
            records: [record("I'm ready", kind: .assistantMessage, offset: 40)]
        ))
        // Empty mirror (sync lag) keeps the row.
        XCTAssertFalse(AgentRemoteConsoleView.relayRowIsMirrored(
            text: "I'm ready", createdAt: composed, records: []
        ))
    }

    // MARK: - Mirror reader

    private func mirrorLine(
        id: String, kind: String, text: String, timestamp: String, sequence: Int, runID: String = "r"
    ) -> String {
        """
        {"id":"\(id)","run_id":"\(runID)","sequence":\(sequence),"timestamp":"\(timestamp)",\
        "agent_id":"A","agent_name":"Fin","server":"box","kind":"\(kind)","text":"\(text)",\
        "model":"","temperature":0}
        """
    }

    func testMirrorReaderMergesTwoDeviceFilesByTimestamp() throws {
        let agentID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root
            .appendingPathComponent("Documents/AgentLogs")
            .appendingPathComponent(AgentLogMirror.slug(agentName: "Fin", agentID: agentID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())

        // Device A wrote at :00 and :20; device B wrote at :10 — the merged
        // timeline must interleave them.
        let deviceA = [
            mirrorLine(id: "a1", kind: "userMessage", text: "first", timestamp: "\(day)T10:00:00Z", sequence: 1),
            mirrorLine(id: "a2", kind: "assistantMessage", text: "third", timestamp: "\(day)T10:00:20Z", sequence: 2),
            AgentLogMirror.truncationMarker,   // non-JSON lines are skipped, not fatal
            "",
        ].joined(separator: "\n")
        let deviceB = mirrorLine(
            id: "b1", kind: "notice", text: "second", timestamp: "\(day)T10:00:10Z", sequence: 1, runID: "q"
        )
        try deviceA.write(to: directory.appendingPathComponent("\(day).aaaa1111.jsonl"), atomically: true, encoding: .utf8)
        try deviceB.write(to: directory.appendingPathComponent("\(day).bbbb2222.jsonl"), atomically: true, encoding: .utf8)
        // A stale file outside the window must not contribute.
        try mirrorLine(id: "z", kind: "notice", text: "ancient", timestamp: "2020-01-01T00:00:00Z", sequence: 1)
            .write(to: directory.appendingPathComponent("2020-01-01.aaaa1111.jsonl"), atomically: true, encoding: .utf8)

        let records = AgentMirrorReader(containerURL: { root })
            .loadRecent(agentName: "Fin", agentID: agentID)

        XCTAssertEqual(records.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(records.map(\.kind), [.userMessage, .notice, .assistantMessage])
    }

    func testMirrorRecordParsingToleratesGarbage() {
        XCTAssertNil(AgentMirrorRecord(jsonlLine: ""))
        XCTAssertNil(AgentMirrorRecord(jsonlLine: "not json"))
        XCTAssertNil(AgentMirrorRecord(jsonlLine: AgentLogMirror.truncationMarker))
        XCTAssertNil(AgentMirrorRecord(jsonlLine: #"{"kind":"notice"}"#), "no timestamp, no record")

        let minimal = AgentMirrorRecord(
            jsonlLine: #"{"kind":"someFutureKind","timestamp":"2026-08-28T10:00:00Z"}"#
        )
        XCTAssertEqual(minimal?.kind, .notice, "unknown kinds render as notices")
        XCTAssertEqual(minimal?.text, "")
    }

    func testMirrorDayFileWindowAndPlaceholderNames() {
        let now = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        XCTAssertTrue(AgentMirrorReader.isRecentDayFile("2026-08-28.aaaa1111.jsonl", days: 2, now: now))
        XCTAssertTrue(AgentMirrorReader.isRecentDayFile("2026-08-27.bbbb2222.jsonl", days: 2, now: now))
        XCTAssertFalse(AgentMirrorReader.isRecentDayFile("2026-08-25.aaaa1111.jsonl", days: 2, now: now))
        XCTAssertFalse(AgentMirrorReader.isRecentDayFile("notes.txt", days: 2, now: now))

        XCTAssertEqual(
            AgentMirrorReader.placeholderTarget(".2026-08-28.aaaa1111.jsonl.icloud"),
            "2026-08-28.aaaa1111.jsonl"
        )
        XCTAssertNil(AgentMirrorReader.placeholderTarget("2026-08-28.aaaa1111.jsonl"))
    }

    /// The reader must not trust whatever sync delivers: a mirror file past the
    /// 6 MB guard (the writer caps its own at 5 MB/day) is skipped wholesale,
    /// leaving one synthetic notice row in its place, while sibling files still
    /// load normally.
    func testMirrorReaderSkipsOversizedFileWithNoticeRow() throws {
        let agentID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-oversize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root
            .appendingPathComponent("Documents/AgentLogs")
            .appendingPathComponent(AgentLogMirror.slug(agentName: "Fin", agentID: agentID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())

        // A legitimate small file from device A…
        try mirrorLine(id: "ok", kind: "notice", text: "healthy", timestamp: "\(day)T10:00:00Z", sequence: 1)
            .write(to: directory.appendingPathComponent("\(day).aaaa1111.jsonl"), atomically: true, encoding: .utf8)
        // …and an oversized one from device B, just past the guard.
        let oversized = String(repeating: "x", count: AgentMirrorReader.maxFileBytes + 1)
        try oversized.write(
            to: directory.appendingPathComponent("\(day).bbbb2222.jsonl"), atomically: true, encoding: .utf8
        )

        let records = AgentMirrorReader(containerURL: { root })
            .loadRecent(agentName: "Fin", agentID: agentID)

        XCTAssertEqual(records.filter { $0.text == "healthy" }.count, 1, "sibling files still load")
        let notices = records.filter { $0.text == AgentMirrorReader.oversizeNoticeText }
        XCTAssertEqual(notices.count, 1, "exactly one synthetic notice per skipped file")
        XCTAssertEqual(notices.first?.kind, .notice)
    }

    // MARK: - Cloud worker control plane

    /// The control plane's whole response table, mapped with no server in the
    /// loop. Two shapes matter beyond the happy path: a 409 is the BENIGN case
    /// (a worker is already up — nothing to fix), and every other failure must
    /// carry the plane's own message or the bare status, never raw body bytes
    /// and never the endpoint or token, which both render in the console.
    func testCloudWorkerOutcomeMappingTable() {
        func body(_ json: String) -> Data { Data(json.utf8) }

        XCTAssertEqual(
            CloudWorkerClient.outcome(
                status: 200,
                body: body(#"{"workerId":"w-1","instanceId":"i-1","instanceType":"t4g.nano"}"#)
            ),
            .started(instanceType: "t4g.nano")
        )
        XCTAssertEqual(
            CloudWorkerClient.outcome(status: 201, body: body(#"{"workerId":"w-2","instanceId":"i-2"}"#)),
            .started(instanceType: "unknown"),
            "a launch that omits the instance type is still a launch"
        )
        XCTAssertEqual(
            CloudWorkerClient.outcome(status: 409, body: body(#"{"error":"worker already running"}"#)),
            .alreadyRunning,
            "409 is the one failure status that isn't a failure"
        )
        XCTAssertEqual(
            CloudWorkerClient.outcome(status: 401, body: body(#"{"error":"unauthorized"}"#)),
            .failed("unauthorized")
        )
        XCTAssertEqual(
            CloudWorkerClient.outcome(status: 500, body: body(#"{"error":"RunInstances failed: capacity"}"#)),
            .failed("RunInstances failed: capacity")
        )
        // No parseable error text — an empty body, an unparseable one, or an
        // empty error string — falls back to the status code.
        XCTAssertEqual(CloudWorkerClient.outcome(status: 403, body: nil), .failed("HTTP 403"))
        XCTAssertEqual(
            CloudWorkerClient.outcome(status: 502, body: body("<html>gateway</html>")),
            .failed("HTTP 502"),
            "a non-JSON body never reaches the console verbatim"
        )
        XCTAssertEqual(CloudWorkerClient.outcome(status: 500, body: body(#"{"error":""}"#)), .failed("HTTP 500"))
        // Nothing came back at all: the transport failed, not the plane.
        XCTAssertEqual(CloudWorkerClient.outcome(status: nil, body: nil), .failed("network error"))
    }
}
