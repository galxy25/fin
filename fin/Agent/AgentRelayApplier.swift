import Foundation
import SwiftData
import CoreData

/// Applies synced `AgentRelayMessage` rows on whichever device hosts the target
/// agent's live runtime — the delivery half of the remote conversation view.
///
/// Modeled on `AgentDirectiveChannel`'s apply loop, because the constraints are
/// identical: injection goes through the exact same `submit` path a typed message
/// takes (so manual-mode approval and the destructive-command heuristic hold), a
/// message that can't apply right now (no live runtime, disconnected session,
/// blocked configuration) is deferred and retried on the next check, and a
/// message counts as applied once submit accepted it — started immediately or
/// queued behind the in-flight turn, which the runtime's FIFO prompt queue
/// guarantees to run in order. Checks run on CloudKit import events (the same
/// `NSPersistentCloudKitContainer` notification `CloudSyncActivityMonitor`
/// observes), on the watchdog's explicit foreground tick, and after every
/// finished turn (the moment a deferred-because-busy message becomes applicable).
///
/// Cross-device claim policy (who may apply a given message):
/// - Armed monitor: while `agent.monitoringArmed`, ONLY the device whose
///   `DeviceIdentity.id` matches `agent.monitoringDeviceID` applies — one
///   deterministic winner, no race.
/// - No armed monitor: any device with a live, connected runtime for the agent
///   may apply, but first sleeps a deterministic per-(device, message) jitter
///   (< 2s) and then RE-CHECKS `appliedAt` from the store — if another device
///   claimed the message during the jitter window, this device backs off.
///   Residual race, accepted: two unarmed consoles whose jitters collide AND
///   whose `appliedAt` stamps haven't sync-round-tripped can still both apply.
///   The injected turn remains mode-gated (manual approval, destructive
///   heuristic), so the blast radius is a duplicated prompt, not an unreviewed
///   action.
@MainActor
final class AgentRelayApplier {
    /// A live runtime plus its session's connectedness — the same shape the
    /// directive channel uses, supplied by `SessionManager`.
    struct Target {
        let runtime: AgentRuntime
        let sessionConnected: Bool
    }

    /// Signals and APPLIED relay messages older than this are deleted by the
    /// launch sweep. An unapplied relay is protected by the 30-day hard floor
    /// below — it stays retryable, not silently dropped at 7 days.
    static let retentionDays = 7
    /// Hard floor for unapplied relay messages: past this age even a
    /// never-applied row is deleted (the sender UI shows it as "expired").
    static let unappliedRetentionDays = 30
    /// Same bound the directive channel puts on remote text: the store is synced
    /// input, and this caps what can ever reach a transcript.
    static let maxTextLength = 8000
    /// `appliedByDeviceID8` sentinel prefix for messages resolved WITHOUT being
    /// injected (e.g. over-length). The sender UI renders these as "not
    /// delivered" instead of "sent". No schema change: the sentinel rides the
    /// existing string field.
    static let rejectedPrefix = "rejected"
    /// Sentinel for an over-length message (the composer enforces the same cap
    /// client-side; this is belt and braces against older builds and raw writes).
    static let rejectedLength = "rejected:length"

    private let context: ModelContext
    private let deviceID8: String
    /// Full `DeviceIdentity.id`, compared against `Agent.monitoringDeviceID`
    /// (which stores the full id) for the armed-monitor claim.
    private let deviceID: String
    var liveTargets: () -> [Target] = { [] }
    /// Test seam for the pre-claim jitter; production sleeps for real.
    var jitterSleep: (Int) async -> Void = { milliseconds in
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    /// Ids already applied by THIS instance — guards double-submission when
    /// overlapping sync notifications land before the `appliedAt` stamp has
    /// round-tripped through a fetch.
    private var appliedIDs: Set<UUID> = []
    /// Durable twin of `appliedIDs` (UserDefaults, capped): survives a crash
    /// between submit and the context save, so a relaunch never re-injects a
    /// message this device already delivered.
    private var ledger: AgentRelayAppliedLedger
    private var syncObserver: NSObjectProtocol?
    private var applyPassTask: Task<Void, Never>?
    private var rerunRequested = false

    init(
        context: ModelContext,
        deviceID8: String = DeviceIdentity.short,
        deviceID: String = DeviceIdentity.id,
        defaults: UserDefaults = .standard
    ) {
        self.context = context
        self.deviceID8 = deviceID8
        self.deviceID = deviceID
        self.ledger = AgentRelayAppliedLedger(defaults: defaults)
        // A finished CloudKit import is the moment a freshly-synced relay message
        // exists locally; the event stream is the push-driven check.
        syncObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event,
                event.type == .import, event.endDate != nil
            else { return }
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
    }

    /// Kicks one application pass. Coalescing wrapper around the async pass:
    /// a request that arrives mid-pass runs one more full pass after (the
    /// in-flight pass may already be past the row the new event delivered).
    func applyPending() {
        guard applyPassTask == nil else {
            rerunRequested = true
            return
        }
        applyPassTask = Task { [weak self] in
            await self?.applyPendingNow()
            guard let self else { return }
            self.applyPassTask = nil
            if self.rerunRequested {
                self.rerunRequested = false
                self.applyPending()
            }
        }
    }

    /// One application pass: every unapplied message, oldest first. MainActor
    /// throughout (the jitter sleep is the only suspension), so a submit that
    /// claims a runtime is visible to the next message in the same pass (it
    /// defers instead of interleaving turns).
    func applyPendingNow() async {
        let descriptor = FetchDescriptor<AgentRelayMessage>(
            predicate: #Predicate { $0.appliedAt == nil },
            sortBy: [SortDescriptor(\AgentRelayMessage.createdAt)]
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        for message in pending {
            guard !appliedIDs.contains(message.id) else { continue }
            if ledger.contains(message.id, agentID: message.agentID) {
                // Delivered on a previous launch whose stamp never saved (crash
                // between submit and save) or was resurrected by sync: restore
                // the stamp, never re-inject.
                stamp(message)
                continue
            }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // Hard skip, mirroring the directive channel: this build will never
                // inject it, so it must not stay eternally pending on every device.
                stamp(message)
                continue
            }
            guard text.count <= Self.maxTextLength else {
                // Same hard skip, but flagged so the sender's UI shows "not
                // delivered (too long)" instead of a false "sent".
                stamp(message, appliedBy: Self.rejectedLength)
                continue
            }
            // Claim policy, armed half: while a monitor is armed, its home device
            // is the ONLY applier — every other device leaves the row pending
            // even if it happens to hold a live runtime for the same agent.
            let armedElsewhere = isMonitoringArmedOnAnotherDevice(agentID: message.agentID)
            guard !armedElsewhere else { continue }
            // Deferral cases — retried on the next check: the agent isn't hosted
            // here (yet), its session is down, or the configuration can't run at
            // all. A busy runtime no longer defers: submit queues the message and
            // the runtime's FIFO queue guarantees it runs, in order, before any
            // heartbeat — so queued counts as applied.
            guard let target = liveTargets().first(where: { $0.runtime.agent.id == message.agentID }),
                  target.sessionConnected,
                  target.runtime.configurationBlocker == nil
            else { continue }

            if !isMonitoringArmedHere(agentID: message.agentID) {
                // Claim policy, unarmed half: no deterministic winner exists, so
                // stagger contenders with a per-(device, message) jitter, then
                // re-check whether someone else's stamp synced in meanwhile.
                await jitterSleep(Self.claimJitterMillis(deviceID8: deviceID8, messageID: message.id))
                guard message.appliedAt == nil, refetchedAppliedAt(id: message.id) == nil else {
                    continue
                }
                // The session or configuration may have changed during the jitter
                // suspension; re-verify before injecting. (A submit that claimed
                // the runtime meanwhile is fine — the queue keeps ordering.)
                guard target.sessionConnected,
                      target.runtime.configurationBlocker == nil
                else { continue }
            }

            // The SAME path a typed message takes — submit's send_input calls still
            // pass through manual-mode approval and the destructive heuristic.
            // Started and queued both count as delivered; only an outright
            // rejection leaves the row pending for the next check.
            guard target.runtime.submit(text) != .rejected else { continue }
            stamp(message)
            target.runtime.recordSupervisionNotice(
                "[relay] applied message \(message.id.uuidString.lowercased().prefix(8)) from device \(message.authorDeviceID8)"
            )
        }
    }

    /// Deterministic per-(device, message) delay in 0..<2000 ms. FNV-1a rather
    /// than `Hasher` because the value must agree across launches (and be
    /// testable) — Swift's hash seeds are per-process.
    nonisolated static func claimJitterMillis(deviceID8: String, messageID: UUID) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (deviceID8 + messageID.uuidString.lowercased()).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % 2000)
    }

    /// `appliedAt` re-read through a FRESH fetch, so a stamp another device
    /// synced during the jitter window is seen even if the in-memory row hasn't
    /// been touched by the merge yet.
    private func refetchedAppliedAt(id: UUID) -> Date? {
        var descriptor = FetchDescriptor<AgentRelayMessage>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.appliedAt
    }

    private func fetchAgent(id: UUID) -> Agent? {
        var descriptor = FetchDescriptor<Agent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func isMonitoringArmedOnAnotherDevice(agentID: UUID) -> Bool {
        guard let agent = fetchAgent(id: agentID), agent.monitoringArmed else { return false }
        return agent.monitoringDeviceID != deviceID
    }

    private func isMonitoringArmedHere(agentID: UUID) -> Bool {
        guard let agent = fetchAgent(id: agentID), agent.monitoringArmed else { return false }
        return agent.monitoringDeviceID == deviceID
    }

    /// Marks a message resolved on this device and SAVES immediately: the stamp
    /// syncs back so the sender's remote console flips "sending…" to "sent", and
    /// an explicit save (rather than waiting on autosave) plus the durable
    /// ledger closes the crash-between-submit-and-save replay window.
    private func stamp(_ message: AgentRelayMessage, appliedBy: String? = nil) {
        message.appliedAt = Date()
        message.appliedByDeviceID8 = appliedBy ?? deviceID8
        appliedIDs.insert(message.id)
        ledger.record(message.id, agentID: message.agentID)
        try? context.save()
    }

    /// Launch sweep for both ephemeral cross-device tables. Deletion syncs, but a
    /// stale signal is noise on every device, so any device may collect it.
    /// Relay messages: an APPLIED row is done and sweeps at `retentionDays`; an
    /// UNAPPLIED row stays retryable until the `unappliedRetentionDays` hard
    /// floor, past which the sender UI has long shown it as "expired".
    func sweepExpiredCrossDeviceRecords(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        try? context.delete(model: AgentSignal.self, where: #Predicate { $0.createdAt < cutoff })
        try? context.delete(
            model: AgentRelayMessage.self,
            where: #Predicate { $0.createdAt < cutoff && $0.appliedAt != nil }
        )
        let hardFloor = now.addingTimeInterval(-TimeInterval(Self.unappliedRetentionDays) * 86_400)
        try? context.delete(
            model: AgentRelayMessage.self, where: #Predicate { $0.createdAt < hardFloor }
        )
    }
}

/// Ordered, capped, per-agent record of relay-message ids this device applied —
/// the durable twin of the applier's in-memory set, so a crash between submit
/// and the context save can't replay a delivered message on relaunch. Same
/// design as the directive channel's `AppliedDirectiveStore`: UserDefaults,
/// JSON array string (inspectable from the shell), oldest evicted past the cap.
struct AgentRelayAppliedLedger {
    static let cap = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(agentID: UUID) -> String {
        "fin.relay.applied.\(agentID.uuidString.lowercased())"
    }

    private func load(agentID: UUID) -> [String] {
        guard let stored = defaults.string(forKey: Self.key(agentID: agentID)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? []
    }

    func contains(_ messageID: UUID, agentID: UUID) -> Bool {
        load(agentID: agentID).contains(messageID.uuidString.lowercased())
    }

    func record(_ messageID: UUID, agentID: UUID) {
        var ids = load(agentID: agentID)
        let id = messageID.uuidString.lowercased()
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.cap { ids.removeFirst(ids.count - Self.cap) }
        if let data = try? JSONEncoder().encode(ids) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key(agentID: agentID))
        }
    }
}
