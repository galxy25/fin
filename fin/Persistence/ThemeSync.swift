import Foundation

/// Optional cross-device sync for the terminal and markdown themes, through the
/// same iCloud Key-Value Storage replica `SyncedDeviceConfig` uses.
///
/// Each scope has its own per-device switch (`ThemeScope.syncEnabledKey`, never
/// synced itself): on, the scope's colors and font size follow the account; off,
/// this device keeps its own theme and ignores the account's. As with
/// `SyncedDeviceConfig`, UserDefaults stays the only store views read
/// (`@AppStorage`) — this type just moves values between it and KVS.
enum ThemeSync {
    private static var observers: [NSObjectProtocol] = []
    private static var wasEnabled: [ThemeScope: Bool] = [:]

    static func isEnabled(_ scope: ThemeScope, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: scope.syncEnabledKey)
    }

    /// Account → device. Per key, a synced value wins (it's the latest
    /// cross-device edit); a key the account doesn't have yet is seeded from this
    /// device. So the first device to turn sync on publishes its theme, and each
    /// later one adopts it.
    static func pull(
        _ scope: ThemeScope,
        defaults: UserDefaults = .standard,
        kvs: SyncedKeyValueStore? = SyncedDeviceConfig.availableStore
    ) {
        guard let kvs else { return }
        for key in scope.syncedKeys {
            let local = defaults.object(forKey: key)
            if let synced = kvs.object(forKey: key) {
                if !isEqual(synced, local) { defaults.set(synced, forKey: key) }
            } else if let local {
                kvs.set(local, forKey: key)
            }
        }
    }

    /// Device → account: mirror any local edit. A no-op when nothing differs,
    /// which is what keeps a pull's own defaults writes from echoing back.
    static func push(
        _ scope: ThemeScope,
        defaults: UserDefaults = .standard,
        kvs: SyncedKeyValueStore? = SyncedDeviceConfig.availableStore
    ) {
        guard let kvs else { return }
        for key in scope.syncedKeys {
            guard let local = defaults.object(forKey: key) else { continue }
            if !isEqual(local, kvs.object(forKey: key)) { kvs.set(local, forKey: key) }
        }
    }

    /// Launch-time wiring, after `SyncedDeviceConfig.activate()`. Idempotent; a
    /// no-op when KVS is unavailable.
    @MainActor
    static func activate() {
        guard SyncedDeviceConfig.availableStore != nil, observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            for scope in ThemeScope.allCases where isEnabled(scope) { pull(scope) }
        })
        // Covers every theme edit (they're all @AppStorage writes) and the sync
        // switch itself, without each view having to call in.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            for scope in ThemeScope.allCases { defaultsChanged(scope) }
        })
        for scope in ThemeScope.allCases { defaultsChanged(scope) }
    }

    /// A switch that just turned on PULLS — adopting the account's theme, or
    /// seeding it if the account has none — rather than pushing, so turning sync
    /// on never overwrites the other devices with this one's local theme.
    static func defaultsChanged(
        _ scope: ThemeScope,
        defaults: UserDefaults = .standard,
        kvs: SyncedKeyValueStore? = SyncedDeviceConfig.availableStore
    ) {
        let enabled = isEnabled(scope, defaults: defaults)
        let justEnabled = enabled && wasEnabled[scope] != true
        wasEnabled[scope] = enabled
        if justEnabled {
            pull(scope, defaults: defaults, kvs: kvs)
        } else if enabled {
            push(scope, defaults: defaults, kvs: kvs)
        }
    }

    /// Test seam: forget which switches were on.
    static func resetTracking() { wasEnabled = [:] }

    private static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a as NSObject, b as NSObject): a.isEqual(b)
        default: false
        }
    }
}
