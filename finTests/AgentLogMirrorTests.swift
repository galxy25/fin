import XCTest
@testable import fin

/// Covers the iCloud Drive log mirror's pure parts — redaction of the encoded line,
/// slug/path derivation, retention expiry — plus its filesystem behaviors: appending
/// under an injected container root, the retention sweep, the per-file soft cap, the
/// dataless-placeholder guard, and staying a no-op when the ubiquity container is
/// unavailable. No real ubiquity container is touched.
final class AgentLogMirrorTests: XCTestCase {

    private let deviceID8 = "cafef00d"

    private func makeRecord(
        agentName: String = "Test Agent",
        agentID: UUID = UUID(),
        text: String = "hello",
        toolArguments: String? = nil
    ) -> AgentLogRecord {
        AgentLogRecord(
            agentID: agentID,
            agentName: agentName,
            serverName: "box",
            runID: UUID(),
            sequence: 1,
            kind: .assistantMessage,
            text: text,
            toolArguments: toolArguments
        )
    }

    private func makeMirror(
        root: URL, softCapBytes: Int = AgentLogMirror.defaultSoftCapBytes
    ) -> AgentLogMirror {
        AgentLogMirror(containerURL: { root }, deviceID8: deviceID8, softCapBytes: softCapBytes)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-\(UUID().uuidString)")
    }

    private func agentDir(root: URL, record: AgentLogRecord) -> URL {
        root
            .appendingPathComponent("Documents/AgentLogs")
            .appendingPathComponent(
                AgentLogMirror.slug(agentName: record.agentName, agentID: record.agentID)
            )
    }

    // MARK: - Redaction on the encoded line

    func testLineRedactsSecretsInTextAndToolArguments() throws {
        // JSON-quoted keys, the shape tool arguments actually arrive in — the closing
        // quote between key and colon must not defeat the credential mask.
        let record = makeRecord(
            text: "export API_KEY=sk-abc123def456ghi789 and continue",
            toolArguments: #"{"password": "hunter2", "apiKey": "sk-abc123"}"#
        )
        let line = try XCTUnwrap(AgentLogMirror.line(for: record))
        XCTAssertTrue(line.contains("[redacted]"))
        XCTAssertFalse(line.contains("sk-abc123def456ghi789"))
        XCTAssertFalse(line.contains("hunter2"))
        XCTAssertFalse(line.contains("sk-abc123"))
        // The keys survive so the trail stays legible.
        XCTAssertTrue(line.contains("password"))
        XCTAssertTrue(line.contains("apiKey"))
    }

    func testLineKeepsOrdinaryContentAndShape() throws {
        let record = makeRecord(text: "ls -la finished cleanly")
        let line = try XCTUnwrap(AgentLogMirror.line(for: record))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["text"] as? String, "ls -la finished cleanly")
        XCTAssertEqual(object["kind"] as? String, "assistantMessage")
        XCTAssertEqual(object["run_id"] as? String, record.runID.uuidString)
        XCTAssertEqual(object["sequence"] as? Int, 1)
    }

    // MARK: - Slug and path derivation

    func testSlugCollapsesPunctuationAndAppendsIDPrefix() throws {
        let id = try XCTUnwrap(UUID(uuidString: "DEADBEEF-1111-2222-3333-444444444444"))
        XCTAssertEqual(
            AgentLogMirror.slug(agentName: "My Cool Agent!!", agentID: id),
            "my-cool-agent-deadbeef"
        )
        XCTAssertEqual(AgentLogMirror.slug(agentName: "  ", agentID: id), "agent-deadbeef")
    }

    func testFileURLGroupsPerAgentPerUTCDayPerDevice() throws {
        let id = try XCTUnwrap(UUID(uuidString: "DEADBEEF-1111-2222-3333-444444444444"))
        let record = makeRecord(agentName: "Fin", agentID: id)
        let url = AgentLogMirror.fileURL(
            root: URL(fileURLWithPath: "/container"),
            record: record,
            date: Date(timeIntervalSince1970: 0),
            deviceID8: deviceID8
        )
        XCTAssertEqual(
            url.path,
            "/container/Documents/AgentLogs/fin-deadbeef/1970-01-01.cafef00d.jsonl"
        )
    }

    // MARK: - Retention expiry decision

    func testDayFileExpiryDecision() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(AgentLogMirror.isExpiredDayFile("2000-01-01.cafef00d.jsonl", asOf: now))
        // Today's file is never expired.
        XCTAssertFalse(AgentLogMirror.isExpiredDayFile(
            "2023-11-14.cafef00d.jsonl", asOf: now
        ))
        // Unrecognized names never expire — the sweep only deletes what it wrote.
        XCTAssertFalse(AgentLogMirror.isExpiredDayFile("notes.txt", asOf: now))
        XCTAssertFalse(AgentLogMirror.isExpiredDayFile("garbage.jsonl", asOf: now))
        XCTAssertFalse(AgentLogMirror.isExpiredDayFile(
            ".2000-01-01.cafef00d.jsonl.icloud", asOf: now
        ))
    }

    // MARK: - Filesystem behavior

    func testAppendsRedactedLinesUnderInjectedRoot() throws {
        let root = tempRoot()
        let mirror = makeMirror(root: root)

        let record = makeRecord(text: "token=abcdefsecret1234")
        mirror.append(record)
        mirror.append(makeRecord(agentID: record.agentID, text: "second line"))
        mirror.flush()

        let dir = agentDir(root: root, record: record)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".\(deviceID8).jsonl"))
        let contents = try String(
            contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8
        )
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[redacted]"))
        XCTAssertFalse(contents.contains("abcdefsecret1234"))
        XCTAssertTrue(lines[1].contains("second line"))
    }

    func testRetentionSweepDeletesExpiredDayFilesOnFirstAppend() throws {
        let root = tempRoot()
        let record = makeRecord()
        let dir = agentDir(root: root, record: record)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let expired = dir.appendingPathComponent("2000-01-01.\(deviceID8).jsonl")
        let foreign = dir.appendingPathComponent("notes.txt")
        try Data("old\n".utf8).write(to: expired)
        try Data("keep\n".utf8).write(to: foreign)

        let mirror = makeMirror(root: root)
        mirror.append(record)
        mirror.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        // Today's freshly-appended file survives its own sweep.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasSuffix(".\(deviceID8).jsonl") })
    }

    func testSoftCapTruncatesOnceAndStopsAppending() throws {
        let root = tempRoot()
        // A cap smaller than one line: the second append trips it.
        let mirror = makeMirror(root: root, softCapBytes: 10)

        let record = makeRecord(text: "first line before the cap")
        mirror.append(record)
        mirror.append(makeRecord(agentID: record.agentID, text: "over the cap"))
        mirror.append(makeRecord(agentID: record.agentID, text: "dropped entirely"))
        mirror.flush()

        let dir = agentDir(root: root, record: record)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let contents = try String(
            contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8
        )
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("first line before the cap"))
        XCTAssertEqual(String(lines[1]), AgentLogMirror.truncationMarker)
        XCTAssertFalse(contents.contains("dropped entirely"))
    }

    func testDatalessPlaceholderIsNeverClobbered() throws {
        let root = tempRoot()
        let record = makeRecord()
        let dir = agentDir(root: root, record: record)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dayFile = AgentLogMirror.fileURL(
            root: root, record: record, date: Date(), deviceID8: deviceID8
        )
        // Simulate an evicted iCloud file: only the placeholder sibling exists.
        let placeholder = dir.appendingPathComponent(".\(dayFile.lastPathComponent).icloud")
        try Data().write(to: placeholder)

        let mirror = makeMirror(root: root)
        mirror.append(record)
        mirror.flush()

        // The line is dropped (fail-safe) rather than starting a fresh file that would
        // fork away the cloud copy's earlier content.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))
    }

    func testNoOpWhenUbiquityContainerUnavailable() {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let mirror = AgentLogMirror(
            containerURL: {
                counter.value += 1
                return nil
            },
            deviceID8: deviceID8
        )

        mirror.append(makeRecord())
        mirror.append(makeRecord())
        mirror.flush()

        // Resolved once, cached as "off", and not re-asked until the retry window
        // (minutes, not this test's lifetime) elapses.
        XCTAssertEqual(counter.value, 1)
    }
}
