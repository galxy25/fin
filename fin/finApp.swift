import SwiftUI
import SwiftData

@main
struct FinApp: App {
    @StateObject private var sessionManager: SessionManager
    private let modelContainer: ModelContainer

    init() {
        let container: ModelContainer
        do {
            // Server/KeyMetadata sync via the user's private CloudKit database (their
            // iCloud account IS the "profile" — there's no separate in-app sign-in).
            // Clipping/MarkdownDocument stay local-only; CloudKit mirroring requires every
            // synced model's properties to have defaults, which isn't worth imposing on
            // clippings/markdown bookmarks that were never asked to sync.
            let syncedConfig = ModelConfiguration(
                "Synced",
                schema: Schema([Server.self, KeyMetadata.self]),
                cloudKitDatabase: .automatic
            )
            let localConfig = ModelConfiguration(
                "Local",
                schema: Schema([Clipping.self, MarkdownDocument.self]),
                cloudKitDatabase: .none
            )
            container = try ModelContainer(
                for: Schema([Server.self, KeyMetadata.self, Clipping.self, MarkdownDocument.self]),
                configurations: [syncedConfig, localConfig]
            )
        } catch {
            fatalError("Failed to create SwiftData model container: \(error)")
        }
        modelContainer = container

        let manager = SessionManager()
        let context = container.mainContext

        manager.resolveCredentials = { server in
            guard let keyID = server.keyID else { return nil }
            let descriptor = FetchDescriptor<KeyMetadata>(predicate: #Predicate { $0.id == keyID })
            guard let metadata = try? context.fetch(descriptor).first,
                  let keyData = KeychainStore.loadPrivateKey(for: keyID),
                  let keyPEM = String(data: keyData, encoding: .utf8) else { return nil }
            let passphrase = KeychainStore.loadPassphrase(for: keyID).flatMap { String(data: $0, encoding: .utf8) }
            return ServerCredentials(
                username: server.username,
                keyPEM: keyPEM,
                keyType: metadata.keyType,
                passphrase: passphrase
            )
        }

        manager.onCapturedClipping = { text in
            context.insert(Clipping(text: text, direction: .from))
        }

        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionManager)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
