import XCTest
import Crypto
import Citadel
@testable import fin

/// Covers Fin's Key end to end minus the network and the Keychain: the OpenSSH
/// encode/decode round-trip for a generated key, the authorized_keys line's
/// wire format (decoded by hand, not trusted to the encoder that wrote it),
/// the `agentOwned` schema default, and the exact provisioning PUT body.
/// Keychain sync behavior lives in `KeychainStoreTests`; the write-only vault
/// contract in `ServiceCredentialsTests`.
final class AgentSSHKeyTests: XCTestCase {

    // MARK: - OpenSSH round-trip

    /// The generated private key text must parse back through the SAME parser
    /// the app's key import and the daemon's key loading use — Citadel's — and
    /// yield the same public key the generator reported.
    func testGeneratedPrivateKeyRoundTrips() throws {
        let generated = AgentSSHKey.generate()
        let reparsed = try Curve25519.Signing.PrivateKey(
            sshEd25519: generated.privateKey, decryptionKey: nil
        )
        XCTAssertEqual(
            AgentSSHKey.openSSHPublicKeyLine(
                rawPublicKey: reparsed.publicKey.rawRepresentation,
                comment: AgentSSHKey.comment
            ),
            generated.publicKeyLine
        )
    }

    /// The synced-device path: every other device holds only the private key
    /// (via iCloud Keychain) and must re-derive the identical public line.
    func testPublicKeyLineDerivesFromPrivateKeyText() throws {
        let generated = AgentSSHKey.generate()
        XCTAssertEqual(
            try AgentSSHKey.publicKeyLine(fromPrivateKeyText: generated.privateKey),
            generated.publicKeyLine
        )
    }

    func testPrivateKeyIsArmoredAndWrappedLikeSSHKeygen() {
        let generated = AgentSSHKey.generate()
        let lines = generated.privateKey.split(separator: "\n")
        XCTAssertEqual(lines.first, "-----BEGIN OPENSSH PRIVATE KEY-----")
        XCTAssertEqual(lines.last, "-----END OPENSSH PRIVATE KEY-----")
        XCTAssertTrue(generated.privateKey.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        for line in lines.dropFirst().dropLast() {
            XCTAssertLessThanOrEqual(line.count, 70, "base64 body should wrap at 70 columns")
        }
    }

    /// Decodes the authorized_keys line by hand — prefix, base64 blob as two
    /// length-prefixed SSH wire strings, comment — so a bug in the encoder
    /// can't hide behind itself.
    func testPublicKeyLineIsAValidAuthorizedKeysEntry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = AgentSSHKey.openSSHPublicKeyLine(
            rawPublicKey: key.publicKey.rawRepresentation, comment: "fins-key"
        )
        let parts = line.split(separator: " ")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "ssh-ed25519")
        XCTAssertEqual(parts[2], "fins-key")

        var blob = try XCTUnwrap(Data(base64Encoded: String(parts[1])))
        func readWireString() throws -> Data {
            let lengthBytes = blob.prefix(4)
            XCTAssertEqual(lengthBytes.count, 4)
            let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
            blob = blob.dropFirst(4)
            let value = blob.prefix(length)
            XCTAssertEqual(value.count, length)
            blob = blob.dropFirst(length)
            return Data(value)
        }
        XCTAssertEqual(try readWireString(), Data("ssh-ed25519".utf8))
        let raw = try readWireString()
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(raw, key.publicKey.rawRepresentation)
        XCTAssertTrue(blob.isEmpty, "no trailing bytes after the two wire strings")
    }

    func testInstallCommandAppendsTheExactLine() {
        let command = AgentSSHKey.installCommand(publicKeyLine: "ssh-ed25519 AAAA fins-key")
        XCTAssertEqual(
            command,
            "mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA fins-key' >> ~/.ssh/authorized_keys"
        )
    }

    // MARK: - Metadata schema

    /// The CloudKit-additive default: every key imported by an earlier build —
    /// and every key imported through KeyImportView today — is user-owned.
    func testKeyMetadataDefaultsToUserOwned() {
        XCTAssertFalse(KeyMetadata(name: "imported", keyType: .ed25519).agentOwned)
    }

    func testAgentOwnedFlagSticks() {
        let metadata = KeyMetadata(name: AgentSSHKey.keyName, keyType: .ed25519, agentOwned: true)
        XCTAssertTrue(metadata.agentOwned)
        XCTAssertEqual(metadata.keyType, .ed25519)
    }

    // MARK: - Provisioning PUT body

    /// Contract-exact: `{"agentScope": "shared", "kind": "api-key",
    /// "privateKey", "publicKey", "note"}` and nothing else — the shape the
    /// Lambda's SECRET_FIELDS accepts and the worker bootstrap reads.
    func testAgentSSHKeyBodyShape() throws {
        let data = try XCTUnwrap(ServiceCredentialsClient.agentSSHKeyBody(
            privateKey: "PRIVATE-PEM", publicKey: "ssh-ed25519 AAAA fins-key"
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys), ["agentScope", "kind", "privateKey", "publicKey", "note"]
        )
        XCTAssertEqual(object["agentScope"] as? String, "shared")
        XCTAssertEqual(object["kind"] as? String, "api-key")
        XCTAssertEqual(object["privateKey"] as? String, "PRIVATE-PEM")
        XCTAssertEqual(object["publicKey"] as? String, "ssh-ed25519 AAAA fins-key")
        let note = try XCTUnwrap(object["note"] as? String)
        XCTAssertFalse(note.isEmpty)
        XCTAssertLessThanOrEqual(note.count, 200, "the Lambda caps note at 200 chars")
    }

    /// The reserved service name must pass the same validation every other
    /// service name does — the Lambda applies it before anything else.
    func testSecretServiceNameIsValid() {
        XCTAssertTrue(ServiceCredentialsClient.isValidServiceName(AgentSSHKey.secretService))
        XCTAssertEqual(AgentSSHKey.secretService, "fin-agent-ssh-key")
    }
}
