import XCTest
@testable import fin

/// The key vault's contract (see `KeyVault`): entries open only with the
/// account's vault key AND under the key id they were sealed for, and the
/// client speaks the three routes with a bearer session token.
final class KeyVaultTests: XCTestCase {
    private let vaultKey = Data((0..<32).map { UInt8($0) })
    private let keyID = UUID(uuidString: "0F0F0F0F-0000-4000-8000-000000000001")!

    func testSealThenOpenRoundTripsPEMAndPassphrase() throws {
        let secret = KeyVault.Secret(pem: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n", passphrase: "hunter2")
        let ciphertext = try KeyVault.seal(secret, keyID: keyID, vaultKey: vaultKey)
        XCTAssertNotNil(Data(base64Encoded: ciphertext), "wire form is base64")
        XCTAssertFalse(ciphertext.contains("OPENSSH"), "the PEM never appears in the clear")
        XCTAssertEqual(try KeyVault.open(ciphertext, keyID: keyID, vaultKey: vaultKey), secret)
    }

    func testWrongVaultKeyOrWrongKeyIDFailsToOpen() throws {
        let ciphertext = try KeyVault.seal(KeyVault.Secret(pem: "pem", passphrase: nil), keyID: keyID, vaultKey: vaultKey)
        var other = vaultKey; other[0] ^= 1
        XCTAssertThrowsError(try KeyVault.open(ciphertext, keyID: keyID, vaultKey: other))
        XCTAssertThrowsError(try KeyVault.open(ciphertext, keyID: UUID(), vaultKey: vaultKey),
                             "an entry copied under another key id must not become that key")
        XCTAssertThrowsError(try KeyVault.open("not base64!", keyID: keyID, vaultKey: vaultKey))
    }

    func testClientSendsBearerTokenAndRouteShapes() async throws {
        var seen: [URLRequest] = []
        var client = KeyVaultClient(endpoint: "https://cp.example.com/", token: "sess-1")
        client.transport = { request in
            seen.append(request)
            let body: Data
            if request.httpMethod == "GET" {
                body = Data(#"{"keys":[{"keyId":"0F0F0F0F-0000-4000-8000-000000000001","name":"laptop","keyType":"ed25519","ciphertext":"QUJD","updatedAt":"2026-09-12T00:00:00Z"}]}"#.utf8)
            } else {
                body = Data("{}".utf8)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let entries = try await client.list()
        try await client.put(keyID: keyID, name: "laptop", keyType: "ed25519", ciphertext: "QUJD")
        try await client.delete(keyID: keyID)

        XCTAssertEqual(entries.map(\.name), ["laptop"])
        XCTAssertEqual(seen.map { $0.url!.absoluteString }, [
            "https://cp.example.com/vault/keys",
            "https://cp.example.com/vault/keys/0F0F0F0F-0000-4000-8000-000000000001",
            "https://cp.example.com/vault/keys/0F0F0F0F-0000-4000-8000-000000000001",
        ])
        XCTAssertEqual(seen.map { $0.httpMethod }, ["GET", "PUT", "DELETE"])
        XCTAssertEqual(Set(seen.map { $0.value(forHTTPHeaderField: "Authorization") }), ["Bearer sess-1"])
        let put = try XCTUnwrap(JSONSerialization.jsonObject(with: seen[1].httpBody!) as? [String: String])
        XCTAssertEqual(put, ["name": "laptop", "keyType": "ed25519", "ciphertext": "QUJD"])
    }

    func testClientSurfacesServerErrorsAndRefusesWithoutConfig() async {
        var client = KeyVaultClient(endpoint: "https://cp.example.com", token: "sess-1")
        client.transport = { request in
            (Data(#"{"error":"unauthorized"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.list(); XCTFail("expected a thrown 401") } catch KeyVaultClient.ClientError.http(let status, let message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "unauthorized")
        } catch { XCTFail("wrong error \(error)") }

        let unconfigured = KeyVaultClient(endpoint: "", token: "")
        do { _ = try await unconfigured.list(); XCTFail("expected notConfigured") } catch KeyVaultClient.ClientError.notConfigured {
        } catch { XCTFail("wrong error \(error)") }
    }

    func testTVReadsTheSameEndpointSlotTheOtherDevicesWrite() {
        XCTAssertEqual(CloudControlPlaneConfig.endpointURLKey, KeyVault.endpointURLKey)
    }
}
