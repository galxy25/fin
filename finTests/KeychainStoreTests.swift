import XCTest
@testable import fin

final class KeychainStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrips() throws {
        let keyID = UUID()
        defer { KeychainStore.deleteKeyMaterial(for: keyID) }
        let data = Data("test-key-material".utf8)
        try KeychainStore.savePrivateKey(data, for: keyID)
        XCTAssertEqual(KeychainStore.loadPrivateKey(for: keyID), data)
    }

    func testOverwriteReplacesPreviousValue() throws {
        let keyID = UUID()
        defer { KeychainStore.deleteKeyMaterial(for: keyID) }
        try KeychainStore.savePrivateKey(Data("first".utf8), for: keyID)
        try KeychainStore.savePrivateKey(Data("second".utf8), for: keyID)
        XCTAssertEqual(KeychainStore.loadPrivateKey(for: keyID), Data("second".utf8))
    }

    func testDeleteRemovesValue() throws {
        let keyID = UUID()
        try KeychainStore.savePrivateKey(Data("to-delete".utf8), for: keyID)
        KeychainStore.deleteKeyMaterial(for: keyID)
        XCTAssertNil(KeychainStore.loadPrivateKey(for: keyID))
    }

    func testMigratesLegacyDeviceOnlyItemForward() throws {
        let keyID = UUID()
        defer { KeychainStore.deleteKeyMaterial(for: keyID) }
        // Simulate an item saved by a pre-sync build: WhenUnlockedThisDeviceOnly, not synchronizable.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.levischoen.fin.privatekey",
            kSecAttrAccount as String: keyID.uuidString,
            kSecValueData as String: Data("legacy".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemAdd(legacyQuery as CFDictionary, nil)

        XCTAssertEqual(KeychainStore.loadPrivateKey(for: keyID), Data("legacy".utf8))
    }
}
