import Foundation
import CloudKit
import os

/// Registers cross-device agent pushes: one USER-LEVEL `CKQuerySubscription` per
/// signal kind on the mirrored `CD_AgentSignal` record type, predicated on the
/// kind alone. Origin-device suppression is CloudKit's own: the server never
/// pushes a fired subscription to the device that made the originating change,
/// so the device that wrote a signal (and already showed a local banner) is
/// excluded automatically, and every OTHER device receives exactly one push per
/// signal — the ids are user-level (no per-device suffix), so all installs
/// share the same four subscriptions instead of each owning a firing copy.
///
/// One subscription per kind rather than the single subscription the feature
/// sketch assumed: `CKSubscription.NotificationInfo` is fixed at creation time,
/// so a kind-specific alert *title* can only exist as one static subscription per
/// kind. The alert *body* does vary per record, via the classic CloudKit
/// field-substitution mechanism — `alertLocalizationKey` naming a format string
/// in `Localizable.strings` ("%1$@") whose arguments (`alertLocalizationArgs`)
/// are record field keys, here `CD_preview`. A plain `alertBody` fallback rides
/// along in case the payload's loc-key is ever dropped.
///
/// Everything here tolerates failure silently (one os_log line): CloudKit being
/// unavailable must never break the app, and the subscription is retried on the
/// next launch. Note the Development-environment caveats: the record type only
/// exists after the first `AgentSignal` export, and `CD_kind` needs a QUERYABLE
/// index in the CloudKit Console before registration succeeds.
/// (`CD_sourceDeviceID8` no longer needs one — the predicate dropped it — but
/// the field is still written on every signal for audit.)
final class AgentSignalSubscriber {
    static let containerIdentifier = "iCloud.dev.levischoen.fin"
    /// The CloudKit face of `AgentSignal` under SwiftData's `CD_` mirroring prefix.
    static let recordType = "CD_AgentSignal"
    /// Prefix shared by every subscription id, old shapes and new; the full
    /// user-level id appends a version and the kind so each can carry its own
    /// title.
    static let subscriptionIDPrefix = "fin-agent-signals"
    /// Version segment in the current ids ("fin-agent-signals-v2-<kind>").
    /// Bumped when `NotificationInfo` changes (v2 added `CD_sourceDeviceID8` to
    /// `desiredKeys` so a tap can route to the signal's ORIGIN device): a fresh
    /// id guarantees the new payload reaches CloudKit for existing installs
    /// whatever the server's same-id-save semantics turn out to be — a same-id
    /// re-save that the server quietly rejected as a duplicate would strand the
    /// old `desiredKeys` forever behind this class's silent-failure policy.
    static let subscriptionIDVersion = "v2"

    /// `Localizable.strings` key whose value is "%1$@" — the alert body becomes
    /// the record's redacted `CD_preview` verbatim.
    static let previewLocalizationKey = "AGENT_SIGNAL_PREVIEW"

    private static let logger = Logger(subsystem: "dev.levischoen.fin", category: "AgentSignalSubscriber")

    /// Pure builder, separated from CloudKit I/O so the predicate/ID/keys are
    /// unit-testable: one user-level subscription per kind, firing on record
    /// creation only (signals are insert-only). No device term anywhere — the
    /// server's own originator exclusion is the origin-device suppression.
    static func makeSubscriptions() -> [CKQuerySubscription] {
        AgentSignalKind.allCases.map { kind in
            let subscription = CKQuerySubscription(
                recordType: recordType,
                predicate: NSPredicate(format: "CD_kind == %@", kind.rawValue),
                subscriptionID: "\(subscriptionIDPrefix)-\(subscriptionIDVersion)-\(kind.rawValue)",
                options: [.firesOnRecordCreation]
            )
            let info = CKSubscription.NotificationInfo()
            info.title = kind.pushTitle
            info.alertLocalizationKey = previewLocalizationKey
            info.alertLocalizationArgs = ["CD_preview"]
            // Static fallback body should the loc-key mechanism ever not render.
            info.alertBody = "Open Fin to view."
            info.soundName = "default"
            info.shouldBadge = false
            // The tap handler routes straight to the agent's conversation —
            // ON THE SIGNAL'S ORIGIN DEVICE, which is why the source device
            // rides along: every device keeps its own transcript for the same
            // synced Agent, so the origin id is what tells the receiver the
            // conversation provably lives elsewhere.
            //
            // HARD SERVER LIMIT: at most THREE desiredKeys per subscription —
            // a fourth makes CloudKit reject the save outright, which is how
            // v2's original four-key set (this list plus CD_agentName) zeroed
            // out every signal subscription on the account. CD_agentName is
            // the one nothing consumes: the banner title is the subscription's
            // static per-kind title, and the tap parser reads only the agent
            // id and origin. Adding a key here means removing one first.
            info.desiredKeys = ["CD_agentID", "CD_kind", "CD_sourceDeviceID8"]
            subscription.notificationInfo = info
            return subscription
        }
    }

    /// Whether a subscription id has the retired per-device shape
    /// `fin-agent-signals-<deviceID8>-<kind>` (8 lowercase hex chars, then the
    /// kind). Those caused N−1 duplicate banners per receiver — every non-origin
    /// device's copy fired — and orphans from deleted installs (the deviceID8 is
    /// minted into UserDefaults, reset on app deletion) accumulated forever.
    /// `ensureSubscriptions` deletes every match, this install's own included.
    static func isLegacySubscriptionID(_ id: String) -> Bool {
        let prefix = subscriptionIDPrefix + "-"
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        let parts = rest.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, !parts[1].isEmpty,
              parts[0].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return false }
        return true
    }

    /// Every retired subscription id shape: the per-device legacy shape above,
    /// PLUS the unversioned user-level ids ("fin-agent-signals-<kind>") the v2
    /// bump replaced — matched exactly, per known kind, so the current
    /// "fin-agent-signals-v2-<kind>" ids (whose "v2" segment is neither a kind
    /// nor 8 hex chars) always survive the cleanup.
    static func isRetiredSubscriptionID(_ id: String) -> Bool {
        if isLegacySubscriptionID(id) { return true }
        return AgentSignalKind.allCases.contains { "\(subscriptionIDPrefix)-\($0.rawValue)" == id }
    }

    /// Creates/refreshes the current versioned user-level subscriptions once the
    /// CloudKit account is reachable, and deletes every retired shape in the same
    /// modify call — the per-device legacy ids (this install's old ones AND
    /// orphans left by deleted installs) and the unversioned user-level ids the
    /// v2 payload bump replaced. Saving under a fixed ID every launch stays
    /// idempotent for the current set; payload changes ride an ID version bump
    /// instead of trusting the server to replace a same-id re-save (see
    /// `subscriptionIDVersion`).
    func ensureSubscriptions() async {
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard let status = try? await container.accountStatus(), status == .available else {
            Self.logger.info("agent-signal subscriptions skipped: no available iCloud account")
            return
        }
        let database = container.privateCloudDatabase
        // Cleanup is best-effort: an unreadable subscription list must not block
        // the upsert of the current set.
        let retiredIDs = ((try? await database.allSubscriptions()) ?? [])
            .map(\.subscriptionID)
            .filter(Self.isRetiredSubscriptionID)
        // Save and delete in SEPARATE calls, saves first — a combined modify once
        // deleted the retired set while the saves failed (v2 rejected as
        // duplicates of the still-present v1 subscriptions in the same batch),
        // leaving the account with ZERO signal subscriptions and no banners on
        // any device. Retired IDs are only removed after the current set exists.
        do {
            _ = try await database.modifySubscriptions(
                saving: Self.makeSubscriptions(), deleting: []
            )
        } catch {
            // Surfaced to the audit trail (and the iCloud mirror) — a silent
            // warning hid the zero-subscription outage for a full debug cycle.
            Self.logger.warning("agent-signal subscription save failed: \(error.localizedDescription)")
            onSubscriptionAudit?("[signals] subscription save failed: \(error.localizedDescription)")
            return
        }
        if !retiredIDs.isEmpty {
            do {
                _ = try await database.modifySubscriptions(saving: [], deleting: retiredIDs)
            } catch {
                Self.logger.warning("retired subscription cleanup failed: \(error.localizedDescription)")
                onSubscriptionAudit?("[signals] retired subscription cleanup failed: \(error.localizedDescription)")
            }
        }
        onSubscriptionAudit?("[signals] subscriptions ensured (v2)")
    }

    /// Wired by FinApp to the lifecycle audit so subscription failures reach the
    /// iCloud mirror instead of dying in os_log.
    var onSubscriptionAudit: ((String) -> Void)?

    /// What a tapped push asks the app to open: the agent, plus the
    /// `DeviceIdentity.short` of the device the signal originated on — the device
    /// whose transcript the tap must reach. Origin is optional because pushes
    /// minted by pre-v2 subscriptions don't carry `CD_sourceDeviceID8`; those
    /// taps fall back to the residence routing rule.
    struct PushOpenTarget: Equatable {
        let agentID: UUID
        let originDeviceID8: String?
    }

    /// Extracts the open target from a CloudKit push's userInfo, when the push
    /// is one of ours. Tolerant of any payload shape: anything unparseable — or a
    /// UUID field CloudKit encoded some other way — returns nil and the tap just
    /// opens the app.
    nonisolated static func openTarget(fromPushUserInfo userInfo: [AnyHashable: Any]) -> PushOpenTarget? {
        guard let dictionary = userInfo as? [String: NSObject],
              let notification = CKNotification(fromRemoteNotificationDictionary: dictionary),
              let query = notification as? CKQueryNotification
        else { return nil }
        return openTarget(
            subscriptionID: query.subscriptionID,
            recordFields: query.recordFields as [String: Any]?
        )
    }

    /// The pure half of the parse, table-testable without constructing CloudKit's
    /// private wire format. The agent id is load-bearing (nil without it); the
    /// origin is best-effort — missing, empty, or oddly-typed degrades to nil
    /// rather than dropping the tap.
    nonisolated static func openTarget(
        subscriptionID: String?, recordFields: [String: Any]?
    ) -> PushOpenTarget? {
        guard subscriptionID?.hasPrefix("\(subscriptionIDPrefix)-") == true,
              let idValue = recordFields?["CD_agentID"] as? String,
              let agentID = UUID(uuidString: idValue)
        else { return nil }
        let origin = recordFields?["CD_sourceDeviceID8"] as? String
        return PushOpenTarget(
            agentID: agentID,
            originDeviceID8: origin?.isEmpty == false ? origin : nil
        )
    }
}
