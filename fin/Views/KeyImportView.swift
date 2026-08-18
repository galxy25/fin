import SwiftUI
import SwiftData
import Crypto
import Citadel

struct KeyImportView: View {
    var onImported: (KeyMetadata) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var passphrase = ""
    @State private var pemString: String?
    @State private var detectedType: SSHKeyType?
    @State private var errorMessage: String?
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key File") {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label(pemString == nil ? "Choose from Files / iCloud" : "Key File Loaded", systemImage: "key")
                    }
                    if let detectedType {
                        Label("Detected \(detectedType == .ed25519 ? "ed25519" : "RSA") key", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if pemString != nil {
                    Section("Passphrase") {
                        SecureField("Leave blank if none", text: $passphrase)
                        Button("Retry with Passphrase") { attemptParse() }
                    }
                    Section("Name") {
                        TextField("Key name", text: $name)
                            .autocapitalizationNeverIfAvailable()
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(detectedType == nil || name.isEmpty)
                }
            }
        }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item]) { result in
            handlePickedFile(result)
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        errorMessage = nil
        detectedType = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                errorMessage = "Couldn't read that file as text."
                return
            }
            pemString = text
            if name.isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
            attemptParse()
        }
    }

    private func attemptParse() {
        guard let pemString else { return }
        let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)

        if (try? Curve25519.Signing.PrivateKey(sshEd25519: pemString, decryptionKey: decryptionKey)) != nil {
            detectedType = .ed25519
            errorMessage = nil
            return
        }
        if (try? Insecure.RSA.PrivateKey(sshRsa: pemString, decryptionKey: decryptionKey)) != nil {
            detectedType = .rsa
            errorMessage = nil
            return
        }
        detectedType = nil
        errorMessage = "Couldn't read this key. Only OpenSSH-format ed25519/RSA keys are supported \u{2014} check the passphrase, or the key format."
    }

    private func save() {
        guard let pemString, let detectedType else { return }
        let metadata = KeyMetadata(name: name, keyType: detectedType)
        do {
            try KeychainStore.savePrivateKey(Data(pemString.utf8), for: metadata.id)
            if !passphrase.isEmpty {
                try KeychainStore.savePassphrase(Data(passphrase.utf8), for: metadata.id)
            }
        } catch {
            errorMessage = "Couldn't save key to Keychain: \(error.localizedDescription)"
            return
        }
        modelContext.insert(metadata)
        onImported(metadata)
        dismiss()
    }
}
