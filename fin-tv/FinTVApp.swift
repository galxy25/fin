// Fin on Apple TV: an SSH terminal whose configuration arrives over CloudKit
// (the same synced Server/KeyMetadata rows every Fin device shares) and whose
// input arrives from a Bluetooth keyboard (GCKeyboard) or the Fin iOS app acting
// as a remote keyboard over the local network, gated to the same iCloud account.
import SwiftUI
import SwiftData
import UIKit

/// APNs registration so CloudKit's silent import pushes wake the mirror — the
/// same reason the iOS app registers (see fin/finApp.swift).
final class FinTVAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct FinTVApp: App {
    @StateObject private var sessionManager: TVSessionManager
    @StateObject private var keyboardMonitor: TVKeyboardMonitor
    @StateObject private var remoteInput: RemoteInputService
    private let modelContainer: ModelContainer
    @UIApplicationDelegateAdaptor(FinTVAppDelegate.self) private var appDelegate

    init() {
        // Schema parity with the iOS app's "Synced" configuration — the mirror of
        // the same private-database records. tvOS twist: local persistent storage
        // outside Caches is not dependable on device (App Programming Guide for
        // tvOS), so the store file lives in Caches and CloudKit is the source of
        // truth — a purged store just re-imports.
        let container: ModelContainer
        do {
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FinSynced.store")
            let syncedConfig = ModelConfiguration(
                "Synced",
                schema: Schema([
                    Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
                    AgentSignal.self, AgentRelayMessage.self, RemoteInputPairing.self,
                ]),
                url: cachesURL,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(
                for: Schema([
                    Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
                    AgentSignal.self, AgentRelayMessage.self, RemoteInputPairing.self,
                ]),
                configurations: [syncedConfig]
            )
        } catch {
            fatalError("Failed to create SwiftData model container: \(error)")
        }
        modelContainer = container

        let manager = TVSessionManager()
        let context = container.mainContext

        // Same join as the iOS app: Server.keyID -> KeyMetadata (synced) -> key
        // material in THIS device's Keychain. tvOS never receives iCloud Keychain
        // items, so the material gets here via the companion's provisioning path.
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

        let keyboard = TVKeyboardMonitor()
        keyboard.sendBytes = { [weak manager] bytes in
            manager?.activeSession?.send(bytes: bytes)
        }
        keyboard.applicationCursorKeys = { [weak manager] in
            manager?.activeSession?.applicationCursorKeys ?? false
        }
        // Capture gating (only while a terminal is on screen) is wired by the
        // terminal screen via TVInputRouter below.

        let remote = RemoteInputService()
        remote.pairingSecret = {
            RemoteInputPairingStore.resolve(context: context, deviceName: UIDevice.current.name)
        }
        remote.sendToSession = { [weak manager] bytes in
            manager?.activeSession?.send(bytes: bytes)
        }
        remote.provisionKey = { keyID, name, keyTypeRaw, pem, passphrase in
            guard let keyType = SSHKeyType(rawValue: keyTypeRaw) else { return false }
            do {
                try KeychainStore.savePrivateKey(Data(pem.utf8), for: keyID)
                if let passphrase, !passphrase.isEmpty {
                    try KeychainStore.savePassphrase(Data(passphrase.utf8), for: keyID)
                }
            } catch {
                return false
            }
            // The KeyMetadata row normally arrives via CloudKit on its own; if it
            // hasn't yet, materialize it now (same id) so the key is usable
            // immediately — sync will merge rather than duplicate on record name.
            let descriptor = FetchDescriptor<KeyMetadata>(predicate: #Predicate { $0.id == keyID })
            if (try? context.fetch(descriptor).first) == nil {
                let metadata = KeyMetadata(name: name, keyType: keyType)
                metadata.id = keyID
                context.insert(metadata)
            }
            return true
        }

        _sessionManager = StateObject(wrappedValue: manager)
        _keyboardMonitor = StateObject(wrappedValue: keyboard)
        _remoteInput = StateObject(wrappedValue: remote)
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(sessionManager)
                .environmentObject(keyboardMonitor)
                .environmentObject(remoteInput)
                .preferredColorScheme(.dark)
                .onAppear {
                    keyboardMonitor.start()
                    remoteInput.start(deviceName: UIDevice.current.name)
                }
        }
        .modelContainer(modelContainer)
    }
}
