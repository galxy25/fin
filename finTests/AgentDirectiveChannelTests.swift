import XCTest
@testable import fin

/// Covers the remote-supervision channel: directive parsing and matching, the
/// applied-set bookkeeping, the injection path (which must be the submit path — the
/// remote supervisor gets no privilege a typed message doesn't have), status-payload
/// redaction, and the pure throttle/ETag decisions. All network I/O goes through the
/// channel's injected closures; nothing here touches a socket.
final class AgentDirectiveChannelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Self.scrubDurableState()
    }

    override func tearDown() {
        Self.scrubDurableState()
        super.tearDown()
    }

    /// The channel's config/applied-set and the watchdog's suppression state are
    /// durable UserDefaults keys; scrub both directions so tests stay hermetic.
    private static func scrubDurableState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("fin.remote.")
                || key.hasPrefix("fin.watchdog.suppressedAt.")
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
    /// fast with a non-retryable badURL — no network, no retry backoff, no timers.
    private static let unparseableEndpointURL = "http://[invalid/v1"

    /// Yield-plus-sleep drain: a failed endpoint turn spends real wall time in its
    /// async machinery before settling, and a pure yield loop can burn through its
    /// budget without the clock ever advancing — observed as a deterministic
    /// failure on fast machines, not even a flake.
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
        mode: AgentMode = .auto,
        heartbeatSeconds: Int = 0,
        connected: Bool = true,
        history: [AgentMessage] = [],
        log: @escaping (AgentLogRecord) -> Void = { _ in }
    ) -> (runtime: AgentRuntime, agent: Agent, session: TerminalSession) {
        let session = TerminalSession(serverID: UUID())
        if connected { session.simulateConnectedStateForTesting() }
        let agent = Agent(
            name: name,
            provider: .openAICompatible,
            endpointURL: Self.unparseableEndpointURL,
            modelIdentifier: "m",
            defaultMode: mode,
            heartbeatSeconds: heartbeatSeconds
        )
        let runtime = AgentRuntime(
            agent: agent, session: session, serverName: "box", log: log, history: history
        )
        return (runtime, agent, session)
    }

    @MainActor
    private func makeChannel(
        fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { _ in
            throw URLError(.notConnectedToInternet)
        },
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    ) -> AgentDirectiveChannel {
        AgentDirectiveChannel(fetch: fetch, put: put)
    }

    private func document(_ json: String) -> RemoteDirectiveDocument {
        guard let document = RemoteDirectiveDocument.parse(Data(json.utf8)) else {
            fatalError("test document must parse")
        }
        return document
    }

    // MARK: - Document parsing

    func testParsesValidDirectiveDocument() {
        let json = """
        {"version":1,"issued_at":"2026-08-27T00:00:00Z","directives":[
          {"id":"d-0001","agent":"*","kind":"user_message","text":"check the build",
           "arm_monitor":true,"interval_seconds":60}
        ]}
        """
        let parsed = RemoteDirectiveDocument.parse(Data(json.utf8))
        XCTAssertEqual(parsed?.version, 1)
        XCTAssertEqual(parsed?.issuedAt, "2026-08-27T00:00:00Z")
        XCTAssertEqual(parsed?.directives.count, 1)
        let directive = parsed?.directives.first
        XCTAssertEqual(directive?.id, "d-0001")
        XCTAssertEqual(directive?.agent, "*")
        XCTAssertEqual(directive?.kind, "user_message")
        XCTAssertEqual(directive?.text, "check the build")
        XCTAssertEqual(directive?.armMonitor, true)
        XCTAssertEqual(directive?.intervalSeconds, 60)
    }

    func testMalformedJSONFailsToParse() {
        XCTAssertNil(RemoteDirectiveDocument.parse(Data("not json {".utf8)))
        XCTAssertNil(RemoteDirectiveDocument.parse(Data("[1,2,3]".utf8)))
    }

    func testMissingOptionalFieldsGetDefaults() {
        let parsed = RemoteDirectiveDocument.parse(
            Data(#"{"directives":[{"id":"d-1","kind":"user_message","text":"hi"}]}"#.utf8)
        )
        XCTAssertEqual(parsed?.version, 1, "missing version defaults, tolerant decode")
        let directive = parsed?.directives.first
        XCTAssertEqual(directive?.agent, "*", "missing agent means wildcard")
        XCTAssertNil(directive?.armMonitor)
        XCTAssertNil(directive?.intervalSeconds)
    }

    func testMalformedDirectiveElementIsDroppedNotFatal() {
        let json = """
        {"version":1,"directives":[
          {"kind":"user_message","text":"no id, dropped"},
          {"id":"d-2","kind":"user_message","text":"kept"}
        ]}
        """
        let parsed = RemoteDirectiveDocument.parse(Data(json.utf8))
        XCTAssertEqual(parsed?.directives.map(\.id), ["d-2"])
    }

    func testUnknownKindSurvivesParsingForForwardCompat() {
        let parsed = RemoteDirectiveDocument.parse(
            Data(#"{"directives":[{"id":"d-1","kind":"reboot_flux_capacitor"}]}"#.utf8)
        )
        XCTAssertEqual(parsed?.directives.first?.kind, "reboot_flux_capacitor",
                       "unknown kinds parse and are skipped at application, not decode")
    }

    // MARK: - Agent matching

    func testAgentMatchingWildcardAndCaseInsensitive() {
        XCTAssertTrue(RemoteDirective(id: "d", agent: "*").matches(agentNamed: "Anything"))
        XCTAssertTrue(RemoteDirective(id: "d", agent: "fin").matches(agentNamed: "Fin"))
        XCTAssertTrue(RemoteDirective(id: "d", agent: "FIN").matches(agentNamed: "fin"))
        XCTAssertFalse(RemoteDirective(id: "d", agent: "Fin").matches(agentNamed: "Other"))
    }

    // MARK: - Applied set

    func testAppliedStoreDedupOrderingCapAndPersistence() {
        var store = AppliedDirectiveStore()
        store.markApplied("d-1")
        store.markApplied("d-2")
        store.markApplied("d-1")
        XCTAssertEqual(store.ids, ["d-1", "d-2"], "re-marking is a no-op, order kept")
        XCTAssertTrue(store.contains("d-1"))
        XCTAssertEqual(store.lastAppliedID, "d-2")

        for index in 3...(AppliedDirectiveStore.cap + 10) {
            store.markApplied("d-\(index)")
        }
        XCTAssertEqual(store.ids.count, AppliedDirectiveStore.cap)
        XCTAssertFalse(store.contains("d-1"), "oldest ids fall off past the cap")
        XCTAssertEqual(store.lastAppliedID, "d-\(AppliedDirectiveStore.cap + 10)")

        let reloaded = AppliedDirectiveStore()
        XCTAssertEqual(reloaded.ids, store.ids, "the set survives a reload")
    }

    func testOrdinalParsing() {
        XCTAssertEqual(AppliedDirectiveStore.ordinal(of: "d-42"), 42)
        XCTAssertEqual(AppliedDirectiveStore.ordinal(of: "d-0001"), 1)
        XCTAssertNil(AppliedDirectiveStore.ordinal(of: "task-7"))
        XCTAssertNil(AppliedDirectiveStore.ordinal(of: "d-"))
        XCTAssertNil(AppliedDirectiveStore.ordinal(of: "d-1a"))
        XCTAssertNil(AppliedDirectiveStore.ordinal(of: "d-١٢"), "non-ASCII digits get no ordinal")
    }

    /// The applied-id list caps at 500; the persisted high-water ordinal is what
    /// stops a relaunch (empty in-memory ETag, full refetch) from re-injecting a
    /// `d-<n>` id that was applied and then evicted.
    @MainActor
    func testEvictedOrdinalIDIsNotReplayedAfterRelaunch() async {
        var store = AppliedDirectiveStore()
        store.markApplied("d-501")
        XCTAssertEqual(store.lastAppliedOrdinal, 501)
        let reloaded = AppliedDirectiveStore()
        XCTAssertEqual(reloaded.lastAppliedOrdinal, 501, "the mark survives a relaunch")
        XCTAssertTrue(reloaded.isBelowHighWaterMark("d-500"))
        XCTAssertFalse(reloaded.isBelowHighWaterMark("d-502"))
        XCTAssertFalse(reloaded.isBelowHighWaterMark("free-form"),
                       "non-ordinal ids keep applied-set-only semantics")
        XCTAssertFalse(reloaded.isBelowHighWaterMark("d-501"),
                       "an id still in the set is deduped by the set, not the mark")

        var lines: [String] = []
        let channel = makeChannel()
        channel.audit = { lines.append($0) }
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let doc = document(
            #"{"directives":[{"id":"d-500","kind":"user_message","text":"old command"}]}"#
        )
        channel.applyDirectives(doc)
        channel.applyDirectives(doc)
        XCTAssertFalse(runtime.isBusy, "an evicted-old directive is never injected")
        XCTAssertTrue(runtime.transcript.messages.filter { $0.role == .user }.isEmpty)
        XCTAssertEqual(
            lines.filter { $0 == "[s3] skipped directive d-500: below high-water mark" }.count, 1,
            "the replay skip audits once per launch"
        )
        XCTAssertFalse(AppliedDirectiveStore().contains("d-500"))
        XCTAssertTrue(AppliedDirectiveStore().deferredOrdinals.isEmpty,
                      "a below-mark replay is a skip, never recorded as a deferral")
    }

    // MARK: - Deferred-ordinal ledger (N1)

    /// The reviewer scenario, end to end through `pollOnce`: d-1 targets Alpha
    /// (whose runtime is absent) and d-2 is a wildcard another agent applies, so
    /// the high-water mark reaches 2 with d-1 never applied. The ledger must keep
    /// d-1 retryable, and the later 304 (cached-document) pass must apply it once
    /// Alpha's runtime shows up idle.
    @MainActor
    func testDeferredLowerOrdinalSurvivesHigherOrdinalApplyingFirst() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches = 0 }
        let box = Box()
        let body = """
        {"version":1,"directives":[
          {"id":"d-1","agent":"Alpha","kind":"user_message","text":"for alpha"},
          {"id":"d-2","agent":"*","kind":"user_message","text":"for anyone"}
        ]}
        """
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                if box.fetches == 1 {
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": "\"v1\""]
                        )!
                    )
                }
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        let (beta, _, _) = makeRuntime(name: "Beta")
        var targets: [AgentDirectiveChannel.Target] = [.init(runtime: beta, sessionConnected: true)]
        channel.liveTargets = { targets }
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertTrue(AppliedDirectiveStore().contains("d-2"), "the wildcard lands on Beta")
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"), "no Alpha runtime: d-1 defers")
        XCTAssertEqual(AppliedDirectiveStore().lastAppliedOrdinal, 2)
        XCTAssertEqual(AppliedDirectiveStore().deferredOrdinals, [1],
                       "the deferral is ledgered, not lost under the mark")

        let (alpha, _, _) = makeRuntime(name: "Alpha")
        targets.append(.init(runtime: alpha, sessionConnected: true))
        await drainUntil { !beta.isBusy }
        await channel.pollOnce()
        XCTAssertTrue(
            AppliedDirectiveStore().contains("d-1"),
            "the 304 cached-document pass must apply the ledgered lower ordinal"
        )
        XCTAssertTrue(AppliedDirectiveStore().deferredOrdinals.isEmpty,
                      "applying releases the ledger entry")
        XCTAssertTrue(
            alpha.transcript.messages.contains { $0.role == .user && $0.text == "for alpha" }
        )
        await drainUntil { !alpha.isBusy }
    }

    /// An out-of-ordinal-order array: d-2 starts a turn, and d-1 — landing on the
    /// now-busy runtime — QUEUES behind it in the same pass. Queued counts as
    /// applied (the runtime's FIFO queue guarantees execution), so the lower
    /// ordinal is never stranded under the advanced mark and never ledgered.
    @MainActor
    func testOutOfOrderArrayDoesNotStrandTheLowerOrdinal() async {
        let (runtime, _, _) = makeRuntime()
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let doc = document("""
        {"directives":[
          {"id":"d-2","kind":"user_message","text":"second"},
          {"id":"d-1","kind":"user_message","text":"first"}
        ]}
        """)
        channel.applyDirectives(doc)
        XCTAssertTrue(AppliedDirectiveStore().contains("d-2"))
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"),
                      "d-1 queues behind d-2's turn and counts as applied")
        XCTAssertTrue(AppliedDirectiveStore().deferredOrdinals.isEmpty,
                      "a queued directive is applied, never ledgered")

        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && runtime.transcript.messages.filter { $0.role == .user }.count == 2
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["second", "first"],
            "the queue preserves document order: d-1 ran after d-2's turn finished"
        )
    }

    /// A fresh (200) document prunes ledger entries whose ordinal it no longer
    /// carries — a pruned directive can never apply, so nothing may keep it alive.
    @MainActor
    func testFreshDocumentPrunesVanishedLedgerEntries() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches = 0 }
        let box = Box()
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                let body = box.fetches == 1
                    ? #"{"version":1,"directives":[{"id":"d-1","kind":"user_message","text":"a"}]}"#
                    : #"{"version":1,"directives":[{"id":"d-3","kind":"user_message","text":"b"}]}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["ETag": "\"v\(box.fetches)\""]
                    )!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.liveTargets = { [] } // everything defers
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertEqual(AppliedDirectiveStore().deferredOrdinals, [1])

        await channel.pollOnce()
        XCTAssertEqual(AppliedDirectiveStore().deferredOrdinals, [3],
                       "d-1 vanished from the document, so its ledger entry is pruned")
    }

    /// The ledger caps at 200 entries; the oldest is evicted with one audit line
    /// per launch, and everything still ledgered stays retryable.
    @MainActor
    func testDeferredLedgerCapEvictsOldestWithOneAuditLine() {
        var auditLines: [String] = []
        let channel = makeChannel()
        channel.audit = { auditLines.append($0) }
        channel.liveTargets = { [] } // everything defers

        func deferDoc(_ range: ClosedRange<Int>) -> RemoteDirectiveDocument {
            let entries = range.map { #"{"id":"d-\#($0)","kind":"user_message","text":"t"}"# }
            return document(#"{"version":1,"directives":[\#(entries.joined(separator: ","))]}"#)
        }
        channel.applyDirectives(deferDoc(1...100))
        channel.applyDirectives(deferDoc(101...200))
        XCTAssertEqual(AppliedDirectiveStore().deferredOrdinals.count, 200)
        XCTAssertTrue(auditLines.filter { $0.hasPrefix("[s3] deferred ledger full") }.isEmpty)

        channel.applyDirectives(deferDoc(201...202))
        let store = AppliedDirectiveStore()
        XCTAssertEqual(store.deferredOrdinals.count, 200, "the cap holds")
        XCTAssertFalse(store.deferredOrdinals.contains(1), "oldest entries are evicted")
        XCTAssertFalse(store.deferredOrdinals.contains(2))
        XCTAssertTrue(store.deferredOrdinals.contains(202))
        XCTAssertEqual(
            auditLines.filter { $0 == "[s3] deferred ledger full: evicted oldest ordinal" }.count, 1,
            "eviction audits once per launch, not once per evicted entry"
        )
    }

    /// A hard skip resolves an ordinal like an apply: mark advanced, ledger
    /// released — and a hard-skipped id never re-audits as anything but a replay.
    func testHardSkipAdvancesMarkAndReleasesLedgerEntry() {
        var store = AppliedDirectiveStore()
        store.markDeferred("d-7")
        XCTAssertEqual(store.deferredOrdinals, [7])
        store.markHardSkipped("d-7")
        XCTAssertTrue(store.deferredOrdinals.isEmpty)
        XCTAssertEqual(store.lastAppliedOrdinal, 7)
        XCTAssertTrue(store.isBelowHighWaterMark("d-7"))
        store.markHardSkipped("free-form")
        XCTAssertEqual(store.lastAppliedOrdinal, 7, "free-form ids never move the mark")

        let reloaded = AppliedDirectiveStore()
        XCTAssertEqual(reloaded.lastAppliedOrdinal, 7, "resolution survives a relaunch")
        XCTAssertTrue(reloaded.deferredOrdinals.isEmpty, "the ledger is persisted state")
    }

    // MARK: - Application

    @MainActor
    func testUnknownKindSkippedWithOneAuditLineAndNeverApplied() {
        var auditLines: [String] = []
        let channel = makeChannel()
        channel.audit = { auditLines.append($0) }
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let doc = document(#"{"directives":[{"id":"d-x","kind":"future_kind"}]}"#)
        channel.applyDirectives(doc)
        channel.applyDirectives(doc)
        XCTAssertEqual(
            auditLines.filter { $0.contains("skipped directive d-x") }.count, 1,
            "skip audits once, not per poll"
        )
        XCTAssertFalse(AppliedDirectiveStore().contains("d-x"),
                       "unknown kinds stay unapplied for a future build")
        XCTAssertFalse(runtime.isBusy)
    }

    @MainActor
    func testInjectionUsesSubmitPathAndAuditsApplied() async {
        var records: [AgentLogRecord] = []
        let (runtime, agent, _) = makeRuntime(log: { records.append($0) })
        // A pre-existing disarm: a real submit lifts suppression, so a directive
        // through the same path must too.
        MonitorSuppressionStore.shared.suppress(agent.id)

        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        channel.applyDirectives(document(
            #"{"directives":[{"id":"d-0001","agent":"fin","kind":"user_message","text":"check the build"}]}"#
        ))

        XCTAssertTrue(
            runtime.transcript.messages.contains { $0.role == .user && $0.text == "check the build" },
            "the transcript gains the directive as a plain user message"
        )
        XCTAssertFalse(runtime.monitoringSuppressed, "submit-path injection lifts suppression")
        XCTAssertTrue(AppliedDirectiveStore().contains("d-0001"))
        XCTAssertTrue(records.contains { $0.kind == .notice && $0.text == "[s3] applied directive d-0001" })
        XCTAssertTrue(records.contains { $0.kind == .userMessage && $0.text == "check the build" })

        await drainUntil { !runtime.isBusy }
    }

    @MainActor
    func testDeferOnDisconnectedSessionIsRetriedNotSkipped() async {
        let (runtime, _, _) = makeRuntime(connected: false)
        var connected = false
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: connected)] }

        let doc = document(
            #"{"directives":[{"id":"d-1","kind":"user_message","text":"hello"}]}"#
        )
        channel.applyDirectives(doc)
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"), "disconnected session defers")
        XCTAssertFalse(runtime.isBusy)

        connected = true
        channel.applyDirectives(doc)
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"), "the deferral was a retry, not a skip")
        await drainUntil { !runtime.isBusy }
    }

    @MainActor
    func testBusyRuntimeQueuesDirectivesInOrder() async {
        let (runtime, _, _) = makeRuntime()
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let doc = document("""
        {"directives":[
          {"id":"d-1","kind":"user_message","text":"first"},
          {"id":"d-2","kind":"user_message","text":"second"}
        ]}
        """)
        channel.applyDirectives(doc)
        // Applying d-1 makes the runtime busy synchronously; d-2 queues behind it
        // in the same pass and counts as applied — the runtime's FIFO queue
        // guarantees per-agent ordering.
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"))
        XCTAssertTrue(AppliedDirectiveStore().contains("d-2"))
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["first"],
            "d-2 waits in the queue while d-1's turn runs"
        )
        XCTAssertEqual(runtime.queuedPrompts, ["second"])

        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && runtime.transcript.messages.filter { $0.role == .user }.count == 2
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["first", "second"],
            "the queued directive ran after the in-flight turn, in order"
        )

        // A later pass re-applies nothing: both ids are in the applied set.
        channel.applyDirectives(doc)
        XCTAssertEqual(runtime.transcript.messages.filter { $0.role == .user }.count, 2)
        XCTAssertTrue(runtime.queuedPrompts.isEmpty)
    }

    /// A directive landing while a user-submitted turn is in flight — the exact
    /// field failure — is queued and marked applied, then runs when the turn ends.
    @MainActor
    func testDirectiveOnBusyRuntimeQueuesAndRunsAfterInFlightTurn() async {
        var records: [AgentLogRecord] = []
        let (runtime, _, _) = makeRuntime(log: { records.append($0) })
        runtime.submit("typed by the user")
        XCTAssertTrue(runtime.isBusy)

        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        channel.applyDirectives(document(
            #"{"directives":[{"id":"d-9","kind":"user_message","text":"from the supervisor"}]}"#
        ))

        XCTAssertTrue(AppliedDirectiveStore().contains("d-9"),
                      "queued counts as applied — the queue guarantees execution")
        XCTAssertEqual(runtime.queuedPrompts, ["from the supervisor"])
        XCTAssertTrue(records.contains { $0.kind == .notice && $0.text == "[s3] applied directive d-9" })

        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && runtime.transcript.messages.filter { $0.role == .user }.count == 2
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["typed by the user", "from the supervisor"],
            "the queued directive ran after the user's in-flight turn"
        )
    }

    @MainActor
    func testManualModeKeepsApprovalGateAndNeverArms() async {
        let (runtime, agent, _) = makeRuntime(mode: .manual)
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        channel.applyDirectives(document(
            #"{"directives":[{"id":"d-1","kind":"user_message","text":"run the deploy","arm_monitor":true,"interval_seconds":60}]}"#
        ))
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"))
        XCTAssertTrue(
            runtime.transcript.messages.contains { $0.role == .user && $0.text == "run the deploy" }
        )
        // The monitor-tool path refuses in manual mode; a remote directive gets no
        // more privilege than the model's own tool call.
        XCTAssertFalse(runtime.isMonitoring)
        XCTAssertFalse(agent.monitoringArmed)
        await drainUntil { !runtime.isBusy }

        // And send_input still parks on approval — no bypass arrived with the channel.
        XCTAssertEqual(runtime.mode, .manual)
        let call = Task {
            await runtime.executeSendInput(input: "echo hi\n", awaitOutputSeconds: 1, rawArguments: "{}")
        }
        await drainUntil { runtime.pendingApproval != nil }
        XCTAssertEqual(runtime.pendingApproval?.reason, .manualMode)
        runtime.rejectPendingCall()
        let result = await call.value
        XCTAssertTrue(result.contains("declined"))
    }

    @MainActor
    func testArmMonitorUsesToolSemanticsWithClampedInterval() async {
        for (requested, expected) in [(5, 15), (10_000, 600), (nil, 60), (120, 120)] as [(Int?, Int)] {
            Self.scrubDurableState()
            let (runtime, agent, _) = makeRuntime()
            let channel = makeChannel()
            channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
            let interval = requested.map { ",\"interval_seconds\":\($0)" } ?? ""
            channel.applyDirectives(document(
                #"{"directives":[{"id":"d-1","kind":"user_message","text":"watch it","arm_monitor":true"# + interval + "}]}"
            ))
            XCTAssertEqual(agent.heartbeatSeconds, expected, "requested \(String(describing: requested))")
            XCTAssertTrue(runtime.isMonitoring)
            XCTAssertEqual(
                MonitorSuppressionStore.shared.armSource(for: agent.id), .tool,
                "a directive arm carries model-tool provenance, not watchdog's budget"
            )
            await drainUntil { !runtime.isBusy }
            runtime.cancel()
        }

        // The agent's configured cadence is authoritative when the directive
        // omits the interval — no hardcoded 60 overrides the user's stepper.
        Self.scrubDurableState()
        let (configured, configuredAgent, _) = makeRuntime(heartbeatSeconds: 120)
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: configured, sessionConnected: true)] }
        channel.applyDirectives(document(
            #"{"directives":[{"id":"d-1","kind":"user_message","text":"watch it","arm_monitor":true}]}"#
        ))
        XCTAssertEqual(configuredAgent.heartbeatSeconds, 120,
                       "an omitted interval defers to the agent's own setting")
        XCTAssertTrue(configured.isMonitoring)
        await drainUntil { !configured.isBusy }
        configured.cancel()
    }

    // MARK: - Input bounds

    @MainActor
    func testOversizeBodyIsAPollFailure() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches = 0 }
        let box = Box()
        var auditLines: [String] = []
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                if box.fetches == 1 {
                    // Actual body over the cap.
                    return (
                        Data(count: AgentDirectiveChannel.maxBodyBytes + 1),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
                    )
                }
                // Small body, but Content-Length promises more than the cap.
                return (
                    Data("{}".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Length": "999999999"]
                    )!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.audit = { auditLines.append($0) }
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertTrue(auditLines.contains("[s3] poll failed: body too large"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: RemoteSupervisionConfig.lastPollStatusKey),
                       "failed: body too large")
        XCTAssertTrue(AppliedDirectiveStore().ids.isEmpty, "nothing was applied")

        await channel.pollOnce()
        XCTAssertEqual(UserDefaults.standard.string(forKey: RemoteSupervisionConfig.lastPollStatusKey),
                       "failed: body too large",
                       "an oversize Content-Length promise fails without trusting the body")
    }

    /// Boundary table for the health badge's one definition of "healthy": enabled,
    /// last poll succeeded, and recent enough (90s window).
    func testIsHealthyBoundaryTable() {
        let defaults = UserDefaults.standard
        let now = Date()

        struct Case {
            let name: String
            let enabled: Bool
            let ageSeconds: TimeInterval?   // nil = no poll ever recorded
            let status: String?
            let expected: Bool
        }
        let cases: [Case] = [
            .init(name: "89s-old ok poll is healthy",
                  enabled: true, ageSeconds: 89, status: "ok (1 directive(s))", expected: true),
            .init(name: "not-modified counts as success",
                  enabled: true, ageSeconds: 10, status: "not modified", expected: true),
            .init(name: "exactly 90s is still healthy",
                  enabled: true, ageSeconds: 90, status: "ok (0 directive(s))", expected: true),
            .init(name: "91s-old ok poll is stale",
                  enabled: true, ageSeconds: 91, status: "ok (1 directive(s))", expected: false),
            .init(name: "recent failure is not healthy",
                  enabled: true, ageSeconds: 5, status: "failed: HTTP 403", expected: false),
            .init(name: "disabled is never healthy",
                  enabled: false, ageSeconds: 5, status: "ok (1 directive(s))", expected: false),
            .init(name: "no poll recorded is not healthy",
                  enabled: true, ageSeconds: nil, status: nil, expected: false),
        ]

        for testCase in cases {
            defaults.set(testCase.enabled, forKey: RemoteSupervisionConfig.enabledKey)
            if let age = testCase.ageSeconds {
                defaults.set(now.addingTimeInterval(-age),
                             forKey: RemoteSupervisionConfig.lastPollAtKey)
            } else {
                defaults.removeObject(forKey: RemoteSupervisionConfig.lastPollAtKey)
            }
            if let status = testCase.status {
                defaults.set(status, forKey: RemoteSupervisionConfig.lastPollStatusKey)
            } else {
                defaults.removeObject(forKey: RemoteSupervisionConfig.lastPollStatusKey)
            }
            XCTAssertEqual(
                RemoteSupervisionConfig.isHealthy(now: now), testCase.expected, testCase.name
            )
        }
    }

    /// N2: the body cap must bound memory, not just processing. The production
    /// fetch streams through `accumulateBody`, which stops pulling one byte past
    /// the cap and cancels the transfer — an endless body is never drained.
    func testStreamingAccumulatorStopsReadingPastTheCap() async throws {
        final class Counter: @unchecked Sendable {
            var pulled = 0
            var cancelled = false
        }
        let counter = Counter()
        let cap = 64
        let endlessBody = AsyncStream<UInt8>(unfolding: {
            counter.pulled += 1
            return 0x20 // an unbounded run of spaces
        })

        let data = try await AgentDirectiveChannel.accumulateBody(endlessBody, cap: cap) {
            counter.cancelled = true
        }
        XCTAssertEqual(data.count, cap + 1,
                       "exactly one byte past the cap — enough to fail the size check, no more")
        XCTAssertTrue(counter.cancelled, "the transfer is cancelled, not abandoned mid-stream")
        XCTAssertLessThanOrEqual(counter.pulled, cap + 2,
                                 "the endless body was never drained past the cap")
    }

    @MainActor
    func testDirectiveCountCapIgnoresExcessWithOneAuditLine() {
        var auditLines: [String] = []
        let channel = makeChannel()
        channel.audit = { auditLines.append($0) }
        channel.liveTargets = { [] }

        // 100 processable directives plus a 101st whose unknown kind WOULD audit a
        // skip if the apply loop ever reached it.
        let entries = (1...100).map {
            #"{"id":"n-\#($0)","kind":"user_message","text":"t"}"#
        } + [#"{"id":"n-101","kind":"bogus_kind"}"#]
        let doc = document(#"{"version":1,"directives":[\#(entries.joined(separator: ","))]}"#)

        channel.applyDirectives(doc)
        channel.applyDirectives(doc)
        XCTAssertEqual(
            auditLines.filter { $0.hasPrefix("[s3] directive document truncated") }.count, 1,
            "the truncation audits once per launch"
        )
        XCTAssertFalse(auditLines.contains { $0.contains("n-101") },
                       "the 101st directive is never processed")
    }

    @MainActor
    func testOverlongDirectiveTextIsSkippedNeverInjected() {
        var auditLines: [String] = []
        let channel = makeChannel()
        channel.audit = { auditLines.append($0) }
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let long = String(repeating: "a", count: AgentDirectiveChannel.maxDirectiveTextLength + 1)
        channel.applyDirectives(document(
            #"{"directives":[{"id":"d-big","kind":"user_message","text":"\#(long)"}]}"#
        ))
        XCTAssertFalse(runtime.isBusy)
        XCTAssertTrue(runtime.transcript.messages.filter { $0.role == .user }.isEmpty)
        XCTAssertFalse(AppliedDirectiveStore().contains("d-big"))
        XCTAssertEqual(
            auditLines.filter {
                $0 == "[s3] skipped directive d-big: text exceeds 8000 characters"
            }.count, 1
        )
    }

    @MainActor
    func testAuditedSkipsCapEvictsOldest() {
        var auditLines: [String] = []
        let channel = makeChannel()
        channel.audit = { auditLines.append($0) }
        channel.liveTargets = { [] }

        func skipDoc(_ ids: [String]) -> RemoteDirectiveDocument {
            let entries = ids.map { #"{"id":"\#($0)","kind":"bogus_kind"}"# }
            return document(#"{"version":1,"directives":[\#(entries.joined(separator: ","))]}"#)
        }
        // Fill the once-per-launch memory exactly to its cap, then push one more
        // to evict k-1 — whose next skip audits again instead of growing without
        // bound in the other direction.
        channel.applyDirectives(skipDoc((1...100).map { "k-\($0)" }))
        channel.applyDirectives(skipDoc(["k-101"]))
        channel.applyDirectives(skipDoc(["k-1"]))
        XCTAssertEqual(
            auditLines.filter { $0.hasPrefix("[s3] skipped directive k-1: ") }.count, 2,
            "eviction from the capped memory allows a re-audit"
        )
        XCTAssertEqual(
            auditLines.filter { $0.hasPrefix("[s3] skipped directive k-2: ") }.count, 1,
            "unevicted ids still audit only once"
        )
    }

    // MARK: - Status payload

    @MainActor
    func testStatusBodyIsRedactedAndCarriesTheSchema() throws {
        let (runtime, _, _) = makeRuntime(history: [
            AgentMessage(role: .user, text: "what did it print?"),
            AgentMessage(role: .assistant, text: "the key is AKIAIOSFODNN7EXAMPLE — careful"),
        ])
        var applied = AppliedDirectiveStore()
        applied.markApplied("d-9")
        let channel = makeChannel()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }

        let body = channel.statusBody()
        XCTAssertFalse(body.contains("AKIAIOSFODNN7EXAMPLE"), "planted key must not survive")
        XCTAssertTrue(body.contains("[redacted]"))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["agent"] as? String, "Fin")
        XCTAssertEqual(object["state"] as? String, "idle")
        XCTAssertEqual(object["mode"] as? String, "auto")
        XCTAssertEqual(object["monitoring_armed"] as? Bool, false)
        XCTAssertEqual(object["suppressed"] as? Bool, false)
        XCTAssertEqual(object["last_applied_id"] as? String, "d-9")
        XCTAssertNotNil(object["updated_at"] as? String)
        XCTAssertNotNil(object["device_id8"] as? String)
        let preview = try XCTUnwrap(object["last_assistant_preview"] as? String)
        XCTAssertTrue(preview.contains("[redacted]"))
        XCTAssertLessThanOrEqual(preview.count, 200)
    }

    @MainActor
    func testRunStateLabels() {
        XCTAssertEqual(AgentDirectiveChannel.stateLabel(.idle), "idle")
        XCTAssertEqual(AgentDirectiveChannel.stateLabel(.thinking), "thinking")
        XCTAssertEqual(AgentDirectiveChannel.stateLabel(.failed("x")), "failed")
        XCTAssertEqual(
            AgentDirectiveChannel.stateLabel(.awaitingApproval(
                call: AgentToolCall(id: "c", name: "send_input", arguments: "{}"),
                reason: .manualMode
            )),
            "awaitingApproval"
        )
    }

    // MARK: - Throttles (pure)

    func testStatusPutThrottleIsTrailingEdge() {
        var throttle = RemoteStatusPutThrottle()
        let start = Date()
        XCTAssertTrue(throttle.shouldSend(now: start), "first send goes out immediately")
        XCTAssertFalse(throttle.shouldSend(now: start.addingTimeInterval(5)))
        XCTAssertTrue(throttle.pending, "a suppressed PUT is remembered, not dropped")
        XCTAssertFalse(throttle.shouldSend(now: start.addingTimeInterval(14.9)))
        XCTAssertTrue(throttle.shouldSend(now: start.addingTimeInterval(15)),
                      "the next opportunity past the window sends")
        XCTAssertFalse(throttle.pending, "sending clears the pending mark")
    }

    func testStatusPutThrottleRemainingWindow() {
        var throttle = RemoteStatusPutThrottle()
        let start = Date()
        XCTAssertNil(throttle.remainingWindow(now: start), "nothing pending, nothing to flush")
        XCTAssertTrue(throttle.shouldSend(now: start))
        XCTAssertNil(throttle.remainingWindow(now: start), "a send leaves nothing pending")
        XCTAssertFalse(throttle.shouldSend(now: start.addingTimeInterval(5)))
        let remaining = throttle.remainingWindow(now: start.addingTimeInterval(5))
        XCTAssertEqual(remaining ?? -1, 10, accuracy: 0.001)
    }

    /// F5: a PUT suppressed by the 15s window is flushed by a scheduled task when
    /// the window closes, not merely remembered until the next poll happens by.
    @MainActor
    func testSuppressedStatusPutFlushesAtWindowEnd() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)
        UserDefaults.standard.set("https://example.com/status.json",
                                  forKey: RemoteSupervisionConfig.statusURLKey)

        final class Box { var puts = 0 }
        let box = Box()
        let channel = AgentDirectiveChannel(
            fetch: { request in
                (
                    Data(#"{"version":1,"directives":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                box.puts += 1
                return HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            }
        )
        channel.statusPutWindow = 1.0
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        await channel.pollOnce()
        XCTAssertEqual(box.puts, 1, "the second PUT inside the window is suppressed")

        let deadline = Date().addingTimeInterval(5)
        while box.puts < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(box.puts, 2, "the trailing-edge flush uplinked the pending status")
    }

    /// F4: a turn finishing while the app is not active must not fire network I/O.
    @MainActor
    func testTurnFinishPollNeverFiresWhileInactive() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches = 0 }
        let box = Box()
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                return (
                    Data(#"{"version":1,"directives":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )

        channel.agentTurnFinished()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(box.fetches, 0, "inactive app: turn finish polls nothing")

        channel.setActiveForTesting(true)
        channel.agentTurnFinished()
        await drainUntil { box.fetches == 1 }
        XCTAssertEqual(box.fetches, 1, "active app: turn finish polls immediately")
    }

    /// F4: a poll requested while another is in flight coalesces into exactly one
    /// follow-up poll instead of being dropped.
    @MainActor
    func testInFlightPollCoalescesFollowUpInsteadOfDropping() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box {
            var fetches = 0
            var release: CheckedContinuation<Void, Never>?
        }
        let box = Box()
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                if box.fetches == 1 {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        box.release = continuation
                    }
                }
                return (
                    Data(#"{"version":1,"directives":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.setActiveForTesting(true)

        let first = Task { await channel.pollOnce() }
        await drainUntil { box.release != nil }
        // Two asks while the first fetch is parked — both must coalesce into ONE
        // follow-up poll after the in-flight one completes.
        channel.agentTurnFinished()
        channel.agentTurnFinished()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(box.fetches, 1, "no concurrent second fetch")

        box.release?.resume()
        _ = await first.value
        await drainUntil { box.fetches == 2 }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(box.fetches, 2, "exactly one coalesced follow-up, not one per ask")
    }

    /// F6: a document fetched just before the user disables the channel must not be
    /// applied after the await resumes.
    @MainActor
    func testDisableLandingMidFetchIsNotApplied() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        let channel = AgentDirectiveChannel(
            fetch: { request in
                // The user toggles the channel off while the GET is in flight.
                UserDefaults.standard.set(false, forKey: RemoteSupervisionConfig.enabledKey)
                return (
                    Data(#"{"directives":[{"id":"d-1","kind":"user_message","text":"late"}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertFalse(runtime.isBusy, "a disable that lands mid-fetch wins")
        XCTAssertTrue(runtime.transcript.messages.filter { $0.role == .user }.isEmpty)
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"))
    }

    // MARK: - Failure-text hygiene

    private struct LeakyError: LocalizedError {
        var errorDescription: String?
    }

    /// F8: failure text can embed the failing URL — and the presigned query string
    /// IS the credential — so audit lines and the status document must never carry
    /// the configured URLs or any X-Amz token.
    @MainActor
    func testFailureTextNeverLeaksURLsOrPresignedTokens() async {
        let sentinel = "https://bucket.s3.amazonaws.com/cap/directives.json"
            + "?X-Amz-Signature=abc123&X-Amz-Credential=AKIA%2Ffoo"
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set(sentinel, forKey: RemoteSupervisionConfig.directiveURLKey)

        var auditLines: [String] = []
        let channel = AgentDirectiveChannel(
            fetch: { _ in
                throw LeakyError(errorDescription:
                    "could not load \(sentinel) and also X-Amz-Security-Token=SEKRET99 leaked")
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.audit = { auditLines.append($0) }
        await channel.pollOnce()

        let failure = auditLines.first { $0.hasPrefix("[s3] poll failed: ") }
        XCTAssertNotNil(failure)
        XCTAssertFalse(failure?.contains("bucket.s3.amazonaws.com") ?? true)
        XCTAssertFalse(failure?.contains("X-Amz-Signature=abc123") ?? true)
        XCTAssertFalse(failure?.contains("SEKRET99") ?? true)

        let pollStatus = UserDefaults.standard.string(
            forKey: RemoteSupervisionConfig.lastPollStatusKey) ?? ""
        XCTAssertFalse(pollStatus.contains("bucket.s3.amazonaws.com"))
        XCTAssertFalse(pollStatus.contains("SEKRET99"))

        let body = channel.statusBody()
        XCTAssertFalse(body.contains("bucket.s3.amazonaws.com"))
        XCTAssertFalse(body.contains("SEKRET99"))
    }

    // MARK: - Lifecycle audit dedupe

    /// F7: scenePhase flapping and reconnect storms repeat identical lifecycle
    /// lines; an identical line inside the 30s window is dropped, [app] and
    /// [session] alike, while distinct lines pass.
    @MainActor
    func testLifecycleAuditDedupesIdenticalLinesWithinWindow() {
        let manager = SessionManager()
        var lines: [String] = []
        let agentID = UUID()
        manager.lifecycleAuditAgents = { [(id: agentID, name: "Fin")] }
        manager.onAgentLog = { lines.append($0.text) }

        let start = Date()
        manager.recordLifecycleEvent("[app] foregrounded", now: start)
        manager.recordLifecycleEvent("[app] foregrounded", now: start.addingTimeInterval(5))
        manager.recordLifecycleEvent("[session] connected to box", now: start.addingTimeInterval(5))
        manager.recordLifecycleEvent("[session] connected to box", now: start.addingTimeInterval(6))
        manager.recordLifecycleEvent("[app] backgrounded", now: start.addingTimeInterval(7))
        manager.recordLifecycleEvent("[app] foregrounded", now: start.addingTimeInterval(36))

        XCTAssertEqual(lines.filter { $0 == "[app] foregrounded" }.count, 2,
                       "the repeat inside 30s is dropped; past the window it logs again")
        XCTAssertEqual(lines.filter { $0 == "[session] connected to box" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "[app] backgrounded" }.count, 1,
                       "distinct lines are never suppressed by each other")
    }

    func testFailureAuditThrottlePerDistinctError() {
        var throttle = RemoteFailureAuditThrottle()
        let start = Date()
        XCTAssertTrue(throttle.shouldAudit("timeout", now: start))
        XCTAssertFalse(throttle.shouldAudit("timeout", now: start.addingTimeInterval(60)))
        XCTAssertTrue(throttle.shouldAudit("HTTP 403", now: start.addingTimeInterval(60)),
                      "a distinct error string audits independently")
        XCTAssertTrue(throttle.shouldAudit("timeout", now: start.addingTimeInterval(301)),
                      "the same error audits again after the window")
    }

    // MARK: - ETag / fetch disposition (pure)

    func testFetchDispositionClassification() {
        XCTAssertEqual(RemoteFetchDisposition.classify(statusCode: 304, etag: nil), .notModified)
        XCTAssertEqual(
            RemoteFetchDisposition.classify(statusCode: 200, etag: "\"v1\""),
            .apply(etag: "\"v1\"")
        )
        XCTAssertEqual(RemoteFetchDisposition.classify(statusCode: 204, etag: nil), .apply(etag: nil))
        XCTAssertEqual(RemoteFetchDisposition.classify(statusCode: 403, etag: nil), .failure("HTTP 403"))
        XCTAssertEqual(RemoteFetchDisposition.classify(statusCode: 500, etag: nil), .failure("HTTP 500"))
    }

    @MainActor
    func testPollSendsStoredETagAnd304AppliesNothing() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)
        UserDefaults.standard.set("https://example.com/status.json",
                                  forKey: RemoteSupervisionConfig.statusURLKey)

        final class Box { var fetches: [URLRequest] = []; var puts: [URLRequest] = [] }
        let box = Box()
        let body = #"{"version":1,"directives":[{"id":"d-1","kind":"user_message","text":"hi"}]}"#

        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches.append(request)
                if box.fetches.count == 1 {
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": "\"v1\""]
                        )!
                    )
                }
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                box.puts.append(request)
                return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertNil(box.fetches[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"))
        XCTAssertEqual(box.puts.count, 1, "each poll cycle ends with a status PUT")
        XCTAssertEqual(box.puts[0].httpMethod, "PUT")
        XCTAssertEqual(box.puts[0].value(forHTTPHeaderField: "Content-Type"), "application/json")

        await drainUntil { !runtime.isBusy }
        await channel.pollOnce()
        XCTAssertEqual(box.fetches[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.count, 1,
            "304 re-runs the cached document; the applied set makes it a no-op"
        )
        XCTAssertEqual(box.puts.count, 1, "the second PUT inside 15s is trailing-edge suppressed")
    }

    /// The exact starvation scenario the ETag adds: the first poll caches the
    /// document but no live runtime exists, so both directives defer — and the
    /// poll after the runtime appears gets a 304. The cached document's re-run
    /// must apply them — a deferred directive is retried on every poll, unchanged
    /// bytes or not. (A busy runtime no longer defers: it queues, so absence is
    /// the deferral cause exercised here.)
    @MainActor
    func testDeferredDirectiveIsAppliedByA304PollAfterRuntimeAppears() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches: [URLRequest] = [] }
        let box = Box()
        let body = """
        {"version":1,"directives":[
          {"id":"d-1","agent":"fin","kind":"user_message","text":"first"},
          {"id":"d-2","agent":"fin","kind":"user_message","text":"second"}
        ]}
        """
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches.append(request)
                if box.fetches.count == 1 {
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": "\"v1\""]
                        )!
                    )
                }
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        var targets: [AgentDirectiveChannel.Target] = []
        channel.liveTargets = { targets }
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"),
                       "no live runtime: both directives defer")
        XCTAssertFalse(AppliedDirectiveStore().contains("d-2"))

        let (runtime, _, _) = makeRuntime()
        targets = [.init(runtime: runtime, sessionConnected: true)]
        await channel.pollOnce()
        XCTAssertEqual(box.fetches[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"),
                      "the 304 poll must not starve deferred directives")
        XCTAssertTrue(AppliedDirectiveStore().contains("d-2"),
                      "d-2 queues behind d-1's turn and counts as applied")
        await drainUntil {
            !runtime.isBusy && runtime.queuedPrompts.isEmpty
                && runtime.transcript.messages.filter { $0.role == .user }.count == 2
        }
        XCTAssertEqual(
            runtime.transcript.messages.filter { $0.role == .user }.map(\.text),
            ["first", "second"]
        )
    }

    /// Field regression: an agent chaining turns has idle gaps of a few seconds, and
    /// a turn-finish poll that pays fetch latency before applying loses that race
    /// every time. The turn-finish hook must apply from the cached document
    /// synchronously — while the runtime is provably idle — before fetching.
    @MainActor
    func testTurnFinishAppliesFromCacheBeforeFetching() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches = 0 }
        let box = Box()
        let body = """
        {"version":1,"directives":[
          {"id":"d-1","agent":"fin","kind":"user_message","text":"first"},
          {"id":"d-2","agent":"fin","kind":"user_message","text":"second"}
        ]}
        """
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches += 1
                if box.fetches == 1 {
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": "\"v1\""]
                        )!
                    )
                }
                // A slow network: the follow-up fetch must not be what delivers d-2.
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        var targets: [AgentDirectiveChannel.Target] = []
        channel.liveTargets = { targets }
        channel.setActiveForTesting(true)

        // First poll caches the document; with no live runtime both defer.
        await channel.pollOnce()
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"))
        XCTAssertFalse(AppliedDirectiveStore().contains("d-2"))

        let (runtime, _, _) = makeRuntime()
        targets = [.init(runtime: runtime, sessionConnected: true)]
        channel.agentTurnFinished()
        XCTAssertTrue(AppliedDirectiveStore().contains("d-1"),
                      "turn-finish must apply the cached document synchronously, before any fetch")
        XCTAssertTrue(AppliedDirectiveStore().contains("d-2"),
                      "the second directive queues behind the first — still applied synchronously")
        await drainUntil { !runtime.isBusy && runtime.queuedPrompts.isEmpty }
    }

    /// N3: a pasted new directive URL is a new document identity — the next poll
    /// must not revalidate the old URL's ETag, and a 304 with no cache applies
    /// nothing (the old URL's cached document is gone).
    @MainActor
    func testDirectiveURLChangeClearsETagAndCachedDocument() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/old.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        final class Box { var fetches: [URLRequest] = [] }
        let box = Box()
        let body = #"{"version":1,"directives":[{"id":"d-1","kind":"user_message","text":"stale"}]}"#
        let channel = AgentDirectiveChannel(
            fetch: { request in
                box.fetches.append(request)
                if box.fetches.count == 1 {
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["ETag": "\"v1\""]
                        )!
                    )
                }
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                )
            },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.liveTargets = { [] } // d-1 defers; the document is cached
        channel.setActiveForTesting(true)

        await channel.pollOnce()
        XCTAssertEqual(box.fetches.count, 1)

        // Now a runtime is available — but the URL changes, so the old cache must
        // not be what a 304 against the NEW URL replays.
        let (runtime, _, _) = makeRuntime()
        channel.liveTargets = { [.init(runtime: runtime, sessionConnected: true)] }
        RemoteSupervisionConfig.setDirectiveURL("https://example.com/new.json")
        await drainUntil { box.fetches.count >= 2 }

        XCTAssertNil(box.fetches[1].value(forHTTPHeaderField: "If-None-Match"),
                     "a new URL must not send the old URL's ETag")
        XCTAssertFalse(runtime.isBusy)
        XCTAssertTrue(runtime.transcript.messages.filter { $0.role == .user }.isEmpty,
                      "a 304 with no cached document applies nothing")
        XCTAssertFalse(AppliedDirectiveStore().contains("d-1"))
    }

    /// N4: a GET that fails after the app resigned active must not fall through
    /// to a status PUT — `uplinkStatus` guards on isActive, covering the failure
    /// path and the flush-task race the success path's guard never sees.
    @MainActor
    func testFetchFailureWhileInactiveIssuesNoStatusPut() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)
        UserDefaults.standard.set("https://example.com/status.json",
                                  forKey: RemoteSupervisionConfig.statusURLKey)

        final class Box { var puts = 0 }
        let box = Box()
        let channel = AgentDirectiveChannel(
            fetch: { _ in throw URLError(.timedOut) },
            put: { request in
                box.puts += 1
                return HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            }
        )

        await channel.pollOnce() // never activated: the failure path reaches uplinkStatus
        XCTAssertEqual(box.puts, 0, "no PUT from a backgrounded app, even on the failure path")

        channel.setActiveForTesting(true)
        await channel.pollOnce()
        XCTAssertEqual(box.puts, 1, "the same failure while active still uplinks status")
    }

    @MainActor
    func testPollFailureAuditIsThrottledPerDistinctError() async {
        UserDefaults.standard.set(true, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)

        var auditLines: [String] = []
        let channel = AgentDirectiveChannel(
            fetch: { _ in throw URLError(.timedOut) },
            put: { request in
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            }
        )
        channel.audit = { auditLines.append($0) }

        await channel.pollOnce()
        await channel.pollOnce()
        let failureLines = auditLines.filter { $0.hasPrefix("[s3] poll failed: ") }
        XCTAssertEqual(failureLines.count, 1, "the same error audits once per 5 minutes")
    }

    @MainActor
    func testDisabledChannelPollsNothing() async {
        UserDefaults.standard.set(false, forKey: RemoteSupervisionConfig.enabledKey)
        UserDefaults.standard.set("https://example.com/directives.json",
                                  forKey: RemoteSupervisionConfig.directiveURLKey)
        var fetched = false
        let channel = AgentDirectiveChannel(
            fetch: { _ in fetched = true; throw URLError(.timedOut) },
            put: { _ in fetched = true; throw URLError(.timedOut) }
        )
        await channel.pollOnce()
        XCTAssertFalse(fetched, "disabled means no network at all")
    }

    // MARK: - Info.plist seeding

    func testSeedingPrecedence() throws {
        let suiteName = "fin.tests.remote-seed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Empty plist values are the dormant default build: nothing seeds, nothing enables.
        XCTAssertFalse(RemoteSupervisionConfig.seedFromInfoPlist(
            ["FinDirectiveURL": "", "FinStatusURL": "  "], defaults: defaults
        ))
        XCTAssertNil(defaults.string(forKey: RemoteSupervisionConfig.directiveURLKey))
        XCTAssertFalse(defaults.bool(forKey: RemoteSupervisionConfig.enabledKey))

        // A stamped build seeds both URLs and turns the channel on.
        XCTAssertTrue(RemoteSupervisionConfig.seedFromInfoPlist(
            ["FinDirectiveURL": "https://example.com/d", "FinStatusURL": "https://example.com/s"],
            defaults: defaults
        ))
        XCTAssertEqual(defaults.string(forKey: RemoteSupervisionConfig.directiveURLKey),
                       "https://example.com/d")
        XCTAssertEqual(defaults.string(forKey: RemoteSupervisionConfig.statusURLKey),
                       "https://example.com/s")
        XCTAssertTrue(defaults.bool(forKey: RemoteSupervisionConfig.enabledKey))

        // An existing (user-pasted) default always wins over a later seed.
        defaults.set(false, forKey: RemoteSupervisionConfig.enabledKey)
        XCTAssertFalse(RemoteSupervisionConfig.seedFromInfoPlist(
            ["FinDirectiveURL": "https://evil.example.com/d"], defaults: defaults
        ))
        XCTAssertEqual(defaults.string(forKey: RemoteSupervisionConfig.directiveURLKey),
                       "https://example.com/d")
        XCTAssertFalse(defaults.bool(forKey: RemoteSupervisionConfig.enabledKey),
                       "a seed that lands nothing must not flip enabled back on")
    }

    // MARK: - Export exclusion

    @MainActor
    func testTranscriptExportNeverContainsRemoteURLs() {
        let sentinel = "https://bucket.s3.amazonaws.com/secret-capability-path?X-Amz-Signature=abc123"
        UserDefaults.standard.set(sentinel, forKey: RemoteSupervisionConfig.directiveURLKey)
        UserDefaults.standard.set(sentinel, forKey: RemoteSupervisionConfig.statusURLKey)

        var transcript = AgentTranscript()
        transcript.reset(systemPrompt: "prompt")
        transcript.append(AgentMessage(role: .user, text: "hello"))
        transcript.append(AgentMessage(role: .assistant, text: "hi there"))
        let agent = Agent(
            name: "Fin", provider: .openAICompatible,
            endpointURL: "http://host:1234/v1", modelIdentifier: "m"
        )

        let export = transcript.markdownExport(agent: agent, serverName: "box")
        XCTAssertFalse(export.contains(sentinel))
        XCTAssertFalse(export.contains("fin.remote"))
        XCTAssertFalse(export.contains("X-Amz-Signature"))
    }

    // MARK: - Redacted display

    func testRedactedDisplayShowsHostAndTruncatedPathOnly() {
        let display = RemoteSupervisionConfig.redactedDisplay(
            "https://bucket.s3.amazonaws.com/some/long/capability/path/directives.json?X-Amz-Signature=abc"
        )
        XCTAssertTrue(display.hasPrefix("bucket.s3.amazonaws.com"))
        XCTAssertFalse(display.contains("X-Amz-Signature"))
        XCTAssertFalse(display.contains("directives.json"), "the tail of the path is truncated")
        XCTAssertEqual(RemoteSupervisionConfig.redactedDisplay(""), "not set")
    }
}
