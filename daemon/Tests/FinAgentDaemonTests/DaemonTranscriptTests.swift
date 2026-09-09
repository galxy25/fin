import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The iOS mirror reader's decode contract, copied from
/// `fin/Agent/AgentMirrorReader.swift` rather than imported: the app target does not
/// build in this package, and the fact that it cannot is exactly why the format has to be
/// pinned here. If this fixture and the reader ever drift, a remote agent's timeline
/// renders empty with no error anywhere.
private enum MirrorReaderContract {
    /// Missing or unparseable → `AgentMirrorRecord.init(jsonlLine:)` returns nil and the
    /// line silently vanishes from the app's timeline.
    static let requiredKeys = ["kind", "timestamp"]
    /// Read when present, defaulted when absent.
    static let optionalKeys = ["id", "text", "sequence", "run_id", "tool_name"]
    /// `AgentLogKind`'s raw values; anything else falls back to `.notice` in the app.
    static let kinds: Set<String> = [
        "userMessage", "assistantMessage", "reasoning", "toolCall",
        "toolResult", "approval", "notice", "error",
        "turnStarted", "turnProgress",
    ]
    /// A default `ISO8601DateFormatter` — no fractional seconds, which it rejects.
    static let timestampFormatter = ISO8601DateFormatter()

    struct Decoded {
        let id: String
        let kind: String
        let text: String
        let timestamp: Date
        let sequence: Int
        let runID: String
        let toolName: String?
    }

    /// The reader's decode path, reproduced: nil exactly where the app's would be nil.
    static func decode(_ line: String) -> Decoded? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kindRaw = object["kind"] as? String,
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = timestampFormatter.date(from: timestampRaw)
        else { return nil }
        return Decoded(
            id: object["id"] as? String ?? UUID().uuidString,
            kind: kinds.contains(kindRaw) ? kindRaw : "notice",
            text: object["text"] as? String ?? "",
            timestamp: timestamp,
            sequence: object["sequence"] as? Int ?? 0,
            runID: object["run_id"] as? String ?? "",
            toolName: object["tool_name"] as? String
        )
    }
}

@MainActor
final class DaemonTranscriptUplinkTests: XCTestCase {

    private let agentID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let runID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

    private func makeUplink(
        flushSeconds: Int = 15,
        maxLines: Int = 2000,
        agentID: UUID? = nil,
        audit: @escaping (String) -> Void = { _ in },
        put: @escaping (URLRequest) async throws -> URLResponse = { request in
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        }
    ) -> DaemonTranscriptUplink {
        DaemonTranscriptUplink(
            endpointURL: "https://cp.example",
            token: "cp-token-123",
            flushSeconds: flushSeconds,
            maxLines: maxLines,
            runID: runID,
            agentID: agentID ?? self.agentID,
            agentName: "fin-agentd-1",
            server: "10.0.0.7",
            modelIdentifier: "google/gemma-4-12b-qat",
            temperature: 0.2,
            audit: audit,
            put: put
        )
    }

    // MARK: - Line format

    func testLineCarriesEveryFieldTheAppReads() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(
            kind: "toolCall", text: "read_terminal (160 lines)",
            toolName: "read_terminal", toolArguments: #"{"lines": 160}"#
        ))

        let line = try XCTUnwrap(uplink.lines.first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        for key in MirrorReaderContract.requiredKeys + MirrorReaderContract.optionalKeys {
            XCTAssertNotNil(object[key], "the app's mirror reader reads \"\(key)\"")
        }

        XCTAssertEqual(object["kind"] as? String, "toolCall")
        XCTAssertEqual(object["text"] as? String, "read_terminal (160 lines)")
        XCTAssertEqual(object["tool_name"] as? String, "read_terminal")
        XCTAssertEqual(object["sequence"] as? Int, 1, "sequences start at 1, as the app's do")
        XCTAssertEqual(object["run_id"] as? String, runID.uuidString)
        XCTAssertEqual(object["agent_id"] as? String, agentID.uuidString)
        XCTAssertEqual(object["agent_id"] as? String, (object["agent_id"] as? String)?.uppercased(),
                       "UUID strings go out uppercase, as Swift's uuidString produces them")
        XCTAssertEqual(object["agent_name"] as? String, "fin-agentd-1")
        XCTAssertEqual(object["server"] as? String, "10.0.0.7")
        XCTAssertEqual(object["model"] as? String, "google/gemma-4-12b-qat")
        XCTAssertEqual(object["temperature"] as? Double, 0.2)
        XCTAssertEqual(object["is_failure"] as? Bool, false)
        XCTAssertNotNil(UUID(uuidString: (object["id"] as? String) ?? ""), "id is a UUID string")
    }

    func testLineDecodesThroughTheMirrorReadersOwnPath() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "the build is green"))

        let decoded = try XCTUnwrap(
            MirrorReaderContract.decode(try XCTUnwrap(uplink.lines.first)),
            "the app's reader must decode this line, not skip it"
        )
        XCTAssertEqual(decoded.kind, "assistantMessage")
        XCTAssertEqual(decoded.text, "the build is green")
        XCTAssertEqual(decoded.sequence, 1)
        XCTAssertEqual(decoded.runID, runID.uuidString)
        XCTAssertNil(decoded.toolName)
    }

    /// `AgentMirrorRecord.timestampFormatter` is a default `ISO8601DateFormatter`, which
    /// returns nil for a fractional-seconds string — every line would be dropped.
    func testTimestampHasNoFractionalSeconds() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "notice", text: "connected"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(uplink.lines.first).utf8)
            ) as? [String: Any]
        )
        let stamp = try XCTUnwrap(object["timestamp"] as? String)
        XCTAssertFalse(stamp.contains("."), "got \(stamp)")
        XCTAssertNotNil(MirrorReaderContract.timestampFormatter.date(from: stamp))
    }

    func testUnknownKindBecomesNotice() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "heartbeatWobble", text: "operational"))
        let decoded = try XCTUnwrap(MirrorReaderContract.decode(try XCTUnwrap(uplink.lines.first)))
        XCTAssertEqual(decoded.kind, "notice")
    }

    func testHeartbeatPromptKeepsItsPrefixAsAUserMessage() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "userMessage", text: Daemon.heartbeatPrompt))
        let decoded = try XCTUnwrap(MirrorReaderContract.decode(try XCTUnwrap(uplink.lines.first)))
        XCTAssertEqual(decoded.kind, "userMessage")
        XCTAssertTrue(decoded.text.hasPrefix("[heartbeat]"),
                      "the app distinguishes beats from real user messages by this prefix")
    }

    func testMissingAgentIDStillEmitsTheKey() throws {
        let uplink = DaemonTranscriptUplink(
            endpointURL: "https://cp.example", token: "t",
            flushSeconds: 15, maxLines: 10, runID: runID, agentID: nil,
            agentName: "Agent", server: "h", modelIdentifier: "m", temperature: 0.2
        )
        uplink.record(AgentAuditEvent(kind: "notice", text: "hello"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(uplink.lines.first).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["agent_id"] as? String,
                       DaemonTranscriptUplink.unsetAgentID.uuidString)
    }

    // MARK: - Redaction

    func testEveryTextFieldIsRedactedBeforeItEntersTheRing() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(
            kind: "toolCall",
            text: "export API_KEY=sk-live-abcdefghijklmnop",
            toolName: "send_input",
            toolArguments: #"{"input": "PGPASSWORD=hunter2 psql"}"#
        ))

        let line = try XCTUnwrap(uplink.lines.first)
        XCTAssertFalse(line.contains("sk-live-abcdefghijklmnop"), "got: \(line)")
        XCTAssertFalse(line.contains("hunter2"), "tool arguments leave the machine too: \(line)")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertTrue((object["text"] as? String)?.contains("[redacted]") == true)
        XCTAssertTrue((object["tool_arguments"] as? String)?.contains("[redacted]") == true)
    }

    // MARK: - Ring

    func testRingKeepsOnlyTheLastMaxLines() {
        let uplink = makeUplink(maxLines: 3)
        for index in 1...10 {
            uplink.record(AgentAuditEvent(kind: "notice", text: "line \(index)"))
        }
        XCTAssertEqual(uplink.lines.count, 3)
        let sequences = uplink.lines.compactMap { MirrorReaderContract.decode($0)?.sequence }
        XCTAssertEqual(sequences, [8, 9, 10], "the oldest lines are evicted, numbering unbroken")
    }

    func testBodyIsTheWholeDocumentNewlineJoined() {
        let uplink = makeUplink(maxLines: 5)
        for index in 1...3 {
            uplink.record(AgentAuditEvent(kind: "notice", text: "line \(index)"))
        }
        let lines = uplink.body.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.compactMap { MirrorReaderContract.decode($0)?.text },
                       ["line 1", "line 2", "line 3"])
    }

    // MARK: - Hour chunking

    func testHourKeyMatchesTheLambdaSideRegex() {
        let date = Date(timeIntervalSince1970: 1_757_372_400) // 2025-09-08T23:00:00Z-ish, exact value irrelevant
        let key = DaemonTranscriptUplink.hourKey(for: date)
        XCTAssertTrue(key.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}$"#, options: .regularExpression) != nil,
                      "got \(key) — must match lambda.py's TRANSCRIPT_HOUR")
    }

    /// The whole point of chunking: an event whose hour differs from the currently
    /// accumulating one flushes the COMPLETED hour under its own key first, then starts a
    /// fresh `lines` array for the new hour — never mixes two hours into one chunk, and
    /// never silently drops the completed hour's lines.
    func testCrossingAnHourBoundaryFlushesTheCompletedHourThenStartsFresh() async throws {
        var requests: [URLRequest] = []
        let uplink = makeUplink(put: { request in
            requests.append(request)
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        })

        var first = AgentAuditEvent(kind: "notice", text: "in hour one")
        first.timestamp = Date(timeIntervalSince1970: 1_757_372_400) // some hour H
        uplink.record(first)
        XCTAssertEqual(uplink.currentHour, DaemonTranscriptUplink.hourKey(for: first.timestamp))

        var second = AgentAuditEvent(kind: "notice", text: "in hour two")
        second.timestamp = first.timestamp.addingTimeInterval(3600) // hour H+1
        uplink.record(second)

        // The boundary crossing's flush is a fire-and-forget Task; give it a moment.
        let deadline = Date().addingTimeInterval(2)
        while requests.isEmpty, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let request = try XCTUnwrap(requests.first, "the completed hour must flush without an explicit flush() call")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["hour"] as? String, DaemonTranscriptUplink.hourKey(for: first.timestamp),
                       "the FIRST (completed) hour, not the one that just started")
        let flushedLines = try XCTUnwrap(object["lines"] as? [String])
        XCTAssertEqual(flushedLines.compactMap { MirrorReaderContract.decode($0)?.text }, ["in hour one"],
                       "only hour one's line — hour two's must not leak into this chunk")

        // The new hour's line stays live, uncommitted, ready for its own eventual flush.
        XCTAssertEqual(uplink.currentHour, DaemonTranscriptUplink.hourKey(for: second.timestamp))
        XCTAssertEqual(uplink.lines.compactMap { MirrorReaderContract.decode($0)?.text }, ["in hour two"])
    }

    // MARK: - Flushing

    func testFlushPutsTheChunkToTheControlPlane() async throws {
        var requests: [URLRequest] = []
        let uplink = makeUplink(put: { request in
            requests.append(request)
            return HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        })
        uplink.record(AgentAuditEvent(kind: "userMessage", text: "one"))
        uplink.record(AgentAuditEvent(kind: "assistantMessage", text: "two"))
        await uplink.flush()

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://cp.example/transcript-chunk")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer cp-token-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["agent"] as? String, "fin-agentd-1")
        XCTAssertEqual(object["hour"] as? String, DaemonTranscriptUplink.hourKey(for: Date()))
        let lines = try XCTUnwrap(object["lines"] as? [String])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.compactMap { MirrorReaderContract.decode($0)?.text }, ["one", "two"])
    }

    func testFlushIsSkippedWhenNothingChanged() async {
        var putCount = 0
        let uplink = makeUplink(put: { request in
            putCount += 1
            return HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        })
        await uplink.flush()
        XCTAssertEqual(putCount, 0, "an empty ring must not PUT")

        uplink.record(AgentAuditEvent(kind: "notice", text: "one"))
        await uplink.flush()
        await uplink.flush()
        XCTAssertEqual(putCount, 1, "a clean ring must not re-PUT the same bytes")
    }

    func testPeriodicFlushWaitsOutTheWindowButAPostTurnFlushDoesNot() async {
        var putCount = 0
        let uplink = makeUplink(flushSeconds: 15, put: { request in
            putCount += 1
            return HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        })
        let start = Date(timeIntervalSince1970: 1_756_400_000)

        uplink.record(AgentAuditEvent(kind: "notice", text: "one"))
        await uplink.flushIfDue(now: start)
        XCTAssertEqual(putCount, 1, "the first dirty tick flushes immediately")

        uplink.record(AgentAuditEvent(kind: "notice", text: "two"))
        await uplink.flushIfDue(now: start.addingTimeInterval(5))
        XCTAssertEqual(putCount, 1, "mid-window ticks are the ceiling this enforces")

        await uplink.flushIfDue(now: start.addingTimeInterval(15))
        XCTAssertEqual(putCount, 2)

        uplink.record(AgentAuditEvent(kind: "notice", text: "three"))
        await uplink.flush(now: start.addingTimeInterval(16))
        XCTAssertEqual(putCount, 3, "an end-of-turn flush ignores the window")
    }

    func testPutFailureIsSwallowedButAuditedOncePerWindow() async {
        var lines: [String] = []
        let uplink = makeUplink(audit: { lines.append($0) }, put: { request in
            HTTPURLResponse(url: request.url!, statusCode: 500,
                            httpVersion: nil, headerFields: nil)!
        })
        for index in 1...3 {
            uplink.record(AgentAuditEvent(kind: "notice", text: "line \(index)"))
            await uplink.flush()
        }
        XCTAssertEqual(lines, ["[transcript] put failed: HTTP 500"],
                       "identical failures throttle to one line per window: \(lines)")
    }

    func testThrownTransportErrorIsSwallowed() async {
        struct Boom: Error {}
        var lines: [String] = []
        let uplink = makeUplink(audit: { lines.append($0) }, put: { _ in throw Boom() })
        uplink.record(AgentAuditEvent(kind: "notice", text: "one"))
        await uplink.flush()
        XCTAssertTrue(lines.contains { $0.hasPrefix("[transcript] put failed:") }, "got: \(lines)")
    }

    // MARK: - Turn visibility (item 6): turnStarted/turnProgress schema

    func testMirrorKindsCarriesTheTurnVisibilitySchema() {
        XCTAssertTrue(DaemonTranscriptUplink.mirrorKinds.contains("turnStarted"))
        XCTAssertTrue(DaemonTranscriptUplink.mirrorKinds.contains("turnProgress"))
        XCTAssertEqual(DaemonTranscriptUplink.immediateFlushKind, "turnStarted")
    }

    /// The one property that makes `turnStarted` worth a dedicated kind at all: the app
    /// must see it within seconds, not wait out a `flushSeconds` window that can be
    /// minutes long. The flush runs as its own unstructured `Task`, so this polls
    /// briefly rather than assuming it has landed the instant `record` returns.
    func testTurnStartedFlushesImmediatelyNotOnTheBatchedInterval() async {
        var putCount = 0
        let uplink = makeUplink(flushSeconds: 300, put: { request in
            putCount += 1
            return HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        })

        uplink.record(AgentAuditEvent(kind: "turnStarted", text: "[turn] started"))

        let deadline = Date().addingTimeInterval(2)
        while putCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(putCount, 1, "turnStarted must flush immediately, not wait for a 300s window")
    }

    /// The immediate flush is turnStarted's special case, not a general "record always
    /// flushes now" regression — every other kind still waits for `flushIfDue`/an
    /// explicit `flush()`, exactly as before this change.
    func testOtherKindsDoNotTriggerAnImmediateFlush() async {
        var putCount = 0
        let uplink = makeUplink(flushSeconds: 300, put: { request in
            putCount += 1
            return HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        })

        uplink.record(AgentAuditEvent(kind: "notice", text: "not urgent"))
        // Give a (wrongly) spawned flush task a moment to land before asserting it didn't.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(putCount, 0, "only turnStarted jumps the batch interval")
    }

    /// Was hardcoded `1`/`0` for every line regardless of what actually happened —
    /// now carries whatever `AgentTurnEngine` stamped on the event.
    func testLineReflectsTheEventsRealAttemptAndRetryCount() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(
            kind: "error", text: "endpoint timed out (attempt 2, retrying)",
            isFailure: true, attempt: 2, retryCount: 1
        ))

        let line = try XCTUnwrap(uplink.lines.first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["attempt"] as? Int, 2)
        XCTAssertEqual(object["retry_count"] as? Int, 1)
    }

    /// An event that never specifies attempt/retryCount (the overwhelming majority of
    /// call sites) still gets the fresh-turn default, unchanged from before this item.
    func testLineDefaultsToAttemptOneRetryCountZero() throws {
        let uplink = makeUplink()
        uplink.record(AgentAuditEvent(kind: "notice", text: "connected"))

        let line = try XCTUnwrap(uplink.lines.first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["attempt"] as? Int, 1)
        XCTAssertEqual(object["retry_count"] as? Int, 0)
    }
}
