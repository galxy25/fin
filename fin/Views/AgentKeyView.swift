import SwiftUI
import SwiftData

/// "Fin's Key" — the agent's own SSH identity, generated here so any user can
/// give their Fin access to a computer as a product feature, not an operator
/// ritual.
///
/// One key per Fin, everywhere: the metadata row (`agentOwned`) syncs through
/// CloudKit and the private key syncs through iCloud Keychain, so this screen
/// shows the same key on every device — and the key appears in every server's
/// key picker, which is all point-to-point use needs. The public line is never
/// stored; it is re-derived from the private key each time this screen loads.
///
/// Private-key handling: the key text is read out of the Keychain in exactly
/// two places — `refreshPublicKey()` (derive the public line, discard) and
/// `provision()` (hand it to `ServiceCredentialsClient`, discard). No `@State`
/// ever holds it, nothing logs it, and the provisioning vault is write-only,
/// so the only thing this screen can show about the cloud copy is `GET
/// /secrets` metadata.
struct AgentKeyView: View {
    @Environment(\.modelContext) private var modelContext
    /// Oldest first: if two devices raced to generate before sync converged,
    /// every device settles on the same (oldest) row.
    @Query(
        filter: #Predicate<KeyMetadata> { $0.agentOwned == true },
        sort: \KeyMetadata.importedAt
    )
    private var agentKeys: [KeyMetadata]

    @State private var publicKeyLine: String?
    @State private var provisionedRow: ServiceCredentialsClient.Metadata?
    @State private var didLoadProvisionState = false
    @State private var isProvisioning = false
    @State private var banner: String?

    private var agentKey: KeyMetadata? { agentKeys.first }

    var body: some View {
        Form {
            keySection
            if publicKeyLine != nil {
                grantSection
                cloudSection
            }
            if let banner {
                Section {
                    Text(banner).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Fin's Key")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: agentKey?.id) {
            refreshPublicKey()
            await reloadProvisionState()
        }
    }

    // MARK: - Key

    @ViewBuilder
    private var keySection: some View {
        if let key = agentKey {
            Section {
                if let publicKeyLine {
                    Text(publicKeyLine)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Public Key") {
                        copyToPasteboard(publicKeyLine)
                        banner = "Public key copied."
                    }
                } else {
                    Text("This device hasn't received Fin's private key from "
                        + "iCloud Keychain yet. It arrives on its own once "
                        + "iCloud Keychain syncs — check that iCloud Keychain "
                        + "is turned on for this device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Public Key")
            } footer: {
                Text("Created \(key.importedAt.formatted(date: .abbreviated, time: .omitted)). "
                    + "The private half stays in your iCloud Keychain, shared "
                    + "only among your own devices.")
            }
        } else {
            Section {
                Button("Generate Fin's Key") { generateKey() }
            } footer: {
                Text("Creates a dedicated ed25519 SSH key that belongs to Fin. "
                    + "It syncs privately to all your devices through iCloud "
                    + "Keychain, and you give Fin access to a computer by "
                    + "adding the public half there. The private half never "
                    + "leaves your devices unless you provision it to cloud "
                    + "workers.")
            }
        }
    }

    // MARK: - Grant access

    private var grantSection: some View {
        Section {
            if let publicKeyLine {
                let command = AgentSSHKey.installCommand(publicKeyLine: publicKeyLine)
                Text(command)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy Install Command") {
                    copyToPasteboard(command)
                    banner = "Install command copied."
                }
            }
        } header: {
            Text("Give Fin Access to a Computer")
        } footer: {
            Text("Run that command on the computer, logged in as the account "
                + "Fin should use. Then add the computer as a server in this "
                + "app and pick \u{201c}\(AgentSSHKey.keyName)\u{201d} in its "
                + "key picker. To revoke access later, delete the line ending "
                + "in \u{201c}\(AgentSSHKey.comment)\u{201d} from "
                + "~/.ssh/authorized_keys on that computer.")
        }
    }

    // MARK: - Cloud workers

    private var cloudSection: some View {
        Section {
            Button {
                Task { await provision() }
            } label: {
                HStack {
                    Text("Provision to Cloud Workers")
                    if isProvisioning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!CloudControlPlaneConfig.isConfigured || isProvisioning)
            LabeledContent("Status", value: provisionStatusLine)
        } header: {
            Text("Cloud Workers")
        } footer: {
            Text("Sends the private key to the write-only credential vault in "
                + "your own AWS Secrets Manager (as "
                + "\u{201c}\(AgentSSHKey.secretService)\u{201d}, shared scope). "
                + "This app can never read it back — only cloud workers can, "
                + "at boot, where it is installed at \(AgentSSHKey.workerKeyPath) "
                + "before the agent starts, so a worker can reach the same "
                + "computers you granted above. Provision again any time to "
                + "replace it; to pull it back out of the cloud, delete "
                + "\u{201c}\(AgentSSHKey.secretService)\u{201d} in Connected "
                + "Services.")
        }
    }

    private var provisionStatusLine: String {
        guard didLoadProvisionState else { return "checking\u{2026}" }
        guard let row = provisionedRow else { return "not provisioned" }
        let provisioned = row.lastUpdatedDate
            .map { "provisioned \($0.formatted(date: .abbreviated, time: .omitted))" }
            ?? "provisioned"
        let read = row.lastAccessed.map { "last read by a worker \($0)" }
            ?? "never read by a worker"
        return "\(provisioned) · \(read)"
    }

    // MARK: - Actions

    private func generateKey() {
        let generated = AgentSSHKey.generate()
        let metadata = KeyMetadata(name: AgentSSHKey.keyName, keyType: .ed25519, agentOwned: true)
        do {
            try KeychainStore.savePrivateKey(Data(generated.privateKey.utf8), for: metadata.id)
        } catch {
            banner = "Couldn't save the key to the Keychain: \(error.localizedDescription)"
            return
        }
        modelContext.insert(metadata)
        publicKeyLine = generated.publicKeyLine
    }

    /// Derives the shown public line from the Keychain-held private key. A miss
    /// is not an error: the metadata row can sync ahead of the iCloud Keychain
    /// item, and the honest state for that window is "not here yet".
    private func refreshPublicKey() {
        guard let key = agentKey,
              let data = KeychainStore.loadPrivateKey(for: key.id),
              let text = String(data: data, encoding: .utf8),
              let line = try? AgentSSHKey.publicKeyLine(fromPrivateKeyText: text)
        else {
            publicKeyLine = nil
            return
        }
        publicKeyLine = line
    }

    private func provision() async {
        guard let key = agentKey,
              let data = KeychainStore.loadPrivateKey(for: key.id),
              let privateText = String(data: data, encoding: .utf8),
              let publicLine = publicKeyLine
        else {
            banner = "The private key isn't on this device yet."
            return
        }
        banner = nil
        isProvisioning = true
        let outcome = await ServiceCredentialsClient.storeAgentSSHKey(
            privateKey: privateText, publicKey: publicLine
        )
        isProvisioning = false
        switch outcome {
        case .success:
            banner = "Provisioned — cloud workers launched from now on will "
                + "install Fin's key at boot."
            await reloadProvisionState()
        case .failure(let failure):
            banner = failure.userMessage
        }
    }

    /// Metadata only, by the vault's design: the row for `fin-agent-ssh-key`
    /// carries timestamps and a label, never a value.
    private func reloadProvisionState() async {
        guard CloudControlPlaneConfig.isConfigured else {
            didLoadProvisionState = true
            provisionedRow = nil
            return
        }
        if case .success(let rows) = await ServiceCredentialsClient.listSecrets() {
            provisionedRow = rows.first {
                $0.service == AgentSSHKey.secretService
                    && $0.agentScope == ServiceCredentialsClient.sharedScope
            }
        }
        didLoadProvisionState = true
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
