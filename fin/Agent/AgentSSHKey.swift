import Foundation
import Crypto
import Citadel

/// Fin's own SSH identity: a dedicated ed25519 key that belongs to the AGENT,
/// generated in-app so any user can give their Fin access to a computer without
/// ever touching ssh-keygen.
///
/// How the pieces travel, exhaustively:
///   - The METADATA is a `KeyMetadata` row flagged `agentOwned`, so it syncs
///     through CloudKit like every imported key and shows up in every server's
///     key picker — point-to-point use needs nothing beyond picking it.
///   - The PRIVATE KEY lives in the Keychain via `KeychainStore`, whose items
///     are synchronizable (`kSecAttrSynchronizable`), so every device signed
///     into the same iCloud account holds it.
///   - The PUBLIC KEY is never stored anywhere: it is derived on demand from
///     the private key, so there is no second artifact to keep consistent.
///   - For cloud workers, "Provision to Cloud Workers" PUTs the private key
///     into the control plane's write-only secret store (service
///     `fin-agent-ssh-key`, scope `shared`); the worker bootstrap installs it
///     at `workerKeyPath` before the daemon starts. The app can never read it
///     back — `ServiceCredentialsClient`'s doctrine covers that path.
///
/// Encoding reuses Citadel end to end: `makeSSHRepresentation` writes the same
/// OpenSSH private-key format that `Curve25519.Signing.PrivateKey(sshEd25519:)`
/// parses — the app's own import path and the daemon's key loading both go
/// through that parser, so a generated key is valid everywhere by construction.
/// Only the public authorized_keys line is encoded here (two length-prefixed
/// wire strings, base64ed), because Citadel has no encoder for it.
enum AgentSSHKey {
    /// The name the `KeyMetadata` row carries — what server key pickers show.
    static let keyName = "Fin's Key"

    /// The key's comment, kept short and distinctive on purpose: it is the last
    /// field of the authorized_keys line, so it is what the user (or a revoke
    /// instruction) greps for on the target computer.
    static let comment = "fins-key"

    /// The write-only secret-store service name the provisioning PUT uses.
    /// The worker bootstrap fetches `fin/service-creds/shared/<this>`.
    static let secretService = "fin-agent-ssh-key"

    /// Where the worker bootstrap installs the provisioned private key (0600,
    /// owned by fin-agent) — a daemon config's `server.privateKeyPath` can
    /// point here.
    static let workerKeyPath = "/home/fin-agent/.ssh/fin_agent_ed25519"

    /// A freshly generated key pair, both halves in OpenSSH text form. The
    /// caller owns persistence: private text to `KeychainStore`, metadata to
    /// SwiftData; the public line is derivable again at any time.
    static func generate() -> (privateKey: String, publicKeyLine: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            privateKey: wrappedOpenSSHPrivateKey(key.makeSSHRepresentation(comment: comment)),
            publicKeyLine: openSSHPublicKeyLine(
                rawPublicKey: key.publicKey.rawRepresentation, comment: comment
            )
        )
    }

    /// Re-derives the authorized_keys line from the stored private key — the
    /// path every synced device takes, since only the private key travels.
    static func publicKeyLine(fromPrivateKeyText text: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: nil)
        return openSSHPublicKeyLine(rawPublicKey: key.publicKey.rawRepresentation, comment: comment)
    }

    /// One line, standard OpenSSH authorized_keys format:
    /// `ssh-ed25519 <base64 wire blob> <comment>`, where the blob is the SSH
    /// wire encoding — length-prefixed "ssh-ed25519", then the length-prefixed
    /// 32-byte raw public key.
    static func openSSHPublicKeyLine(rawPublicKey: Data, comment: String) -> String {
        var blob = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &blob)
        appendSSHString(rawPublicKey, to: &blob)
        let base64 = blob.base64EncodedString()
        return comment.isEmpty ? "ssh-ed25519 \(base64)" : "ssh-ed25519 \(base64) \(comment)"
    }

    /// The one-line grant command shown next to the Copy button. `mkdir -p`
    /// keeps it honest on an account that has never used SSH (a bare append
    /// would fail there); 0755 on a fresh `~/.ssh` passes sshd's StrictModes,
    /// which rejects only group/world-WRITABLE paths.
    static func installCommand(publicKeyLine: String) -> String {
        "mkdir -p ~/.ssh && echo '\(publicKeyLine)' >> ~/.ssh/authorized_keys"
    }

    // MARK: - Encoding helpers

    /// Citadel's `makeSSHRepresentation` emits the base64 body as one long line.
    /// Its own parser strips newlines so that round-trips fine, but `ssh-keygen`
    /// output wraps at 70 columns and staying byte-compatible with the familiar
    /// shape costs nothing — so the body is re-wrapped here.
    static func wrappedOpenSSHPrivateKey(_ text: String) -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        let base64 = text
            .split(separator: "\n")
            .filter { $0 != Substring(begin) && $0 != Substring(end) }
            .joined()
        var lines = [begin]
        var remainder = Substring(base64)
        while !remainder.isEmpty {
            let line = remainder.prefix(70)
            lines.append(String(line))
            remainder = remainder.dropFirst(line.count)
        }
        lines.append(end)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendSSHString(_ data: Data, to blob: inout Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(data)
    }
}
