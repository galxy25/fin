import Foundation
import Security

enum KeychainStore {
    private static let keyService = "dev.levischoen.fin.privatekey"
    private static let passphraseService = "dev.levischoen.fin.passphrase"
    private static let agentAPIKeyService = "dev.levischoen.fin.agentapikey"
    private static let deviceConfigService = "dev.levischoen.fin.deviceconfig"

    enum KeychainError: Error {
        case unhandled(OSStatus)
    }

    static func savePrivateKey(_ data: Data, for keyID: UUID) throws {
        try save(data, service: keyService, account: keyID.uuidString)
    }

    static func loadPrivateKey(for keyID: UUID) -> Data? {
        load(service: keyService, account: keyID.uuidString)
    }

    static func savePassphrase(_ passphrase: Data, for keyID: UUID) throws {
        try save(passphrase, service: passphraseService, account: keyID.uuidString)
    }

    static func loadPassphrase(for keyID: UUID) -> Data? {
        load(service: passphraseService, account: keyID.uuidString)
    }

    static func deleteKeyMaterial(for keyID: UUID) {
        delete(service: keyService, account: keyID.uuidString)
        delete(service: passphraseService, account: keyID.uuidString)
    }

    /// Agent endpoint bearer tokens. Kept out of SwiftData (which mirrors to CloudKit
    /// in plaintext) for the same reason private keys are. Local endpoints like
    /// LM Studio are typically keyless, so this is legitimately empty for most agents.
    static func saveAgentAPIKey(_ key: String, for agentID: UUID) throws {
        guard let data = key.data(using: .utf8), !key.isEmpty else {
            delete(service: agentAPIKeyService, account: agentID.uuidString)
            return
        }
        try save(data, service: agentAPIKeyService, account: agentID.uuidString)
    }

    static func loadAgentAPIKey(for agentID: UUID) -> String? {
        guard let data = load(service: agentAPIKeyService, account: agentID.uuidString),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    static func deleteAgentAPIKey(for agentID: UUID) {
        delete(service: agentAPIKeyService, account: agentID.uuidString)
    }

    /// Device-WIDE synced secrets (today: the control-plane bearer token), keyed
    /// by the same defaults key the value once lived under so call sites keep one
    /// name per value. Synchronizable like the private keys, but
    /// `AfterFirstUnlock`: this credential backs refresh paths that can fire
    /// before the first unlock after a reboot (presign re-vends on early launch),
    /// and it protects a remote capability, not local data at rest — the weaker
    /// accessibility is the correct trade here. An empty value deletes, mirroring
    /// `saveAgentAPIKey`, so clearing the field on one device clears the account.
    static func saveDeviceSecret(_ value: String, forKey key: String) throws {
        guard !value.isEmpty else {
            delete(service: deviceConfigService, account: key)
            return
        }
        try save(
            Data(value.utf8), service: deviceConfigService, account: key,
            accessible: kSecAttrAccessibleAfterFirstUnlock
        )
    }

    static func loadDeviceSecret(forKey key: String) -> String? {
        guard let data = load(service: deviceConfigService, account: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func deleteDeviceSecret(forKey key: String) {
        delete(service: deviceConfigService, account: key)
    }

    // `WhenUnlocked` (not `...ThisDeviceOnly`) plus `kSecAttrSynchronizable` is what makes
    // an item eligible for iCloud Keychain sync, so private keys follow the server list
    // they belong to onto every device signed into the same iCloud account.
    private static func save(
        _ data: Data, service: String, account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlocked
    ) throws {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    private static func load(service: String, account: String) -> Data? {
        if let data = load(service: service, account: account, synchronizable: true) {
            return data
        }
        // Falls back to (and migrates forward) a pre-sync, device-only item saved by an
        // earlier build, so upgrading doesn't strand keys that were already imported.
        guard let legacyData = load(service: service, account: account, synchronizable: false) else {
            return nil
        }
        try? save(legacyData, service: service, account: account)
        return legacyData
    }

    private static func load(service: String, account: String, synchronizable: Bool) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func delete(service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var synced = base
        synced[kSecAttrSynchronizable as String] = true
        var local = base
        local[kSecAttrSynchronizable as String] = false
        let syncedStatus = SecItemDelete(synced as CFDictionary)
        let localStatus = SecItemDelete(local as CFDictionary)
        return (syncedStatus == errSecSuccess || syncedStatus == errSecItemNotFound)
            && (localStatus == errSecSuccess || localStatus == errSecItemNotFound)
    }
}
