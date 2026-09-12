import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Minimal app delegate whose one job is APNs: CloudKit's cross-device agent
/// pushes (`AgentSignalSubscriber`) ride remote notifications, and delivery
/// requires the process to have registered for them. Display and tap routing go
/// through `AgentNotificationService`'s UNUserNotificationCenter delegate —
/// foreground pushes present via `willPresent`, taps deep-link via `didReceive` —
/// so the remote-notification callback here is deliberately not a router: on
/// macOS it also fires on mere arrival, where hijacking navigation would be wrong.
///
/// The token callback forwards to `DeviceTokenUplink` on every launch (tokens
/// rotate; the control plane dedupes), which is how the headless fin-agentd
/// daemon gets a push path to this device. Registration failure is normal on
/// simulators and boxes without push entitlements, so it stays silent.
final class FinAppDelegate: NSObject {}

#if os(macOS)
extension FinAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        DeviceTokenUplink.register(deviceToken: deviceToken)
    }
}
#else
extension FinAppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        DeviceTokenUplink.register(deviceToken: deviceToken)
    }
}
#endif

@main
struct FinApp: App {
    @StateObject private var sessionManager: SessionManager
    @StateObject private var entitlementStore = EntitlementStore()
    private let modelContainer: ModelContainer
    #if os(macOS)
    @NSApplicationDelegateAdaptor(FinAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(FinAppDelegate.self) private var appDelegate
    #endif

    init() {
        // Delegate installation must precede any notification delivery; everything else
        // about the service stays dormant until the first agent prompt asks permission.
        AgentNotificationService.shared.install()
        // The CloudKit mirror's first import fires during container setup, moments from
        // now — a lazily-created monitor would miss it and report "no activity" for the
        // whole launch even though sync ran fine.
        _ = CloudSyncActivityMonitor.shared

        let container: ModelContainer
        do {
            // Server/KeyMetadata sync via the user's private CloudKit database (their
            // iCloud account IS the "profile" — there's no separate in-app sign-in).
            // Clipping/MarkdownDocument stay local-only; CloudKit mirroring requires every
            // synced model's properties to have defaults, which isn't worth imposing on
            // clippings/markdown bookmarks that were never asked to sync.
            // Agent joins the synced set: it's the same kind of portable configuration as
            // a server entry, and its one secret (the endpoint bearer token, when an
            // endpoint even needs one) lives in the Keychain rather than in this store.
            // AgentMemory syncs too: a conversation digested on one device should inform
            // the agent on every other. Its content derives from the same terminal
            // output that keeps AgentLogEntry local, so every write goes through
            // MemoryRedactor first — a deliberate residual risk, documented on the model.
            // AgentSignal and AgentRelayMessage are the cross-device notification
            // and message-relay tables: ephemeral (7-day sweep below), redacted
            // before write, and synced precisely because their whole purpose is to
            // reach the user's other devices.
            // RemoteInputPairing joins the synced set: it exists to be read by the
            // user's OTHER devices (the Apple TV's remote-keyboard secret) — the
            // private database's access control is the whole point of storing it there.
            let syncedConfig = ModelConfiguration(
                "Synced",
                schema: Schema([
                    Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
                    AgentSignal.self, AgentRelayMessage.self, RemoteInputPairing.self,
                ]),
                cloudKitDatabase: .automatic
            )
            // AgentLogEntry is local-only and stays that way: the trail quotes raw terminal
            // output, which is the likeliest place for a server's secrets to appear.
            let localConfig = ModelConfiguration(
                "Local",
                schema: Schema([Clipping.self, MarkdownDocument.self, AgentLogEntry.self]),
                cloudKitDatabase: .none
            )
            container = try ModelContainer(
                for: Schema([
                    Server.self, KeyMetadata.self, Agent.self, AgentMemory.self,
                    AgentSignal.self, AgentRelayMessage.self, RemoteInputPairing.self,
                    Clipping.self, MarkdownDocument.self, AgentLogEntry.self,
                ]),
                configurations: [syncedConfig, localConfig]
            )
        } catch {
            fatalError("Failed to create SwiftData model container: \(error)")
        }
        modelContainer = container
        // In-app App Intents (Siri "Message Fin") read the store through this
        // bridge — see FinSharedState. Assigned exactly once, before any intent
        // can possibly run.
        FinSharedState.modelContainer = container

        let manager = SessionManager()
        let context = container.mainContext

        // App Store screenshot capture only (FIN_SCREENSHOT_MODE=1); a no-op for
        // every real launch. See ScreenshotFixtures for why empty-state captures
        // were worth fixing.
        ScreenshotFixtures.seedIfNeeded(context)
        ScreenshotFixtures.cleanup(context)

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

        manager.onAgentLog = { record in
            context.insert(AgentLogEntry(record: record))
            // Fetch rather than cache: the per-agent mirror toggle must take effect on
            // the very next line, and a fetch-by-ID against the main context is cheap
            // at log-line rates. Missing agent → don't mirror.
            let agentID = record.agentID
            var descriptor = FetchDescriptor<Agent>(predicate: #Predicate { $0.id == agentID })
            descriptor.fetchLimit = 1
            if (try? context.fetch(descriptor).first)?.mirrorLogsToICloud == true {
                AgentLogMirror.shared.append(record)
            }
        }

        // Semantic recall: keyword-only for now. The Wax-backed on-device vector
        // index was removed 2026-09-11 (see VectorMemoryIndex.swift's header) —
        // dragging in Wax's whole broker/MCP-server module for its embedded vector
        // store broke both the macOS Release build and iOS compilation, for two
        // unrelated reasons neither of which had anything to do with the one API
        // surface Fin actually used. Semantic recall is being rebuilt on the cloud
        // control plane instead; `AgentMemoryIndexing` (VectorMemoryIndex.swift) is
        // the seam a future indexer plugs into without touching this call site.
        manager.memoryAccess = MemoryStore(context: context).access

        // Session routing, layered onto whichever access the branches above installed:
        // the registry is a plain machine-scoped file (see RoutingRegistryLocation for
        // why it must never sync), so it deliberately bypasses MemoryStore/SwiftData.
        // No cache, on purpose: composeSystemPrompt invokes this only at runtime
        // creation and Clear Conversation, so each call re-reads the tiny file and the
        // staleness window is the conversation itself — registry edits land at the
        // next new conversation, never mid-conversation. An absent file reads as nil,
        // which keeps the system prompt byte-identical to a build without routing.
        manager.memoryAccess.readRoutingRegistry = {
            RegistryDocument.loadIfPresent(at: RoutingRegistryLocation.fileURL)
        }

        // The goals ledger rides the same seam: a plain file in Application Support
        // (GoalsLedgerLocation), no cache. The system prompt re-reads it at runtime
        // creation and Clear Conversation like the registry; the heartbeat re-reads it
        // at EVERY beat, so ledger edits reach the tick within one interval. An absent
        // file reads as nil, which keeps both the system prompt and the beat text
        // byte-identical to a build without goals.
        manager.memoryAccess.readGoalsLedger = {
            LedgerDocument.loadIfPresent(at: GoalsLedgerLocation.fileURL)
        }

        manager.loadAgentHistory = { agentID in
            // Rebuilds the conversation from the persisted trail. Bounded to the recent
            // tail so a long-lived agent doesn't reopen with a transcript that instantly
            // needs compacting.
            var descriptor = FetchDescriptor<AgentLogEntry>(
                predicate: #Predicate<AgentLogEntry> { $0.agentID == agentID },
                sortBy: [SortDescriptor(\AgentLogEntry.timestamp, order: .reverse)]
            )
            descriptor.fetchLimit = 40
            guard let recent = try? context.fetch(descriptor) else { return [] }

            return recent
                .reversed()
                .compactMap { entry in
                    switch entry.kind {
                    case .userMessage:
                        // The prompt prefix is the only durable trace of a heartbeat
                        // turn; without it a restored check renders as a full user bubble.
                        // The recorded timestamp rides along so the watchdog's
                        // staleness gate sees the conversation's real age.
                        return AgentMessage(
                            role: .user,
                            text: entry.text,
                            isHeartbeat: entry.text.hasPrefix("[heartbeat]"),
                            timestamp: entry.timestamp
                        )
                    case .assistantMessage:
                        // Placeholder text stands in for a turn that was only tool calls.
                        return entry.text == "(tool call only)"
                            ? nil
                            : AgentMessage(role: .assistant, text: entry.text, timestamp: entry.timestamp)
                    default:
                        return nil
                    }
                }
        }

        AgentNotificationService.shared.onOpenAgent = { [weak manager] agentID, originDeviceID8 in
            manager?.pendingAgentOpen = SessionManager.PendingAgentOpen(
                agentID: agentID, originDeviceID8: originDeviceID8
            )
        }

        // Every local banner also writes a synced AgentSignal, so the user's OTHER
        // devices get a push about it (their CKQuerySubscription excludes the
        // origin device — see AgentSignalSubscriber). Preview redaction/capping
        // happens in the service before this closure ever sees the text.
        AgentNotificationService.shared.persistSignal = { kind, agentID, agentName, preview in
            context.insert(AgentSignal(
                agentID: agentID,
                agentName: agentName,
                kind: kind,
                preview: preview,
                sourceDeviceID8: DeviceIdentity.short
            ))
        }

        // Hosting-side delivery for messages typed on a non-hosting device. The
        // applier observes CloudKit import events itself; the manager pokes it on
        // turn finish and the explicit watchdog tick.
        let relayApplier = AgentRelayApplier(context: context)
        relayApplier.liveTargets = { [weak manager] in
            manager?.relayTargets() ?? []
        }
        manager.relayApplier = relayApplier
        relayApplier.sweepExpiredCrossDeviceRecords()

        // Memory sync: same ModelContext-ownership split as relayApplier above. Audit
        // lines land in whichever runtime is actually hosting the agent, same as
        // DaemonMemoryClient's failures land in the daemon's own log.
        let memorySync = AgentMemorySyncService(context: context)
        memorySync.audit = { [weak manager] agentID, line in
            manager?.runtime(forAgentID: agentID)?.recordSupervisionNotice(line)
        }
        manager.memorySyncService = memorySync

        // Cross-device push subscriptions: idempotent refresh once the CloudKit
        // account answers. Failures land in the audit trail (and iCloud mirror) —
        // a silent zero-subscription outage cost a full debug cycle.
        //
        // Skipped when launched by `launchFinApp()` (finUITests/XCUIHelpers.swift),
        // which sets FIN_UI_TESTING=1: `CKContainer(identifier:)` traps outright —
        // a non-throwing, non-catchable crash inside Apple's own framework —
        // whenever the running binary's code signature lacks a valid CloudKit
        // container entitlement, which an ad-hoc-signed UI test run (see
        // `.claude/skills/apple-test/SKILL.md`; ad-hoc signing needs no
        // provisioning profile, which is also exactly why it has no CloudKit
        // entitlement) never has. `XCTestConfigurationFilePath` was tried first
        // and does NOT work here: it's set on a unit-test host process (same
        // process as the app), but a UI test's app-under-test is a genuinely
        // separate process `XCUIApplication.launch()` spawns, and that env var
        // isn't propagated to it — confirmed live, the crash still reproduced
        // with that check in place. Real users always run a properly-signed
        // build with no launch environment override, so this changes nothing
        // for them.
        //
        // The UNIT-test host is the other case: there the tests run inside this
        // very process, so `XCTestConfigurationFilePath` IS set — and the host is
        // signed by scripts/test-macos.sh without the CloudKit entitlement, so the
        // same trap fires at bootstrap and no test ever runs (seen live 2026-09-12:
        // "test runner crashed before establishing connection").
        let environment = ProcessInfo.processInfo.environment
        if environment["FIN_UI_TESTING"] == nil, environment["XCTestConfigurationFilePath"] == nil {
            Task { [weak manager] in
                let subscriber = AgentSignalSubscriber()
                subscriber.onSubscriptionAudit = { message in
                    Task { @MainActor in manager?.recordLifecycleEvent(message) }
                }
                await subscriber.ensureSubscriptions()
            }
        }

        manager.lifecycleAuditAgents = {
            // Only mirror-enabled agents carry lifecycle lines: the lines exist for
            // the remote supervisor reading the iCloud mirror, and an agent whose
            // mirroring is off has opted out of exactly that audience.
            let descriptor = FetchDescriptor<Agent>(
                predicate: #Predicate { $0.mirrorLogsToICloud == true }
            )
            return ((try? context.fetch(descriptor)) ?? []).map { (id: $0.id, name: $0.name) }
        }

        // Remote supervision: capability URLs stamped into a build's Info.plist seed
        // the device-local config once; a user-pasted URL always wins.
        RemoteSupervisionConfig.seedFromInfoPlist()

        // Device-wide config sync: pull the iCloud KVS replica (AFTER plist
        // seeding, so a stamped build's seed can promote to the account) and keep
        // pulling on external changes — a control-plane endpoint pasted on the
        // Mac reaches the phone without a relaunch. Secrets ride iCloud Keychain
        // instead of KVS; `SyncedDeviceConfig` documents the split and the
        // deliberate non-goals (capability URLs, machine-scoped files, telemetry
        // opt-ins).
        SyncedDeviceConfig.activate()

        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        manager.recordLifecycleEvent("[app] launched build \(buildNumber)")

        _sessionManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionManager)
                .environmentObject(entitlementStore)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
        #if os(macOS) || os(visionOS)
        // The agent hub (settings, logs/traces, memory, remote, artifacts, key) opens
        // as its own resizable window on macOS/visionOS instead of pushing over the
        // terminal — see AgentHubWindowView. Keyed by Agent.id (a plain UUID) rather
        // than PersistentIdentifier so the value stays trivially Codable across the
        // openWindow(id:value:) boundary; the window resolves the live SwiftData model
        // itself. `.modelContainer` is reattached here deliberately — passing the SAME
        // container instance to a second scene doesn't create a second store, it's the
        // documented way to share one SwiftData store across multiple windows.
        WindowGroup(id: FinScene.agentHub, for: UUID.self) { $agentID in
            AgentHubWindowView(agentID: agentID)
                .environmentObject(sessionManager)
                .environmentObject(entitlementStore)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 920, height: 640)
        // A file opens as its own resizable window too — see
        // MarkdownReaderWindowView — for the same reason: worth reading next to a
        // terminal session, an agent's settings, or another file.
        WindowGroup(id: FinScene.markdownReader, for: UUID.self) { $documentID in
            MarkdownReaderWindowView(documentID: documentID)
                .environmentObject(sessionManager)
                .environmentObject(entitlementStore)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 720, height: 640)
        #endif
    }
}

#if os(macOS) || os(visionOS)
/// Scene identifiers shared between `finApp`'s declaration and every `openWindow` call
/// site, so a renamed scene can't silently desync into a runtime no-op.
enum FinScene {
    static let agentHub = "agent-hub"
    static let markdownReader = "markdown-reader"
}
#endif
