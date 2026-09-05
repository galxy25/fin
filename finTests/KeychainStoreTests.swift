import XCTest
@testable import fin

final class KeychainStoreTests: XCTestCase {

    /// The iCloud-synchronizable keychain items this covers can't be written from the
    /// macOS unit-test host — `SecItemAdd` returns errSecInteractionNotAllowed (-25308)
    /// because the test runner isn't the signed, entitled app. The code under test is
    /// platform-independent and is exercised on iOS, so this skips rather than fails and
    /// leaves a permanently red macOS suite.
    override func setUpWithError() throws {
        #if os(macOS)
        throw XCTSkip("Keychain writes require the signed app host; covered on iOS.")
        #endif
    }

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

    /// Fin's Key depends on the private key reaching every device through
    /// iCloud Keychain, so assert the saved item really carries the
    /// synchronizable attribute rather than trusting the save path's constant.
    /// (Runs only where the entitled app host exists — the macOS skip above is
    /// also the guard for environments without iCloud Keychain.)
    func testSavedPrivateKeyItemIsFlaggedSynchronizable() throws {
        let keyID = UUID()
        defer { KeychainStore.deleteKeyMaterial(for: keyID) }
        try KeychainStore.savePrivateKey(Data("sync-check".utf8), for: keyID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.levischoen.fin.privatekey",
            kSecAttrAccount as String: keyID.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Int, 1)
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
