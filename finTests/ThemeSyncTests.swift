import XCTest
@testable import fin

private final class FakeThemeStore: SyncedKeyValueStore {
    var storage: [String: Any] = [:]

    func string(forKey key: String) -> String? { storage[key] as? String }
    func object(forKey key: String) -> Any? { storage[key] }
    func set(_ anObject: Any?, forKey key: String) { storage[key] = anObject }
    func synchronize() -> Bool { true }
}

/// The theme sync rules: off means fully device-local, turning on adopts the
/// account's theme (or seeds it), edits while on reach the account, and the
/// two scopes sync independently.
final class ThemeSyncTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var kvs: FakeThemeStore!

    override func setUp() {
        super.setUp()
        suiteName = "theme-sync-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        kvs = FakeThemeStore()
        ThemeSync.resetTracking()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        ThemeSync.resetTracking()
        super.tearDown()
    }

    private func changed(_ scope: ThemeScope) {
        ThemeSync.defaultsChanged(scope, defaults: defaults, kvs: kvs)
    }

    func testSyncOffNeverTouchesTheAccount() {
        defaults.set("#112233", forKey: ThemeScope.terminal.backgroundKey)
        changed(.terminal)
        XCTAssertTrue(kvs.storage.isEmpty)
    }

    func testTurningOnAdoptsTheAccountThemeInsteadOfOverwritingIt() {
        kvs.storage[ThemeScope.terminal.backgroundKey] = "#AABBCC"
        kvs.storage[ThemeScope.terminal.fontSizeKey] = 18.0
        defaults.set("#112233", forKey: ThemeScope.terminal.backgroundKey)
        defaults.set(14.0, forKey: ThemeScope.terminal.fontSizeKey)

        defaults.set(true, forKey: ThemeScope.terminal.syncEnabledKey)
        changed(.terminal)

        XCTAssertEqual(defaults.string(forKey: ThemeScope.terminal.backgroundKey), "#AABBCC")
        XCTAssertEqual(defaults.double(forKey: ThemeScope.terminal.fontSizeKey), 18)
        XCTAssertEqual(kvs.storage[ThemeScope.terminal.backgroundKey] as? String, "#AABBCC")
    }

    func testTurningOnSeedsAnEmptyAccount() {
        defaults.set("#112233", forKey: ThemeScope.terminal.backgroundKey)
        defaults.set(true, forKey: ThemeScope.terminal.syncEnabledKey)
        changed(.terminal)
        XCTAssertEqual(kvs.storage[ThemeScope.terminal.backgroundKey] as? String, "#112233")
    }

    func testEditsWhileOnReachTheAccount() {
        defaults.set(true, forKey: ThemeScope.terminal.syncEnabledKey)
        changed(.terminal)
        defaults.set(20.0, forKey: ThemeScope.terminal.fontSizeKey)
        changed(.terminal)
        XCTAssertEqual(kvs.storage[ThemeScope.terminal.fontSizeKey] as? Double, 20)
    }

    func testScopesSyncIndependently() {
        defaults.set(true, forKey: ThemeScope.markdown.syncEnabledKey)
        changed(.markdown)
        changed(.terminal)
        defaults.set(22.0, forKey: ThemeScope.markdown.fontSizeKey)
        defaults.set(9.0, forKey: ThemeScope.terminal.fontSizeKey)
        changed(.markdown)
        changed(.terminal)
        XCTAssertEqual(kvs.storage[ThemeScope.markdown.fontSizeKey] as? Double, 22)
        XCTAssertNil(kvs.storage[ThemeScope.terminal.fontSizeKey])
    }
}
