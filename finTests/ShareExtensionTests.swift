import XCTest
import UniformTypeIdentifiers
@testable import fin

/// docs/XANADU.md "Share extension (v1.1)": the pure parts fin-share shares
/// with the app — routing a shared item, naming its file, composing the
/// message text — plus the App Group mirror's write rule and the one-time
/// current-thread migration. No group container, no keychain, no network.
final class ShareExtensionTests: XCTestCase {
    // MARK: - Item → attachment mapping

    func testRouteContentBeatsLinksAndText() {
        XCTAssertEqual(ShareIntake.route(for: ["public.heic", "public.url"]), .file("public.heic"))
        XCTAssertEqual(ShareIntake.route(for: ["public.jpeg"]), .file("public.jpeg"))
        XCTAssertEqual(ShareIntake.route(for: ["com.apple.quicktime-movie"]), .file("com.apple.quicktime-movie"))
        XCTAssertEqual(ShareIntake.route(for: ["com.apple.m4a-audio"]), .file("com.apple.m4a-audio"))
        XCTAssertEqual(ShareIntake.route(for: ["com.adobe.pdf", "public.file-url"]), .file("com.adobe.pdf"))
        XCTAssertEqual(ShareIntake.route(for: ["org.openxmlformats.spreadsheetml.sheet"]),
                       .file("org.openxmlformats.spreadsheetml.sheet"))
    }

    func testRouteFileURLLinkAndText() {
        // A .txt from Files: text-typed, but handed over by URL → the file.
        XCTAssertEqual(ShareIntake.route(for: ["public.plain-text", "public.file-url"]), .fileURL)
        XCTAssertEqual(ShareIntake.route(for: ["public.url", "public.plain-text"]), .webURL)
        XCTAssertEqual(ShareIntake.route(for: ["public.plain-text"]), .text)
        XCTAssertNil(ShareIntake.route(for: []))
        XCTAssertNil(ShareIntake.route(for: ["not.a.registered.type.zzz"]))
    }

    func testFileNamePrefersSuggestedAndAddsExtension() {
        XCTAssertEqual(ShareIntake.fileName(suggested: "IMG_1234", loadedName: "x.tmp", typeIdentifier: "public.heic", index: 0),
                       "IMG_1234.heic")
        XCTAssertEqual(ShareIntake.fileName(suggested: "Q3 costs.xlsx", loadedName: nil,
                                            typeIdentifier: "org.openxmlformats.spreadsheetml.sheet", index: 0),
                       "Q3 costs.xlsx")
        XCTAssertEqual(ShareIntake.fileName(suggested: "  ", loadedName: "report.pdf", typeIdentifier: "com.adobe.pdf", index: 2),
                       "report.pdf")
        XCTAssertEqual(ShareIntake.fileName(suggested: nil, loadedName: nil, typeIdentifier: "public.jpeg", index: 2),
                       "shared-3.jpeg")
        XCTAssertEqual(ShareIntake.fileName(suggested: nil, loadedName: nil, typeIdentifier: nil, index: 0), "shared-1")
    }

    func testMessageTextJoinsNoteLinksAndText() {
        let parts = ShareIntake.messageText(note: " give me a breakdown of cost by quarter ",
                                            urls: ["https://example.com/a"], texts: ["  some text "])
        XCTAssertEqual(parts.text, "give me a breakdown of cost by quarter\n\nhttps://example.com/a\n\nsome text")
        XCTAssertNil(parts.overflow)
        XCTAssertEqual(ShareIntake.messageText(note: "", urls: [], texts: []).text, "")
    }

    func testLongSharedTextOverflowsIntoAFile() {
        let long = String(repeating: "a", count: 50)
        let parts = ShareIntake.messageText(note: "note", urls: ["https://x.y"], texts: [long], limit: 40)
        XCTAssertEqual(parts.text, "note\n\nhttps://x.y")
        XCTAssertEqual(parts.overflow, long)
    }

    func testTextLimitMatchesTheAppsCap() {
        XCTAssertEqual(ShareIntake.messageTextLimit, CloudAgentChannel.maxTextLength)
    }

    func testKeychainGroupMustBeResolved() {
        XCTAssertEqual(FinAppGroup.validKeychainGroup("EC27UF79GL.dev.levischoen.fin.shared"), "EC27UF79GL.dev.levischoen.fin.shared")
        XCTAssertNil(FinAppGroup.validKeychainGroup("$(AppIdentifierPrefix)dev.levischoen.fin.shared"))
        XCTAssertNil(FinAppGroup.validKeychainGroup("dev.levischoen.fin.shared"))
        XCTAssertNil(FinAppGroup.validKeychainGroup(""))
    }

    // MARK: - Group mirror

    private final class Fake {
        var strings: [String: String] = [:]
        var secret: String?
        var secretWrites = 0
        var store: FinShareMirror.Store {
            FinShareMirror.Store(
                string: { self.strings[$0] },
                setString: { value, key in self.strings[key] = value },
                secret: { self.secret },
                setSecret: { self.secret = $0.isEmpty ? nil : $0; self.secretWrites += 1 }
            )
        }
    }

    func testMirrorWritesAndReadsBack() {
        let fake = Fake()
        let snapshot = FinShareMirror.Snapshot(endpointURL: "https://cp.example", token: "tok", agentName: "Fin", deviceID8: "abcd1234")
        let changed = FinShareMirror.write(snapshot, to: fake.store)
        XCTAssertEqual(changed.count, 4)
        XCTAssertEqual(FinShareMirror.read(from: fake.store), snapshot)
        XCTAssertTrue(snapshot.isUsable)
        // Idempotent: nothing rewritten, the keychain untouched.
        XCTAssertTrue(FinShareMirror.write(snapshot, to: fake.store).isEmpty)
        XCTAssertEqual(fake.secretWrites, 1)
    }

    func testUnknownAgentNeverErasesAKnownOne() {
        let fake = Fake()
        FinShareMirror.write(.init(endpointURL: "https://cp", token: "t", agentName: "Fin", deviceID8: "d"), to: fake.store)
        FinShareMirror.write(.init(endpointURL: "https://cp", token: "t", agentName: nil, deviceID8: "d"), to: fake.store)
        XCTAssertEqual(FinShareMirror.read(from: fake.store)?.agentName, "Fin")
    }

    func testSignOutClearsTheCopies() {
        let fake = Fake()
        FinShareMirror.write(.init(endpointURL: "https://cp", token: "t", agentName: "Fin", deviceID8: "d"), to: fake.store)
        FinShareMirror.write(.init(endpointURL: "https://cp", token: "", agentName: nil, deviceID8: "d"), to: fake.store)
        let read = FinShareMirror.read(from: fake.store)
        XCTAssertEqual(read?.token, "")
        XCTAssertEqual(read?.isUsable, false)
        XCTAssertNil(FinShareMirror.read(from: nil))
    }

    // MARK: - Current-thread migration

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "share.tests.\(UUID().uuidString)")!
    }

    func testMigrationCopiesLegacyMapOnceAndGroupWins() {
        let legacy = suite(), group = suite()
        legacy.set(["Fin": "m-old", "Work": "m-work"], forKey: XanaduCurrentThread.defaultsKey)
        // The share extension already started a thread for Fin in the group.
        group.set(["Fin": "m-shared"], forKey: XanaduCurrentThread.defaultsKey)
        XCTAssertTrue(XanaduCurrentThread.migrate(from: legacy, to: group))
        XCTAssertEqual(group.dictionary(forKey: XanaduCurrentThread.defaultsKey) as? [String: String],
                       ["Fin": "m-shared", "Work": "m-work"])
        // The legacy copy is kept (a downgrade still finds it).
        XCTAssertEqual((legacy.dictionary(forKey: XanaduCurrentThread.defaultsKey) as? [String: String])?["Fin"], "m-old")
        // Once only: a later legacy value never overwrites the group again.
        legacy.set(["Work": "m-newer"], forKey: XanaduCurrentThread.defaultsKey)
        XCTAssertFalse(XanaduCurrentThread.migrate(from: legacy, to: group))
        XCTAssertEqual((group.dictionary(forKey: XanaduCurrentThread.defaultsKey) as? [String: String])?["Work"], "m-work")
    }

    func testMigrationWithNothingToCopyStillMarksDone() {
        let legacy = suite(), group = suite()
        XCTAssertTrue(XanaduCurrentThread.migrate(from: legacy, to: group))
        XCTAssertNil(group.dictionary(forKey: XanaduCurrentThread.defaultsKey))
        XCTAssertTrue(group.bool(forKey: XanaduCurrentThread.migratedKey))
    }
}
