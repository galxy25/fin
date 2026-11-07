import Foundation
import Security

/// docs/XANADU.md "Share extension (v1.1)": the state the app and the
/// `fin-share` extension both read. Compiled into BOTH targets (project.yml),
/// so it is Foundation/Security only and never names an app-module type.
///
/// Two stores, by what each value is:
/// - The App Group's defaults (`group.dev.levischoen.fin`) hold the
///   non-secret values: the control-plane endpoint, the primary agent's name,
///   this install's device id, and Xanadu's current thread per agent
///   (`XanaduCurrentThread`).
/// - The shared keychain access group (`<prefix>dev.levischoen.fin.shared`,
///   named in Info.plist as `FinSharedKeychainGroup`) holds the bearer token —
///   a device-only, never-synchronized COPY. The app's own synced item stays
///   exactly where it always was, so nothing here can sign anyone out: the
///   mirror is one-way, app → group, and the extension only ever reads it.
enum FinAppGroup {
    static let identifier = "group.dev.levischoen.fin"

    /// True inside an app extension's process (the share sheet), where the
    /// app-only migrations must never run.
    static let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"

    /// The group's defaults, or nil when this process has no group container
    /// (an un-entitled build) or is the unit-test host — callers then keep
    /// using their pre-group store, which is exactly the pre-group behaviour.
    static let defaults: UserDefaults? = {
        guard !TestHost.isUnitTest,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
        else { return nil }
        return UserDefaults(suiteName: identifier)
    }()

    /// The full keychain access group (team prefix included), from Info.plist.
    /// nil when the build did not resolve `$(AppIdentifierPrefix)` (unsigned).
    static var keychainGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "FinSharedKeychainGroup") as? String ?? ""
        return validKeychainGroup(value)
    }

    /// Pure: a resolved group looks like `TEAMID.dev.levischoen.fin.shared` —
    /// a prefix, then the suffix — never an unexpanded `$(…)` or a bare suffix.
    static func validKeychainGroup(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".dev.levischoen.fin.shared"
        guard trimmed.hasSuffix(suffix), trimmed.count > suffix.count, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

/// The device-only token copy in the shared keychain access group. Never
/// synchronizable (each device mirrors its own), `AfterFirstUnlock` (a share
/// can happen any time the phone is unlocked once), data-protection keychain
/// (required on macOS for access groups; the default on iOS).
enum FinSharedKeychain {
    static let service = "dev.levischoen.fin.share"

    private static func base(account: String, group: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func load(account: String, group: String? = FinAppGroup.keychainGroup) -> String? {
        guard let group else { return nil }
        var query = base(account: account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    /// An empty value deletes. Returns whether the keychain now holds `value`.
    @discardableResult
    static func save(_ value: String, account: String, group: String? = FinAppGroup.keychainGroup) -> Bool {
        guard let group else { return false }
        let query = base(account: account, group: group)
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// What the app hands the share extension, and the one rule for writing it.
enum FinShareMirror {
    enum Key {
        static let endpointURL = "share.endpointURL"
        static let agentName = "share.primaryAgentName"
        static let deviceID8 = "share.deviceID8"
        static let tokenAccount = "fin.cloudcp.token"
    }

    struct Snapshot: Equatable {
        var endpointURL: String
        var token: String
        /// nil = unknown right now (agents not synced in yet): keep what the
        /// group already has rather than erase a good value.
        var agentName: String?
        var deviceID8: String

        var isUsable: Bool {
            !endpointURL.isEmpty && !token.isEmpty && !(agentName ?? "").isEmpty
        }
    }

    /// The two stores as closures, so the write rule is tested against a
    /// dictionary instead of the live group and keychain.
    struct Store {
        var string: (String) -> String?
        var setString: (String?, String) -> Void
        var secret: () -> String?
        var setSecret: (String) -> Void

        static var live: Store? {
            guard let defaults = FinAppGroup.defaults else { return nil }
            return Store(
                string: { defaults.string(forKey: $0) },
                setString: { value, key in
                    if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                },
                secret: { FinSharedKeychain.load(account: Key.tokenAccount) },
                setSecret: { FinSharedKeychain.save($0, account: Key.tokenAccount) }
            )
        }
    }

    /// Write only what changed; returns the keys written. A signed-out app
    /// (empty token / endpoint) clears the copies, so the share sheet signs out
    /// with it. An unknown agent name never erases a known one.
    @discardableResult
    static func write(_ snapshot: Snapshot, to store: Store) -> Set<String> {
        var changed: Set<String> = []
        func put(_ value: String?, _ key: String) {
            let next = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = next?.isEmpty == false ? next : nil
            guard store.string(key) != normalized else { return }
            store.setString(normalized, key)
            changed.insert(key)
        }
        put(snapshot.endpointURL, Key.endpointURL)
        put(snapshot.deviceID8, Key.deviceID8)
        if let agent = snapshot.agentName { put(agent, Key.agentName) }
        if (store.secret() ?? "") != snapshot.token {
            store.setSecret(snapshot.token)
            changed.insert(Key.tokenAccount)
        }
        return changed
    }

    /// The extension's read: whatever the app last mirrored.
    static func read(from store: Store?) -> Snapshot? {
        guard let store else { return nil }
        return Snapshot(
            endpointURL: store.string(Key.endpointURL) ?? "",
            token: store.secret() ?? "",
            agentName: store.string(Key.agentName),
            deviceID8: store.string(Key.deviceID8) ?? ""
        )
    }
}
