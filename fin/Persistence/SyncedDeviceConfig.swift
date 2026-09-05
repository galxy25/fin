import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the sync pass touches, as a seam so
/// tests can run the migration rule against a dictionary instead of the live
/// iCloud replica.
protocol SyncedKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    func set(_ anObject: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: SyncedKeyValueStore {}

/// Mirrors the handful of device-WIDE, account-portable config values through
/// iCloud Key-Value Storage, so a value pasted on one device reaches all of the
/// user's others (Levi's directive: "all agent and server config should sync via
/// icloud" — this bit for real when a phone had no control-plane config the Mac
/// had held for weeks).
///
/// UserDefaults stays the store every read path consults — this type only moves
/// values between the local defaults and the iCloud KVS replica at three
/// well-defined moments: setter push, launch pull, and external-change pull.
/// Reads never touch KVS, so call sites keep their exact pre-sync semantics and
/// cost, and a device that loses iCloud keeps working from its local cache.
///
/// What syncs HERE is non-secret scalars only: the control-plane endpoint URL and
/// the supervision enabled flag. Everything else is deliberate:
/// - Secrets (the control-plane bearer token) ride the iCloud-synchronizable
///   keychain (`KeychainStore.saveDeviceSecret`) — end-to-end encrypted and
///   scoped to the user's signed-in devices — never KVS, which is plaintext to
///   the server.
/// - Presigned capability URLs (`CloudAgentConfig`, the supervision
///   directive/status URLs) sync NOWHERE: each device re-vends its own through
///   `POST /presign` the moment the synced control-plane pair lands, and a grant
///   dies within the hour anyway — syncing one would be pointless where it
///   matters and widen the blast radius where it doesn't.
/// - Machine-scoped files stay machine-scoped by design: the session-routing
///   registry (`RoutingRegistryLocation`) and the daemon's goals ledger name
///   tmux sessions that exist on exactly one host — syncing them would teach
///   other devices to route work into sessions they cannot reach.
/// - Telemetry opt-ins stay device-local (`FeedbackSettings`): consent to send
///   data off THIS device is a per-device decision, the privacy stance of the
///   feedback work.
enum SyncedDeviceConfig {
    /// Every synced key, in one place, so the launch pull, the external-change
    /// pull, and the setter pushes can never disagree about what syncs.
    static let stringKeys: [String] = [CloudControlPlaneConfig.endpointURLKey]
    static let boolKeys: [String] = [RemoteSupervisionConfig.enabledKey]

    /// The live KVS replica, or nil when iCloud KVS is unavailable to this
    /// process (unsigned test host, missing entitlement, iCloud-less CI):
    /// `synchronize()` is documented to return false exactly then, and everything
    /// here degrades to local-only silently — a device without iCloud still
    /// configures by hand, same as before sync existed.
    static var availableStore: SyncedKeyValueStore? {
        isAvailable ? NSUbiquitousKeyValueStore.default : nil
    }
    private static let isAvailable: Bool = NSUbiquitousKeyValueStore.default.synchronize()

    private static var observer: NSObjectProtocol?

    /// Setter-side half: mirror a just-written local value into the synced store.
    /// KVS writes land in the local replica immediately (iCloud upload is
    /// background), so a fresh local edit is never at risk from the next pull.
    static func push(
        _ value: Any?, forKey key: String, kvs: SyncedKeyValueStore? = availableStore
    ) {
        kvs?.set(value, forKey: key)
    }

    /// Pull-and-promote pass, run at launch and on every external KVS change.
    /// Returns the keys whose LOCAL value changed, so the caller can post the
    /// matching domain notifications.
    ///
    /// THE migration rule (one-way promotion): a synced value that exists always
    /// wins — it is the user's most recent cross-device intent, and any local
    /// edit reaches the replica synchronously in its setter, so a genuinely newer
    /// local value can never lose here. A key absent from the synced store but
    /// present locally is promoted INTO it (how a pre-sync device's config seeds
    /// the account); the reverse — a local value clobbering a non-empty synced
    /// one — never happens.
    @discardableResult
    static func pull(
        defaults: UserDefaults = .standard, kvs: SyncedKeyValueStore? = availableStore
    ) -> Set<String> {
        guard let kvs else { return [] }
        var changedLocally: Set<String> = []
        for key in stringKeys {
            let synced = kvs.string(forKey: key) ?? ""
            let local = defaults.string(forKey: key) ?? ""
            if !synced.isEmpty {
                if synced != local {
                    defaults.set(synced, forKey: key)
                    changedLocally.insert(key)
                }
            } else if !local.isEmpty {
                kvs.set(local, forKey: key)
            }
        }
        for key in boolKeys {
            let synced = kvs.object(forKey: key) as? Bool
            let local = defaults.object(forKey: key) as? Bool
            if let synced {
                if synced != local {
                    defaults.set(synced, forKey: key)
                    changedLocally.insert(key)
                }
            } else if let local {
                // Presence is the bool analogue of non-empty: an explicit local
                // OFF is a decision worth seeding the account with, same as ON.
                kvs.set(local, forKey: key)
            }
        }
        return changedLocally
    }

    /// Launch-time wiring: one pull now (call AFTER any Info.plist seeding, so a
    /// stamped build's seed can promote to the account), then a pull per external
    /// change — which is what makes a value pasted on the Mac appear on the phone
    /// without a relaunch. Idempotent; a no-op when KVS is unavailable.
    @MainActor
    static func activate() {
        guard availableStore != nil, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            // The userInfo's changed-keys list could narrow this, but the synced
            // key set is tiny and the pass idempotent — re-running it whole keeps
            // one code path for launch and live change.
            postDomainNotifications(for: pull())
        }
        postDomainNotifications(for: pull())
    }

    /// Domain notifications for freshly pulled values, so live machinery reacts
    /// without polling: a changed enabled flag must start/stop the directive
    /// channel, and a control-plane endpoint arriving is exactly the moment an
    /// enabled-but-unconfigured channel can begin vending its own supervision
    /// URLs — the supervision changed notification pokes it awake in both cases
    /// (its handler is cheap and idempotent for a URL that didn't change).
    private static func postDomainNotifications(for changed: Set<String>) {
        guard !changed.isEmpty else { return }
        if changed.contains(CloudControlPlaneConfig.endpointURLKey) {
            NotificationCenter.default.post(
                name: CloudControlPlaneConfig.changedNotification, object: nil
            )
        }
        NotificationCenter.default.post(
            name: RemoteSupervisionConfig.changedNotification, object: nil
        )
    }
}
