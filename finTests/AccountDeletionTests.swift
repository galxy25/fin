import XCTest
@testable import fin

/// Account deletion (App Store Guideline 5.1.1(v)): the wording the user reads
/// and the decode of what the server says it removed. The network half is the
/// control plane's own `AccountDeletionTests` in test_lambda.py; what is pinned
/// here is that the app never claims more (or less) than actually happened.
final class AccountDeletionTests: XCTestCase {

    private func decode(_ json: String) throws -> ControlPlaneClient.AccountDeletion {
        try JSONDecoder().decode(ControlPlaneClient.AccountDeletion.self, from: Data(json.utf8))
    }

    func testTheServersCountsDecode() throws {
        let deletion = try decode("""
        {"deleted":{"instancesTerminated":1,"workers":3,"sites":2,"messages":40,
         "threadEvents":12,"agents":1,"enrollTokens":0,"deviceTokens":5,
         "objects":118,"credentials":2,"identities":1,"sessions":4}}
        """)
        XCTAssertEqual(deletion.deleted.instancesTerminated, 1)
        XCTAssertEqual(deletion.deleted.sites, 2)
        XCTAssertEqual(deletion.deleted.objects, 118)
        XCTAssertEqual(deletion.deleted.sessions, 4)
    }

    /// A field the app doesn't know about must not fail the decode — the server
    /// gains counters over time and an older build still has to show the sheet.
    func testAnUnknownCounterDoesNotBreakTheDecode() throws {
        let deletion = try decode(#"{"deleted":{"sites":1,"somethingNew":9}}"#)
        XCTAssertEqual(deletion.deleted.sites, 1)
        XCTAssertNil(deletion.deleted.objects)
    }

    func testTheSummaryNamesWhatWasActuallyRemoved() throws {
        let summary = ControlPlaneClient.deletionSummary(try decode(
            #"{"deleted":{"instancesTerminated":2,"sites":1,"objects":40,"sessions":3}}"#))
        XCTAssertTrue(summary.contains("2 cloud computers shut down"), summary)
        XCTAssertTrue(summary.contains("1 computer unlinked"), summary)
        XCTAssertTrue(summary.contains("40 stored files erased"), summary)
        XCTAssertTrue(summary.contains("Every device is signed out."), summary)
    }

    /// Zero counts are left out rather than read as "0 cloud computers shut
    /// down", and an account with nothing in it still gets a plain confirmation.
    func testAnEmptyAccountStillReadsAsDeleted() throws {
        let summary = ControlPlaneClient.deletionSummary(try decode(
            #"{"deleted":{"instancesTerminated":0,"sites":0,"objects":0}}"#))
        XCTAssertEqual(summary, "Your Fin account is gone. This device is signed out.")
        XCTAssertEqual(ControlPlaneClient.deletionSummary(nil),
                       "Your Fin account is gone. This device is signed out.")
    }

    func testSingularAndPluralAgree() throws {
        let one = ControlPlaneClient.deletionSummary(try decode(
            #"{"deleted":{"instancesTerminated":1,"sites":1,"objects":1}}"#))
        XCTAssertTrue(one.contains("1 cloud computer shut down"), one)
        XCTAssertTrue(one.contains("1 computer unlinked"), one)
        XCTAssertTrue(one.contains("1 stored file erased"), one)
        XCTAssertFalse(one.contains("computers shut down"), one)
    }

    /// A failure must never read as a deletion, and an unreachable server has
    /// to say plainly that nothing was deleted.
    func testFailuresSayNothingWasDeleted() {
        let offline = CloudSyncStatusView.deleteFailureMessage(.network)
        XCTAssertTrue(offline.contains("nothing was deleted"), offline)
        XCTAssertFalse(offline.lowercased().contains("your fin account is gone"), offline)

        let refused = CloudSyncStatusView.deleteFailureMessage(.http(403, "account deletion requires a Sign in with Apple session token"))
        XCTAssertTrue(refused.contains("403"), refused)
        XCTAssertTrue(refused.contains("Sign in with Apple session token"), refused)

        XCTAssertTrue(CloudSyncStatusView.deleteFailureMessage(.notConfigured).contains("No Fin account"))
    }

    /// The server answers 500 with the stages it could not sweep; the user must
    /// see that, not a success sheet.
    func testAPartialSweepIsReportedAsAFailure() {
        let message = CloudSyncStatusView.deleteFailureMessage(.http(
            500, "some data could not be deleted (sites); nothing here is recoverable, please contact support so the rest can be removed by hand"))
        XCTAssertTrue(message.contains("contact support"), message)
        XCTAssertTrue(message.contains("500"), message)
    }
}
