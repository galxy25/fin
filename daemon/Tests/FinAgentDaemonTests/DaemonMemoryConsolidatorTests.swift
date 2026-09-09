import XCTest
@testable import FinAgentDaemon
@testable import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `DaemonMemoryConsolidator` — the daemon-side counterpart to
/// `AgentRuntime.consolidateMemoriesIfDue()`: periodically folds episodic `/memory`
/// entries into the shared cumulative profile and keeps a local cache for
/// `Daemon.composedSystemPrompt` to inject. Drives `run(refreshCache:attemptConsolidation:)`
/// directly (the internal seam `tickIfDue` wraps in a fire-and-forget `Task`), with an
/// injected `completion` closure so no test ever reaches a real model endpoint.
@MainActor
final class DaemonMemoryConsolidatorTests: XCTestCase {
    private var cacheFileURL: URL!

    override func setUp() {
        super.setUp()
        cacheFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fin-consolidator-test-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheFileURL)
        super.tearDown()
    }

    private func makeConsolidator(
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> (consolidator: DaemonMemoryConsolidator, auditLines: () -> [String]) {
        var lines: [String] = []
        let memory = DaemonMemoryClient(
            endpointURL: "https://cp.example",
            token: "cp-token",
            agentName: "Nimbus",
            agentID: nil,
            originDeviceID8: "abcd1234",
            audit: { lines.append($0) },
            transport: transport
        )
        let consolidator = DaemonMemoryConsolidator(
            memory: memory,
            cacheFileURL: cacheFileURL,
            holder: "abcd1234",
            endpointURL: "https://model.example",
            modelIdentifier: "m",
            apiKey: nil,
            temperature: 0.2,
            maxOutputTokens: 640,
            audit: { lines.append($0) }
        )
        return (consolidator, { lines })
    }

    private func ok(_ body: String, for request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func profileBody(content: String, updatedAt: String?) -> String {
        let updated = updatedAt.map { "\"\($0)\"" } ?? "null"
        return #"{"content":"\#(content)","updatedAt":\#(updated)}"#
    }

    // MARK: - acceptableProfile (pure)

    func testAcceptableProfileRejectsShortText() {
        XCTAssertFalse(DaemonMemoryConsolidator.acceptableProfile("too short", replacing: ""))
    }

    func testAcceptableProfileRejectsThePlaceholderEcho() {
        let echoed = "(none) is what the current profile said, so nothing changed here at all"
        XCTAssertFalse(DaemonMemoryConsolidator.acceptableProfile(echoed, replacing: ""))
    }

    func testAcceptableProfileRejectsADrasticShrink() {
        let existing = String(repeating: "a fact about the user. ", count: 20)
        let shrunk = "just a few words"
        XCTAssertFalse(DaemonMemoryConsolidator.acceptableProfile(shrunk, replacing: existing))
    }

    func testAcceptableProfileAcceptsAReasonableUpdate() {
        let existing = "Levi is shipping Fin."
        let updated = "Levi is shipping Fin, a terminal agent with voice and cloud hosting support."
        XCTAssertTrue(DaemonMemoryConsolidator.acceptableProfile(updated, replacing: existing))
    }

    // MARK: - run: cache refresh

    func testRunWritesTheCacheFileWhenRefreshCacheIsTrue() async throws {
        let (consolidator, _) = makeConsolidator { request in
            self.ok(self.profileBody(content: "likes concise replies", updatedAt: "2026-09-08T00:00:00Z"), for: request)
        }
        await consolidator.run(refreshCache: true, attemptConsolidation: false)
        let written = try String(contentsOf: cacheFileURL, encoding: .utf8)
        XCTAssertEqual(written, "likes concise replies")
    }

    func testRunDoesNotWriteCacheFileWhenRefreshCacheIsFalseAndConsolidationSkips() async {
        let (consolidator, _) = makeConsolidator { request in
            // Recent updatedAt: the 24h floor isn't due, so nothing past the profile
            // read should happen — including no cache write, since refreshCache is false.
            self.ok(self.profileBody(content: "x", updatedAt: ISO8601DateFormatter().string(from: Date())), for: request)
        }
        await consolidator.run(refreshCache: false, attemptConsolidation: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))
    }

    func testRunSkipsEverythingWhenTheProfileReadFails() async {
        let (consolidator, auditLines) = makeConsolidator { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        await consolidator.run(refreshCache: true, attemptConsolidation: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))
        XCTAssertTrue(auditLines().contains { $0.contains("profile read failed") })
    }

    // MARK: - run: consolidation floor/candidates/lock gating

    func testRunSkipsConsolidationWhenTheFloorIsNotYetDue() async {
        var lockClaimed = false
        let (consolidator, _) = makeConsolidator { request in
            if request.url?.path.hasSuffix("/lock") == true { lockClaimed = true }
            return self.ok(self.profileBody(content: "x", updatedAt: ISO8601DateFormatter().string(from: Date())), for: request)
        }
        await consolidator.run(refreshCache: false, attemptConsolidation: true)
        XCTAssertFalse(lockClaimed, "the 24h floor isn't due yet — must never reach the lock")
    }

    func testRunSkipsConsolidationWhenThereAreNoNewCandidates() async {
        var lockClaimed = false
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        let (consolidator, _) = makeConsolidator { request in
            if request.url?.path.hasSuffix("/lock") == true {
                lockClaimed = true
                return self.ok(#"{"holder":"abcd1234","claimedAt":"2026-09-08T00:00:00Z"}"#, for: request)
            }
            if request.url?.absoluteString.contains("/memory?agent=") == true {
                return self.ok(#"{"entries":[]}"#, for: request)
            }
            return self.ok(self.profileBody(content: "x", updatedAt: old), for: request)
        }
        await consolidator.run(refreshCache: false, attemptConsolidation: true)
        XCTAssertFalse(lockClaimed, "no candidates newer than the profile — must never reach the lock")
    }

    func testRunSkipsConsolidationWhenTheLockIsHeldByAnotherRunner() async throws {
        var completionCalled = false
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        let (consolidator, auditLines) = makeConsolidator { request in
            if request.url?.path.hasSuffix("/lock") == true {
                return (Data(#"{"error":"locked by other-device"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.absoluteString.contains("/memory?agent=") == true {
                return self.ok(#"{"entries":[{"id":"m-1","title":"t","content":"c","updatedAt":"2026-09-09T00:00:00Z"}]}"#, for: request)
            }
            return self.ok(self.profileBody(content: "x", updatedAt: old), for: request)
        }
        consolidator.completion = { _, _ in completionCalled = true; return "unused" }
        await consolidator.run(refreshCache: false, attemptConsolidation: true)
        XCTAssertFalse(completionCalled, "lost the lock race — must never call the model")
        XCTAssertTrue(auditLines().isEmpty, "losing an uncontested-in-principle race isn't a failure worth auditing")
    }

    // MARK: - run: full happy path

    func testRunClaimsCompactsWritesAndReleasesOnTheHappyPath() async throws {
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        var methodsByPath: [String: [String]] = [:]
        var writtenProfileContent: String?
        var completionInput: String?

        let (consolidator, auditLines) = makeConsolidator { request in
            let path = request.url?.path ?? ""
            methodsByPath[path, default: []].append(request.httpMethod ?? "")
            if path.hasSuffix("/lock") {
                if request.httpMethod == "DELETE" {
                    return self.ok(#"{"released":true}"#, for: request)
                }
                return self.ok(#"{"holder":"abcd1234","claimedAt":"2026-09-08T00:00:00Z"}"#, for: request)
            }
            if path.hasSuffix("/profile"), request.httpMethod == "PUT" {
                let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                writtenProfileContent = object?["content"] as? String
                return self.ok(#"{"content":"ok","updatedAt":"2026-09-09T00:00:00Z"}"#, for: request)
            }
            if request.url?.absoluteString.contains("/memory?agent=") == true {
                return self.ok(#"{"entries":[{"id":"m-1","title":"Deploy target","content":"prod-east","updatedAt":"2026-09-09T00:00:00Z"}]}"#, for: request)
            }
            return self.ok(self.profileBody(content: "existing profile text", updatedAt: old), for: request)
        }
        consolidator.completion = { instruction, input in
            completionInput = input
            XCTAssertTrue(instruction.contains("Merge into a concise user profile"))
            return "Levi is working on Fin; prefers direct, concise answers and end-to-end verification."
        }

        await consolidator.run(refreshCache: false, attemptConsolidation: true)

        XCTAssertEqual(methodsByPath["/memory/profile/lock"], ["PUT", "DELETE"], "claim then release, in order")
        XCTAssertEqual(writtenProfileContent, "Levi is working on Fin; prefers direct, concise answers and end-to-end verification.")
        XCTAssertTrue(completionInput?.contains("Deploy target") ?? false, "the candidate's title/content must reach the prompt")
        XCTAssertTrue(completionInput?.contains("existing profile text") ?? false, "the current profile must be re-read under the lock and included")
        XCTAssertTrue(auditLines().contains { $0.contains("merged 1 conversation") })
    }

    func testRunReleasesTheLockEvenWhenTheModelReturnsUnusableText() async throws {
        let old = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -25 * 60 * 60))
        var lockMethods: [String] = []
        let (consolidator, auditLines) = makeConsolidator { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/lock") {
                lockMethods.append(request.httpMethod ?? "")
                if request.httpMethod == "DELETE" { return self.ok(#"{"released":true}"#, for: request) }
                return self.ok(#"{"holder":"abcd1234","claimedAt":"2026-09-08T00:00:00Z"}"#, for: request)
            }
            if request.url?.absoluteString.contains("/memory?agent=") == true {
                return self.ok(#"{"entries":[{"id":"m-1","title":"t","content":"c","updatedAt":"2026-09-09T00:00:00Z"}]}"#, for: request)
            }
            return self.ok(self.profileBody(content: "x", updatedAt: old), for: request)
        }
        consolidator.completion = { _, _ in "too short" }

        await consolidator.run(refreshCache: false, attemptConsolidation: true)

        XCTAssertEqual(lockMethods, ["PUT", "DELETE"], "an unusable reply must still release the lock")
        XCTAssertTrue(auditLines().contains { $0.contains("skipped: model returned unusable text") })
    }
}
