import XCTest
import SwiftUI
@testable import fin

/// Covers the write-only service-credential client: the exact PUT body the
/// control plane's contract specifies, the metadata decode, the status table, and
/// — the load-bearing one — a reflective assertion that no decoded type here can
/// carry a credential value.
///
/// No network anywhere: every call under test is a pure function over
/// `(status, body)`, which is why the client splits them out that way.
final class ServiceCredentialsTests: XCTestCase {

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Request body

    func testPutBodyCarriesContractFields() throws {
        let body = ServiceCredentialsClient.putBody(
            agentScope: "Nimbus",
            kind: .appPassword,
            value: "abcd efgh ijkl mnop",
            username: "levi@example.com",
            note: "Gmail app password"
        )
        let object = try decodeBody(body)
        XCTAssertEqual(object["agentScope"] as? String, "Nimbus")
        XCTAssertEqual(object["kind"] as? String, "app-password")
        XCTAssertEqual(object["value"] as? String, "abcd efgh ijkl mnop")
        XCTAssertEqual(object["username"] as? String, "levi@example.com")
        XCTAssertEqual(object["note"] as? String, "Gmail app password")
        XCTAssertEqual(Set(object.keys), ["agentScope", "kind", "value", "username", "note"])
    }

    /// The Lambda rejects an empty username with a 400; the contract's "no
    /// username" is an ABSENT key, not an empty one. Same for the note.
    func testPutBodyOmitsBlankOptionalFields() throws {
        let object = try decodeBody(ServiceCredentialsClient.putBody(
            agentScope: "shared", kind: .password, value: "v", username: "   ", note: ""
        ))
        XCTAssertEqual(Set(object.keys), ["agentScope", "kind", "value"])
        XCTAssertNil(object["username"])
        XCTAssertNil(object["note"])
    }

    func testPutBodyTrimsOptionalFieldsButNotTheValue() throws {
        let object = try decodeBody(ServiceCredentialsClient.putBody(
            agentScope: "shared", kind: .apiKey, value: "  spaces matter  ",
            username: "  levi  ", note: "  note  "
        ))
        XCTAssertEqual(object["username"] as? String, "levi")
        XCTAssertEqual(object["note"] as? String, "note")
        // A credential may legitimately contain leading/trailing whitespace;
        // trimming it would silently store a value that doesn't authenticate.
        XCTAssertEqual(object["value"] as? String, "  spaces matter  ")
    }

    func testSecretKindRawValuesMatchTheContract() {
        XCTAssertEqual(
            ServiceCredentialsClient.SecretKind.allCases.map(\.rawValue),
            ["app-password", "oauth", "api-key", "password"]
        )
    }

    func testServiceNameValidationMatchesTheContractRegex() {
        for good in ["gmail", "app-store-connect", "a", "a1-2", String(repeating: "a", count: 40)] {
            XCTAssertTrue(ServiceCredentialsClient.isValidServiceName(good), good)
        }
        for bad in ["", "Gmail", "-leading", "under_score", "sp ace",
                    String(repeating: "a", count: 41), "trailing\n"] {
            XCTAssertFalse(ServiceCredentialsClient.isValidServiceName(bad), bad)
        }
    }

    // MARK: - Response decode

    /// Byte-for-byte a real `GET /secrets` body (captured from the live control
    /// plane), including the null `lastAccessed` and the pending-deletion row.
    func testListDecodesLiveMetadataShape() {
        let json = """
        {"generatedAt": "2026-09-05T20:30:22Z", "secrets": [
          {"service": "test-svc", "agentScope": "shared", "kind": "password",
           "label": "live smoke test", "lastUpdated": "2026-09-05T20:15:00Z",
           "lastAccessed": "2026-09-05", "deletionScheduled": "2026-09-05T20:15:00Z"},
          {"service": "gmail", "agentScope": "nimbus", "kind": "app-password",
           "label": "", "lastUpdated": "2026-09-05T20:29:35Z",
           "lastAccessed": null}
        ]}
        """.data(using: .utf8)
        guard case .success(let rows) = ServiceCredentialsClient
            .listOutcome(status: 200, body: json) else {
            return XCTFail("expected the live list body to decode")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].deletionScheduled, "2026-09-05T20:15:00Z")
        XCTAssertNotNil(rows[0].deletionDate)
        XCTAssertEqual(rows[1].service, "gmail")
        XCTAssertEqual(rows[1].agentScope, "nimbus")
        // Today's Lambda coerces a missing Description to "" (`entry.get
        // ("Description") or ""`), but the client declares `label` Optional so
        // a null or absent field can never fail the whole list's decode.
        XCTAssertEqual(rows[1].label, "")
        XCTAssertNil(rows[1].lastAccessed)
        XCTAssertNil(rows[1].deletionScheduled)
        XCTAssertEqual(rows[1].id, "nimbus/gmail")
    }

    func testListTreatsAnAbsentSecretsArrayAsEmpty() {
        guard case .success(let rows) = ServiceCredentialsClient
            .listOutcome(status: 200, body: Data("{\"generatedAt\":\"x\"}".utf8)) else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    /// 201 create and 200 update are both successes — the live API answers 201
    /// the first time and 200 on every re-PUT, and the UI treats them alike.
    func testPutOutcomeAcceptsBoth201CreateAnd200Update() {
        let json = Data("""
        {"service": "gmail", "agentScope": "shared", "kind": "app-password",
         "lastUpdated": "2026-09-05T20:30:08Z"}
        """.utf8)
        for status in [200, 201] {
            guard case .success(let ack) = ServiceCredentialsClient
                .putOutcome(status: status, body: json) else {
                return XCTFail("expected \(status) to be a success")
            }
            XCTAssertEqual(ack.service, "gmail")
            XCTAssertEqual(ack.kind, "app-password")
        }
    }

    func testDeleteDecodesTheRecoveryWindow() {
        let json = Data("""
        {"service": "gmail", "agentScope": "shared",
         "deletionDate": "2026-09-12T20:30:21Z"}
        """.utf8)
        guard case .success(let ack) = ServiceCredentialsClient
            .deleteOutcome(status: 200, body: json) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(ack.deletionDate, "2026-09-12T20:30:21Z")
    }

    // MARK: - Status table

    func testStatusTableMapsTheLiveFailureBodies() {
        // 400s the live API really returns.
        let missingValue = Data("{\"error\": \"value is required\"}".utf8)
        XCTAssertEqual(
            ServiceCredentialsClient.putOutcome(status: 400, body: missingValue),
            .failure(.server("value is required"))
        )
        XCTAssertEqual(
            ServiceCredentialsClient.listOutcome(status: 401, body: nil),
            .failure(.unauthorized)
        )
        XCTAssertEqual(
            ServiceCredentialsClient.deleteOutcome(
                status: 404,
                body: Data("{\"error\": \"no secret for service x in scope shared\"}".utf8)
            ),
            .failure(.server("no secret for service x in scope shared"))
        )
        // Transport failure: no status at all.
        XCTAssertEqual(
            ServiceCredentialsClient.listOutcome(status: nil, body: nil),
            .failure(.transport)
        )
        // 2xx with a body that isn't the documented JSON degrades rather than
        // surfacing raw bytes.
        XCTAssertEqual(
            ServiceCredentialsClient.putOutcome(status: 200, body: Data("<html>".utf8)),
            .failure(.malformedResponse)
        )
        // A non-2xx with no usable error field falls back to the bare status.
        XCTAssertEqual(
            ServiceCredentialsClient.putOutcome(status: 503, body: Data("{}".utf8)),
            .failure(.http(503))
        )
    }

    func testUserMessagesNeverCarryTheEndpointOrToken() {
        // Capture and RESTORE the real config — the suite runs inside the app's
        // process, so resetting to "" here would wipe a configured control plane
        // on the developer's own machine.
        let originalEndpoint = CloudControlPlaneConfig.endpointURL
        let originalToken = CloudControlPlaneConfig.token
        CloudControlPlaneConfig.setEndpointURL("https://secret-host.example.com")
        CloudControlPlaneConfig.setToken("TOKEN-SHOULD-NEVER-APPEAR")
        defer {
            CloudControlPlaneConfig.setEndpointURL(originalEndpoint)
            CloudControlPlaneConfig.setToken(originalToken)
        }
        let failures: [ServiceCredentialsClient.Failure] = [
            .notConfigured, .transport, .unauthorized, .malformedResponse,
            .http(500), .server("kind must be one of: app-password, oauth"),
        ]
        for failure in failures {
            let message = failure.userMessage
            XCTAssertFalse(message.contains("TOKEN-SHOULD-NEVER-APPEAR"), message)
            XCTAssertFalse(message.contains("secret-host.example.com"), message)
            XCTAssertFalse(message.isEmpty)
        }
        // And a hostile server body echoing the token back is scrubbed on the
        // way in, not merely absent by luck.
        let echoed = Data("""
        {"error": "bad token TOKEN-SHOULD-NEVER-APPEAR"}
        """.utf8)
        guard case .failure(let failure) = ServiceCredentialsClient
            .listOutcome(status: 400, body: echoed) else {
            return XCTFail("expected a failure")
        }
        XCTAssertFalse(failure.userMessage.contains("TOKEN-SHOULD-NEVER-APPEAR"))
        XCTAssertTrue(failure.userMessage.contains("[token]"))
    }

    // MARK: - The write-only invariant

    /// The invariant this whole feature rests on: nothing the client can DECODE
    /// has a place to put a credential. Asserted by reflection so that adding a
    /// `value` field to any response type fails here rather than in review.
    func testNoDecodedTypeCanCarryACredentialValue() {
        let banned = ["value", "secret", "password", "username", "token", "credential"]

        func assertClean(_ mirror: Mirror, _ what: String) {
            for child in mirror.children {
                let name = (child.label ?? "").lowercased()
                for word in banned {
                    XCTAssertFalse(
                        name.contains(word),
                        "\(what) exposes a credential-shaped field '\(name)'"
                    )
                }
            }
        }

        let metadata = ServiceCredentialsClient.Metadata(
            service: "gmail", agentScope: "shared", kind: "app-password",
            label: "l", lastUpdated: nil, lastAccessed: nil, deletionScheduled: nil
        )
        assertClean(Mirror(reflecting: metadata), "Metadata")
        assertClean(
            Mirror(reflecting: ServiceCredentialsClient.PutAck(
                service: "gmail", agentScope: "shared", kind: "k", lastUpdated: nil
            )),
            "PutAck"
        )
        assertClean(
            Mirror(reflecting: ServiceCredentialsClient.DeletionAck(
                service: "gmail", agentScope: "shared", deletionDate: nil
            )),
            "DeletionAck"
        )

        // A server that DID return a value (a regression, or an impostor
        // endpoint) still cannot smuggle it into the app: the extra key is
        // dropped at decode, so there is no path from wire to memory.
        let hostile = Data("""
        {"secrets": [{"service": "gmail", "agentScope": "shared",
          "kind": "app-password", "label": "", "lastUpdated": null,
          "lastAccessed": null, "deletionScheduled": null,
          "value": "LEAKED", "username": "levi@example.com"}]}
        """.utf8)
        guard case .success(let rows) = ServiceCredentialsClient
            .listOutcome(status: 200, body: hostile) else {
            return XCTFail("expected the row to decode without the extra keys")
        }
        assertClean(Mirror(reflecting: rows[0]), "Metadata decoded from a hostile body")
        XCTAssertFalse("\(rows[0])".contains("LEAKED"))
    }

    /// The client's public surface is write-plus-metadata: three calls, none of
    /// which can hand back a value. Pinned as a compile-time shape check —
    /// changing any return type breaks this test's type annotations.
    func testClientSurfaceReturnsOnlyMetadata() {
        let store: (String, String, ServiceCredentialsClient.SecretKind, String, String?, String?)
            async -> Result<ServiceCredentialsClient.PutAck, ServiceCredentialsClient.Failure> = {
                await ServiceCredentialsClient.storeSecret(
                    service: $0, agentScope: $1, kind: $2, value: $3, username: $4, note: $5
                )
            }
        let list: () async -> Result<
            [ServiceCredentialsClient.Metadata], ServiceCredentialsClient.Failure
        > = { await ServiceCredentialsClient.listSecrets() }
        let remove: (String, String) async -> Result<
            ServiceCredentialsClient.DeletionAck, ServiceCredentialsClient.Failure
        > = { await ServiceCredentialsClient.deleteSecret(service: $0, agentScope: $1) }
        XCTAssertNotNil(store)
        XCTAssertNotNil(list)
        XCTAssertNotNil(remove)
    }

    /// Staleness is a metadata-only nudge, so it has to work off `lastUpdated`
    /// alone — the app has nothing else to judge a credential's age by.
    func testStalenessBadgeFiresOnlyPastTheThreshold() {
        func row(daysAgo: Int) -> ServiceCredentialsClient.Metadata {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            return .init(
                service: "gmail", agentScope: "shared", kind: "password", label: "",
                lastUpdated: ISO8601DateFormatter().string(from: date),
                lastAccessed: nil, deletionScheduled: nil
            )
        }
        XCTAssertFalse(row(daysAgo: 1).isStale())
        XCTAssertFalse(row(daysAgo: 179).isStale())
        XCTAssertTrue(row(daysAgo: 181).isStale())
        // An unparseable or absent stamp must not badge every row stale.
        XCTAssertFalse(ServiceCredentialsClient.Metadata(
            service: "g", agentScope: "shared", kind: "password", label: "",
            lastUpdated: nil, lastAccessed: nil, deletionScheduled: nil
        ).isStale())
    }
}
