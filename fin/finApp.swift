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
final class FinAppDelegate: NSObject {}

#if os(macOS)
extension FinAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
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

        // Semantic recall (PROTOTYPE, vector-recall branch) rides on Wax's built-in
        // on-device embedder, which needs iOS 18/macOS 15; below that the store runs
        // keyword-only exactly as before — the gate only excludes iOS 17. visionOS is
        // keyword-only too, but for a different reason: Wax doesn't compile there
        // (see project.yml), so the canImport branch vanishes from that build.
        #if canImport(Wax)
        if #available(iOS 18.0, macOS 15.0, *) {
            let indexer = VectorMemoryIndexManager()
            let memoryStore = MemoryStore(context: context, indexer: indexer)
            manager.memoryAccess = memoryStore.access
            // Deleting an agent deletes its plaintext index files outright — the
            // lazy self-heal can never fire for an agent that no longer exists.
            AgentMemoryIndexRegistry.destroyIndex = { agentID in
                Task { await indexer.destroyIndex(agentID: agentID) }
            }
            // Index-level audit events (bloat recovery) ride the lifecycle-audit
            // machinery so they reach the iCloud mirror — the field bloat defect
            // was only diagnosable remotely.
            AgentMemoryIndexRegistry.audit = { [weak manager] _, line in
                manager?.recordLifecycleEvent(line)
            }
            // Launch-time consistency pass: remote (CloudKit-synced) deletions have
            // no per-record hook, so shortly after launch compare every agent's
            // index against SwiftData truth (cheap; full rebuild only on
            // divergence), and sweep index files for agents that no longer exist
            // (deleted on another device). Erasure SLA — see VectorMemoryIndex.
            Task { @MainActor in
                // A beat after launch: off the startup critical path, and late
                // enough that CloudKit's first import has usually landed, so the
                // pass compares against post-sync truth.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let agentIDs = Set((((try? context.fetch(FetchDescriptor<Agent>())) ?? []).map(\.id)))
                await indexer.pruneOrphanedIndexes(keeping: agentIDs)
                for agentID in agentIDs {
                    await indexer.ensureConsistent(
                        agentID: agentID,
                        expected: memoryStore.indexableEpisodicRecords(agentID: agentID)
                    )
                }
            }
        } else {
            manager.memoryAccess = MemoryStore(context: context).access
        }
        #else
        manager.memoryAccess = MemoryStore(context: context).access
        #endif

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

        // Cross-device push subscriptions: idempotent refresh once the CloudKit
        // account answers. Failures land in the audit trail (and iCloud mirror) —
        // a silent zero-subscription outage cost a full debug cycle.
        Task { [weak manager] in
            let subscriber = AgentSignalSubscriber()
            subscriber.onSubscriptionAudit = { message in
                Task { @MainActor in manager?.recordLifecycleEvent(message) }
            }
            await subscriber.ensureSubscriptions()
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
    }
}
