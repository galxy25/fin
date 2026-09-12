// Fin on Apple TV: an SSH terminal whose configuration arrives over CloudKit
// (the same synced Server/KeyMetadata rows every Fin device shares), whose SSH
// keys arrive through the key vault after Sign in with Apple (TVCloudAccount —
// tvOS has no iCloud Keychain), and whose input is a Bluetooth keyboard
// (GCKeyboard) or the system's own iPhone-typing keyboard.
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
    @StateObject private var account: TVCloudAccount
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

        // App Store screenshot capture only (FIN_SCREENSHOT_MODE=1). A tvOS
        // simulator has no iCloud account, so without this every capture is the
        // "No Servers Yet" empty state — see ScreenshotFixtures.
        ScreenshotFixtures.seedIfNeeded(context)
        ScreenshotFixtures.cleanup(context)

        // Same join as the iOS app: Server.keyID -> KeyMetadata (synced) -> key
        // material in THIS device's Keychain. tvOS never receives iCloud Keychain
        // items, so the material gets here through the key vault (TVCloudAccount).
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

        _sessionManager = StateObject(wrappedValue: manager)
        _keyboardMonitor = StateObject(wrappedValue: keyboard)
        _account = StateObject(wrappedValue: TVCloudAccount(context: context))
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(sessionManager)
                .environmentObject(keyboardMonitor)
                .environmentObject(account)
                .preferredColorScheme(.dark)
                .onAppear {
                    keyboardMonitor.start()
                }
        }
        .modelContainer(modelContainer)
    }
}
