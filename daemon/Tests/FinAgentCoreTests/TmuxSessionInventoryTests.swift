import XCTest
@testable import FinAgentCore

/// `TmuxSessionInventory` — the pure parser/classifier half of the live session
/// inventory feature. Mirrors evals/session-activity's `inventory_baseline.py` spec;
/// this is the Swift port's own regression suite for the same decisions.
final class TmuxSessionInventoryTests: XCTestCase {

    private func pane(
        session: String, paneTarget: String, cwd: String, command: String, windows: Int
    ) -> TmuxSessionInventory.DiscoveredPane {
        TmuxSessionInventory.DiscoveredPane(
            session: session, paneTarget: paneTarget, cwd: cwd,
            currentCommand: command, windowCount: windows
        )
    }

    // MARK: - parsePanes

    func testParsePanesReadsAWellFormedRow() {
        let raw = "fin\t0.0\t/Users/levi/forges/levi/fin\tclaude\t2\n"
        let panes = TmuxSessionInventory.parsePanes(raw)
        XCTAssertEqual(panes, [pane(session: "fin", paneTarget: "0.0", cwd: "/Users/levi/forges/levi/fin", command: "claude", windows: 2)])
    }

    func testParsePanesSkipsAMalformedRowInsteadOfCrashing() {
        // Missing the trailing window-count field entirely.
        let raw = "fin\t0.0\t/Users/levi/fin\tclaude\n" + "pocketdj\t0.0\t/Users/levi/pocketdj\tzsh\t1\n"
        let panes = TmuxSessionInventory.parsePanes(raw)
        XCTAssertEqual(panes, [pane(session: "pocketdj", paneTarget: "0.0", cwd: "/Users/levi/pocketdj", command: "zsh", windows: 1)])
    }

    func testParsePanesSkipsARowWithANonIntegerWindowCount() {
        let raw = "fin\t0.0\t/Users/levi/fin\tclaude\tmany\n"
        XCTAssertEqual(TmuxSessionInventory.parsePanes(raw), [])
    }

    func testParsePanesToleratesAnEmptyCurrentCommandField() {
        // A pane whose current_command is the empty string — malformed-ish but still
        // 5 well-separated fields, so it must parse (and simply never match an agent).
        let raw = "idle\t0.0\t/Users/levi\t\t1\n"
        let panes = TmuxSessionInventory.parsePanes(raw)
        XCTAssertEqual(panes, [pane(session: "idle", paneTarget: "0.0", cwd: "/Users/levi", command: "", windows: 1)])
    }

    // MARK: - groupBySession: kind classification

    func testASingleShellPaneSessionIsClassifiedShell() {
        let panes = [pane(session: "main", paneTarget: "0.0", cwd: "/Users/levi", command: "zsh", windows: 1)]
        let snapshots = TmuxSessionInventory.groupBySession(panes)
        XCTAssertEqual(snapshots, [
            TmuxSessionInventory.SessionSnapshot(session: "main", kind: "shell", cwd: "/Users/levi", agentPaneTarget: nil),
        ])
    }

    func testASingleAgentPaneSessionIsClassifiedCodingAgentWithPaneTargetSet() {
        let panes = [pane(session: "fin", paneTarget: "0.1", cwd: "/Users/levi/fin", command: "claude", windows: 1)]
        let snapshots = TmuxSessionInventory.groupBySession(panes)
        XCTAssertEqual(snapshots, [
            TmuxSessionInventory.SessionSnapshot(
                session: "fin", kind: "coding-agent", cwd: "/Users/levi/fin", agentPaneTarget: "fin:0.1"
            ),
        ])
    }

    func testAMixedShellAndAgentSessionIsCodingAgentUsingTheAgentPanesCwdAndTarget() {
        let panes = [
            pane(session: "fin", paneTarget: "0.0", cwd: "/Users/levi/shell-cwd", command: "zsh", windows: 2),
            pane(session: "fin", paneTarget: "1.0", cwd: "/Users/levi/fin", command: "claude", windows: 2),
        ]
        let snapshots = TmuxSessionInventory.groupBySession(panes)
        XCTAssertEqual(snapshots, [
            TmuxSessionInventory.SessionSnapshot(
                session: "fin", kind: "coding-agent", cwd: "/Users/levi/fin", agentPaneTarget: "fin:1.0"
            ),
        ])
    }

    func testTwoSessionsSharingACwdAreNotMerged() {
        let panes = [
            pane(session: "a", paneTarget: "0.0", cwd: "/Users/levi/shared", command: "claude", windows: 1),
            pane(session: "b", paneTarget: "0.0", cwd: "/Users/levi/shared", command: "claude", windows: 1),
        ]
        let snapshots = TmuxSessionInventory.groupBySession(panes)
        XCTAssertEqual(snapshots.map(\.session), ["a", "b"])
    }

    func testKnownAgentsCanBeOverriddenBySetIntersection() {
        let panes = [pane(session: "s", paneTarget: "0.0", cwd: "/x", command: "my-custom-agent", windows: 1)]
        XCTAssertEqual(
            TmuxSessionInventory.groupBySession(panes, knownAgents: ["my-custom-agent"]).first?.kind,
            "coding-agent"
        )
        XCTAssertEqual(TmuxSessionInventory.groupBySession(panes).first?.kind, "shell")
    }

    func testResultsAreSortedBySessionNameForDeterminism() {
        let panes = [
            pane(session: "zeta", paneTarget: "0.0", cwd: "/z", command: "zsh", windows: 1),
            pane(session: "alpha", paneTarget: "0.0", cwd: "/a", command: "zsh", windows: 1),
        ]
        XCTAssertEqual(TmuxSessionInventory.groupBySession(panes).map(\.session), ["alpha", "zeta"])
    }
}
