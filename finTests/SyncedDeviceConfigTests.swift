import XCTest
@testable import fin

/// Dictionary-backed stand-in for the iCloud KVS replica, so the migration rule
/// runs against controlled state instead of the live (entitlement-gated) store.
private final class FakeSyncedStore: SyncedKeyValueStore {
    var storage: [String: Any] = [:]

    func string(forKey key: String) -> String? { storage[key] as? String }
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ anObject: Any?, forKey key: String) {
        if let anObject {
            storage[key] = anObject
        } else {
            storage.removeValue(forKey: key)
        }
    }
    func synchronize() -> Bool { true }
}

/// The device-config sync rules: one-way promotion of legacy local values into an
/// empty synced slot, a non-empty synced value never clobbered by a local one,
/// the token's synchronizable-keychain round trip, and silent local-only
/// degradation when the synced stores are unavailable (CI, unsigned test host).
final class SyncedDeviceConfigTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var kvs: FakeSyncedStore!

    private let endpointKey = CloudControlPlaneConfig.endpointURLKey
    private let enabledKey = RemoteSupervisionConfig.enabledKey

    override func setUp() {
        super.setUp()
        suiteName = "synced-config-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        kvs = FakeSyncedStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Promotion (migration)

    func testPullPromotesLegacyLocalValueIntoEmptySyncedStore() {
        defaults.set("https://cp.example.com/prod", forKey: endpointKey)

        let changed = SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)

        XCTAssertEqual(kvs.string(forKey: endpointKey), "https://cp.example.com/prod")
        // Promotion is a synced-side write only; the local value it came from is
        // already right, so nothing changed locally and no notification is owed.
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(defaults.string(forKey: endpointKey), "https://cp.example.com/prod")
    }

    func testPullPromotesExplicitLocalBoolIncludingFalse() {
        // Presence is the bool analogue of non-empty: an explicit OFF is a
        // decision worth seeding the account with.
        defaults.set(false, forKey: enabledKey)

        SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)

        XCTAssertEqual(kvs.object(forKey: enabledKey) as? Bool, false)
    }

    func testPullWithNothingAnywhereWritesNothing() {
        let changed = SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)

        XCTAssertTrue(changed.isEmpty)
        XCTAssertTrue(kvs.storage.isEmpty)
        XCTAssertNil(defaults.string(forKey: endpointKey))
        XCTAssertNil(defaults.object(forKey: enabledKey))
    }

    // MARK: - Non-empty synced always wins

    func testPullNeverClobbersNonEmptySyncedValueWithLocalOne() {
        kvs.set("https://synced.example.com/prod", forKey: endpointKey)
        defaults.set("https://stale-local.example.com", forKey: endpointKey)

        let changed = SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)

        // Synced side untouched; local side adopted it (and reported the change
        // so domain notifications fire).
        XCTAssertEqual(kvs.string(forKey: endpointKey), "https://synced.example.com/prod")
        XCTAssertEqual(defaults.string(forKey: endpointKey), "https://synced.example.com/prod")
        XCTAssertEqual(changed, [endpointKey])
    }

    func testPullAdoptsSyncedBoolOverLocalInBothDirections() {
        kvs.set(false, forKey: enabledKey)
        defaults.set(true, forKey: enabledKey)

        var changed = SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)
        XCTAssertEqual(defaults.bool(forKey: enabledKey), false)
        XCTAssertEqual(changed, [enabledKey])

        kvs.set(true, forKey: enabledKey)
        changed = SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs)
        XCTAssertEqual(defaults.bool(forKey: enabledKey), true)
        XCTAssertEqual(changed, [enabledKey])
    }

    func testPullAgreementReportsNoChange() {
        kvs.set("https://cp.example.com/prod", forKey: endpointKey)
        defaults.set("https://cp.example.com/prod", forKey: endpointKey)

        XCTAssertTrue(SyncedDeviceConfig.pull(defaults: defaults, kvs: kvs).isEmpty)
    }

    // MARK: - Degraded mode (no KVS)

    func testPullAndPushAreInertWithoutASyncedStore() {
        defaults.set("https://cp.example.com/prod", forKey: endpointKey)

        // nil is exactly what `availableStore` resolves to when synchronize()
        // reports the entitlement/iCloud absent — everything must no-op locally.
        XCTAssertTrue(SyncedDeviceConfig.pull(defaults: defaults, kvs: nil).isEmpty)
        SyncedDeviceConfig.push("https://other.example.com", forKey: endpointKey, kvs: nil)

        XCTAssertEqual(defaults.string(forKey: endpointKey), "https://cp.example.com/prod")
    }

    func testPushMirrorsValueIntoSyncedStore() {
        SyncedDeviceConfig.push(true, forKey: enabledKey, kvs: kvs)
        SyncedDeviceConfig.push("https://cp.example.com/prod", forKey: endpointKey, kvs: kvs)

        XCTAssertEqual(kvs.object(forKey: enabledKey) as? Bool, true)
        XCTAssertEqual(kvs.string(forKey: endpointKey), "https://cp.example.com/prod")
    }

    // MARK: - Token (synchronizable keychain)

    /// Keychain-touching tests skip on macOS for the reason KeychainStoreTests
    /// documents: the unsigned test host can't write keychain items
    /// (errSecInteractionNotAllowed). The token path is exercised on iOS; on
    /// macOS hosts the code degrades to the UserDefaults fallback by design.
    private func skipUnlessKeychainWritable() throws {
        #if os(macOS)
        throw XCTSkip("Keychain writes require the signed app host; covered on iOS.")
        #endif
    }

    func testTokenRoundTripsThroughSynchronizableKeychain() throws {
        try skipUnlessKeychainWritable()
        defer {
            KeychainStore.deleteDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey)
            UserDefaults.standard.removeObject(forKey: CloudControlPlaneConfig.tokenKey)
        }

        CloudControlPlaneConfig.setToken("cp-secret-1234")
        XCTAssertEqual(CloudControlPlaneConfig.token, "cp-secret-1234")
        // The keychain owns it: no plaintext copy may linger in defaults.
        XCTAssertNil(UserDefaults.standard.string(forKey: CloudControlPlaneConfig.tokenKey))

        // Clearing the field deletes the item (account-wide via keychain sync).
        CloudControlPlaneConfig.setToken("")
        XCTAssertEqual(CloudControlPlaneConfig.token, "")
        XCTAssertNil(KeychainStore.loadDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey))
    }

    func testTokenPromotesLegacyDefaultsValueIntoKeychainOnFirstRead() throws {
        try skipUnlessKeychainWritable()
        defer {
            KeychainStore.deleteDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey)
            UserDefaults.standard.removeObject(forKey: CloudControlPlaneConfig.tokenKey)
        }
        KeychainStore.deleteDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey)
        UserDefaults.standard.set("legacy-token", forKey: CloudControlPlaneConfig.tokenKey)

        XCTAssertEqual(CloudControlPlaneConfig.token, "legacy-token")

        // Promoted: the keychain holds it now and the plaintext copy is gone.
        XCTAssertEqual(
            KeychainStore.loadDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey),
            "legacy-token"
        )
        XCTAssertNil(UserDefaults.standard.string(forKey: CloudControlPlaneConfig.tokenKey))
    }

    func testTokenNeverClobbersNonEmptyKeychainValueWithLegacyLocalOne() throws {
        try skipUnlessKeychainWritable()
        defer {
            KeychainStore.deleteDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey)
            UserDefaults.standard.removeObject(forKey: CloudControlPlaneConfig.tokenKey)
        }
        try KeychainStore.saveDeviceSecret("synced-token", forKey: CloudControlPlaneConfig.tokenKey)
        UserDefaults.standard.set("stale-local-token", forKey: CloudControlPlaneConfig.tokenKey)

        // The synced value wins outright; the legacy value is never promoted
        // over it, and the losing plaintext copy is retired from defaults.
        XCTAssertEqual(CloudControlPlaneConfig.token, "synced-token")
        XCTAssertEqual(
            KeychainStore.loadDeviceSecret(forKey: CloudControlPlaneConfig.tokenKey),
            "synced-token"
        )
        XCTAssertNil(UserDefaults.standard.string(forKey: CloudControlPlaneConfig.tokenKey))
    }
}
