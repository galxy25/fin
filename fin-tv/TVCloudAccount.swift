// The Apple TV's account: Sign in with Apple → the control plane's session token
// (stored in THIS device's keychain; tvOS has no iCloud Keychain to sync one) →
// the key vault, opened with the vault key CloudKit delivers. See `KeyVault`.
//
// The control-plane endpoint is the one the iPhone/Mac wrote to iCloud Key-Value
// Storage — same slot, read directly — so the TV has nothing to type, ever.
import Foundation
import SwiftData
import SwiftUI
import AuthenticationServices

@MainActor
final class TVCloudAccount: ObservableObject {
    enum Phase: Equatable {
        /// iCloud KVS hasn't delivered the endpoint yet (or no device ever set one).
        case waitingForEndpoint
        case needsSignIn
        case syncing
        /// Signed in and the last vault sync succeeded; `keysInstalled` says how many.
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .waitingForEndpoint
    @Published private(set) var keysInstalled = 0
    @Published private(set) var lastSyncAt: Date?

    static let sessionTokenKey = "fin.cloudcp.session-token"
    private var kvsObserver: NSObjectProtocol?
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        NSUbiquitousKeyValueStore.default.synchronize()
        kvsObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    var endpoint: String {
        NSUbiquitousKeyValueStore.default.string(forKey: KeyVault.endpointURLKey) ?? ""
    }

    var sessionToken: String {
        KeychainStore.loadLocalSecret(forKey: Self.sessionTokenKey) ?? ""
    }

    var isSignedIn: Bool { !sessionToken.isEmpty }

    /// Launch / foreground: recompute the phase and, when signed in, pull the vault.
    func refresh() async {
        guard !endpoint.isEmpty else { phase = .waitingForEndpoint; return }
        guard isSignedIn else { phase = .needsSignIn; return }
        await syncVault()
    }

    func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            phase = .failed(error.localizedDescription)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                phase = .failed("Apple did not return an identity token.")
                return
            }
            phase = .syncing
            Task {
                let outcome = await AppleSignInClient.signIn(identityToken: identityToken, endpoint: endpoint)
                switch outcome {
                case .signedIn(let sessionToken):
                    do {
                        try KeychainStore.saveLocalSecret(sessionToken, forKey: Self.sessionTokenKey)
                    } catch {
                        phase = .failed("Couldn't store the session in the Keychain.")
                        return
                    }
                    await syncVault()
                case .notConfigured:
                    phase = .waitingForEndpoint
                case .failed(let message):
                    phase = .failed(message)
                }
            }
        }
    }

    func signOut() {
        try? KeychainStore.saveLocalSecret("", forKey: Self.sessionTokenKey)
        phase = endpoint.isEmpty ? .waitingForEndpoint : .needsSignIn
    }

    /// Lists the vault and installs every entry this account's vault key opens.
    /// An entry that fails to open is skipped, not fatal: it may have been sealed
    /// by a device whose CloudKit vault-key record lost the mint race (see
    /// `DeviceVaultKeyStore`) — that device re-seals on its next launch.
    func syncVault() async {
        phase = .syncing
        guard let vaultKey = DeviceVaultKeyStore.resolve(context: context, deviceName: "Apple TV") else {
            phase = .failed("Waiting for iCloud to deliver this account's vault key.")
            return
        }
        let client = KeyVaultClient(endpoint: endpoint, token: sessionToken)
        do {
            let entries = try await client.list()
            var installed = 0
            for entry in entries {
                guard let keyID = UUID(uuidString: entry.keyId),
                      let keyType = SSHKeyType(rawValue: entry.keyType),
                      let secret = try? KeyVault.open(entry.ciphertext, keyID: keyID, vaultKey: vaultKey)
                else { continue }
                do {
                    try KeychainStore.savePrivateKey(Data(secret.pem.utf8), for: keyID)
                    if let passphrase = secret.passphrase, !passphrase.isEmpty {
                        try KeychainStore.savePassphrase(Data(passphrase.utf8), for: keyID)
                    }
                } catch { continue }
                // The KeyMetadata row normally arrives via CloudKit on its own; if it
                // hasn't yet, materialize it (same id) so the key is usable now —
                // sync merges on record name rather than duplicating.
                let descriptor = FetchDescriptor<KeyMetadata>(predicate: #Predicate { $0.id == keyID })
                if (try? context.fetch(descriptor).first) == nil {
                    let metadata = KeyMetadata(name: entry.name, keyType: keyType)
                    metadata.id = keyID
                    context.insert(metadata)
                }
                installed += 1
            }
            keysInstalled = installed
            lastSyncAt = Date()
            phase = .ready
        } catch KeyVaultClient.ClientError.http(let status, _) where status == 401 {
            // The session was revoked or expired server-side: back to sign-in,
            // which is one click on the TV.
            try? KeychainStore.saveLocalSecret("", forKey: Self.sessionTokenKey)
            phase = .needsSignIn
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Sign in with Apple + vault status, as a `List` section the server list and
/// the empty state both show. Nothing to configure: the endpoint comes from
/// iCloud and the identity from the Apple ID this TV is already signed into.
struct TVAccountSection: View {
    @EnvironmentObject private var account: TVCloudAccount

    var body: some View {
        Section {
            switch account.phase {
            case .waitingForEndpoint:
                Label("Waiting for iCloud to deliver your Fin cloud settings from your iPhone or Mac.",
                      systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            case .needsSignIn:
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { result in
                    account.handleSignIn(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(maxWidth: 480, minHeight: 60)
                Text("Sign in once and the SSH keys from your other Fin devices arrive here on their own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .syncing:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Fetching your keys…")
                        .foregroundStyle(.secondary)
                }
            case .ready:
                Label(
                    account.keysInstalled == 1 ? "1 key installed from your account."
                        : "\(account.keysInstalled) keys installed from your account.",
                    systemImage: "checkmark.icloud"
                )
                .foregroundStyle(.secondary)
                Button("Refresh keys") { Task { await account.syncVault() } }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await account.refresh() } }
            }
        } header: {
            Text("Fin Account")
        }
    }
}
