import XCTest
@testable import FinAgentCore

/// The rule that decides whether the heartbeat's pane inventory may run.
///
/// Every case here is a sentence about the 2026-09-15 work-laptop incident: a resident site
/// whose model turns (a 12B over a Funnel, ~73 s) outlasted its heartbeat interval (60 s)
/// was permanently mid-turn, so a scan that politely stood aside for turns stood aside
/// forever — and because a skipped scan copies the previous inventory forward, the app
/// showed that computer with no tmux sessions at all, indefinitely, while `read_session` on
/// the same daemon listed them on request.
final class PaneScanPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Until the first scan lands, the app shows a computer with no panes. That is worth
    /// one exec channel whatever else is happening.
    func testTheFirstScanAlwaysRuns() {
        XCTAssertTrue(PaneScanPolicy.shouldScan(
            scanIsCheap: false, isTurnInFlight: true, lastScanAt: nil, now: now
        ))
    }

    /// The ordinary quiet case.
    func testScansWhenNoTurnIsRunning() {
        XCTAssertTrue(PaneScanPolicy.shouldScan(
            scanIsCheap: false, isTurnInFlight: false, lastScanAt: now.addingTimeInterval(-30), now: now
        ))
    }

    /// The courtesy itself, still intact: a fresh inventory is not worth competing with the
    /// agent's own tool calls for an SSH session slot.
    func testStandsAsideForATurnWhenTheInventoryIsFresh() {
        XCTAssertFalse(PaneScanPolicy.shouldScan(
            scanIsCheap: false, isTurnInFlight: true, lastScanAt: now.addingTimeInterval(-30), now: now
        ))
    }

    /// THE REGRESSION. Mid-turn, but the inventory has not been refreshed in longer than
    /// the starvation interval — which on the work laptop was "since launch, and forever".
    func testScansAnywayOnceTheInventoryIsStarved() {
        XCTAssertTrue(PaneScanPolicy.shouldScan(
            scanIsCheap: false,
            isTurnInFlight: true,
            lastScanAt: now.addingTimeInterval(-PaneScanPolicy.starvationInterval - 1),
            now: now
        ))
    }

    /// The boundary is inclusive — exactly at the interval is starved, not "not yet".
    func testTheStarvationBoundaryIsInclusive() {
        XCTAssertTrue(PaneScanPolicy.shouldScan(
            scanIsCheap: false,
            isTurnInFlight: true,
            lastScanAt: now.addingTimeInterval(-PaneScanPolicy.starvationInterval),
            now: now
        ))
    }

    /// A local PTY's fixed command is a child process, not a session on a connection with a
    /// budget. There is nothing to stand aside for, so it never does.
    func testACheapScanNeverWaitsForATurn() {
        XCTAssertTrue(PaneScanPolicy.shouldScan(
            scanIsCheap: true, isTurnInFlight: true, lastScanAt: now.addingTimeInterval(-1), now: now
        ))
    }

    /// The exact shape that froze the laptop: turns back to back, forever, with a fresh-ish
    /// scan each time the question is asked. Before the starvation escape this loop answered
    /// "no" on every single beat for as long as the process lived.
    func testAPermanentlyBusySiteStillRefreshesItsInventory() {
        var lastScan = now
        var scans = 0
        // Two hours of 20-second beats, never once idle.
        for beat in 1...360 {
            let at = now.addingTimeInterval(Double(beat) * 20)
            if PaneScanPolicy.shouldScan(
                scanIsCheap: false, isTurnInFlight: true, lastScanAt: lastScan, now: at
            ) {
                scans += 1
                lastScan = at
            }
        }
        XCTAssertGreaterThan(scans, 30, "a permanently busy site never refreshed its pane inventory")
    }
}
