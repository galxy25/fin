import Foundation
import Security

enum KeychainStore {
    private static let keyService = "dev.levischoen.fin.privatekey"
    private static let passphraseService = "dev.levischoen.fin.passphrase"

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

    // `WhenUnlocked` (not `...ThisDeviceOnly`) plus `kSecAttrSynchronizable` is what makes
    // an item eligible for iCloud Keychain sync, so private keys follow the server list
    // they belong to onto every device signed into the same iCloud account.
    private static func save(_ data: Data, service: String, account: String) throws {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
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
