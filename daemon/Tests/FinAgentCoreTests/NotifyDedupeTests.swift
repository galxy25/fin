import XCTest
@testable import FinAgentCore

/// The floor under the notify tool's "never spam": the ten "Audit Complete" pushes of
/// 2026-09-13, reworded each time, must collapse to one.
final class NotifyDedupeTests: XCTestCase {
    private let now = Date()

    private func sent(_ title: String, _ body: String, minutesAgo: Int) -> RecentNotify {
        RecentNotify(title: title, body: body, at: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }

    func testTheLiveRewordingsAreAllDuplicates() {
        let first = sent("Audit Complete",
                         "The audit is complete. Final results: 12 albums added, 119 split fixes, 38 identity replacements, and a final index of 1,372 albums / 12,493 songs with zero integrity errors.",
                         minutesAgo: 41)
        let rewordings: [(String, String)] = [
            ("Audit Complete", "The audit is complete! Results: 12 albums added, 119 split fixes, 38 identity replacements, and a final index of 1,372 albums / 12,493 songs."),
            ("PocketDJ Audit Complete", "The pocketdj audit is complete! Key results: 12 albums added, 119 split fixes, 38 wrong-release identities replaced, and a final index of 1,372 albums / 12,493 songs with zero integrity errors."),
            ("Security Audit Complete", "Security audit complete. Final report shows 12 albums added, 119 split fixes, 38 identity replacements, and a final index of 1,372 albums / 12,493 songs with zero integrity errors."),
            ("Audit Complete", "The audit is complete and the final results have been shipped."),
        ]
        for (title, body) in rewordings {
            XCTAssertNotNil(NotifyDedupe.duplicate(title: title, body: body, in: [first], now: now), "should dedupe: \(title) — \(body)")
        }
    }

    func testGenuinelyNewNewsIsNotADuplicate() {
        let earlier = sent("Audit Complete", "The audit is complete. 12 albums added, 119 split fixes.", minutesAgo: 10)
        XCTAssertNil(NotifyDedupe.duplicate(
            title: "Blackstreet rip fixed",
            body: "The Tailscale path mount was shadowing POST /rip; removed it and the album is ripped.",
            in: [earlier], now: now))
    }

    func testAnOldPushOutsideTheWindowNoLongerCounts() {
        let old = sent("Deploy done", "main is live on prod.", minutesAgo: 3 * 60)
        XCTAssertNil(NotifyDedupe.duplicate(title: "Deploy done", body: "main is live on prod.", in: [old], now: now))
    }

    func testTheNewestMatchIsReported() {
        let a = sent("Audit Complete", "done", minutesAgo: 90)
        let b = sent("Audit Complete", "done", minutesAgo: 5)
        XCTAssertEqual(NotifyDedupe.duplicate(title: "audit complete", body: "x", in: [a, b], now: now)?.at, b.at)
    }

    func testRememberingPrunesTheWindowAndTheCap() {
        var recent = (0..<25).map { sent("t\($0)", "b\($0)", minutesAgo: 1) }
        recent.append(sent("stale", "stale", minutesAgo: 5 * 60))
        let kept = NotifyDedupe.remembering(sent("new", "new", minutesAgo: 0), in: recent, now: now)
        XCTAssertEqual(kept.count, NotifyDedupe.keep)
        XCTAssertEqual(kept.last?.title, "new")
        XCTAssertFalse(kept.contains { $0.title == "stale" })
    }

    func testStoreRoundTripsAndTreatsGarbageAsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotifyDedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("recent.json").path
        XCTAssertEqual(RecentNotifyStore.load(at: path), [])
        RecentNotifyStore.save([sent("a", "b", minutesAgo: 1)], at: path)
        XCTAssertEqual(RecentNotifyStore.load(at: path).first?.title, "a")
        try Data("nope".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(RecentNotifyStore.load(at: path), [])
    }
}
