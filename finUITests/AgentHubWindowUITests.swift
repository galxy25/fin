import XCTest

/// Drives the real, running macOS app via XCUITest's own synchronized accessibility
/// protocol — not generic AppleScript/System Events GUI scripting, which proved
/// unreliable mid-investigation (inconsistent element counts, ambiguous same-named-
/// window addressing) for exactly the kind of "does the agent hub window stay
/// populated after an interaction" question this suite exists to answer live, in a
/// real running app, rather than by static code review alone.
final class AgentHubWindowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func elementStartingWith(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Reaches the agent hub window regardless of which route the app launched
    /// into (an auto-reconnected terminal session presents the Agents tab behind a
    /// sheet; the bare `.home` route shows it directly) — mirrors the two paths
    /// `AgentListView` is actually reachable from in the real app.
    private func openAgentHubWindow(_ app: XCUIApplication) throws {
        var agentsPicker = element(app, id: "homeMode_Agents")
        if !agentsPicker.waitForExistence(timeout: 3) {
            let serversButton = element(app, id: "controlStrip_servers")
            XCTAssertTrue(
                serversButton.waitForExistence(timeout: 5),
                "Expected either the Agents tab or the servers button to reach it"
            )
            serversButton.tapCenter()
            agentsPicker = element(app, id: "homeMode_Agents")
        }
        XCTAssertTrue(agentsPicker.waitForExistence(timeout: 5), "Agents tab picker segment never appeared")
        agentsPicker.tapCenter()

        let agentRow = elementStartingWith(app, prefix: "agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "Expected at least one agent row in the list")
        agentRow.tapCenter()
    }

    /// Opening an agent's hub should open a NEW window, not take over the app's
    /// existing one (the Agents list stays open behind it).
    func testOpeningAgentCreatesNewWindow() throws {
        let app = launchFinApp()

        var agentsPicker = element(app, id: "homeMode_Agents")
        if !agentsPicker.waitForExistence(timeout: 3) {
            let serversButton = element(app, id: "controlStrip_servers")
            XCTAssertTrue(serversButton.waitForExistence(timeout: 5))
            serversButton.tapCenter()
            agentsPicker = element(app, id: "homeMode_Agents")
        }
        XCTAssertTrue(agentsPicker.waitForExistence(timeout: 5))
        agentsPicker.tapCenter()

        let before = app.windows.count
        let agentRow = elementStartingWith(app, prefix: "agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5))
        agentRow.tapCenter()

        let settingsForm = element(app, id: "agentSettingsForm")
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 5))

        let after = app.windows.count
        XCTAssertGreaterThan(
            after, before,
            "Opening an agent should create a new window, not replace the existing one"
        )
    }

    /// The exact live-reproduced bug: switching the hub window's sidebar selection
    /// (Settings → Logs → back to Settings) blanked the entire window (0
    /// accessibility elements, process alive, no crash/hang report) before this was
    /// investigated. Round-trips the selection and asserts real content survives
    /// each hop.
    func testHubWindowSurvivesSidebarSelectionChange() throws {
        let app = launchFinApp()
        try openAgentHubWindow(app)

        let sidebar = element(app, id: "hubSidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Hub window's sidebar should appear")

        let settingsForm = element(app, id: "agentSettingsForm")
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 5), "Settings form should render on first open")

        let logsRow = element(app, id: "hubSidebarRow_logs")
        XCTAssertTrue(logsRow.waitForExistence(timeout: 5))
        logsRow.tapCenter()

        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Sidebar should still exist after switching to Logs")

        let settingsRow = element(app, id: "hubSidebarRow_settings")
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tapCenter()

        XCTAssertTrue(
            settingsForm.waitForExistence(timeout: 5),
            "Settings form should still render after round-tripping the sidebar selection — this is the exact interaction that live-testing showed blanking the window"
        )
    }

    /// The user's original report: content below Limits (Remote Supervision, Help
    /// Improve Fin, System Prompt) was unreachable — clipped hard partway down with
    /// no working scrollbar. Settings collapsible sections (DisclosureGroup, then a
    /// manual toggle) were tried and found to break Form's scroll entirely,
    /// regardless of the hub window's own container (NavigationSplitView, then a
    /// plain HStack) — so `AgentEditView.macBody` replaced `Form`/`Section` with a
    /// plain `ScrollView` on macOS instead. This asserts that fix: scrolling the
    /// Settings pane actually reveals Remote Supervision's Toggle.
    func testScrollingSettingsReachesRemoteSupervision() throws {
        let app = launchFinApp()
        try openAgentHubWindow(app)

        let form = element(app, id: "agentSettingsForm")
        XCTAssertTrue(form.waitForExistence(timeout: 5))

        let remoteSupervisionToggle = element(app, id: "remoteSupervisionEnabledToggle")
        if !remoteSupervisionToggle.waitForExistence(timeout: 1) {
            for _ in 0..<12 {
                form.swipeUp()
                if remoteSupervisionToggle.waitForExistence(timeout: 1) { break }
            }
        }
        XCTAssertTrue(
            remoteSupervisionToggle.waitForExistence(timeout: 2),
            "Scrolling the Settings pane should reach Remote Supervision's Enabled toggle"
        )

        let sidebar = element(app, id: "hubSidebar")
        XCTAssertTrue(sidebar.exists, "Sidebar should still be present after scrolling Settings")
    }

    /// A plain value-changing control (no row insertion/removal at all) — isolates
    /// whether ANY interaction inside the hub window's Settings form is broken, not
    /// just the collapsible-section mechanism.
    func testTogglingNotifyOnResponseDoesNotBlankWindow() throws {
        let app = launchFinApp()
        try openAgentHubWindow(app)

        let settingsForm = element(app, id: "agentSettingsForm")
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 5))

        let checkbox = app.checkBoxes.firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "Expected at least one checkbox in the settings form")
        checkbox.tapCenter()

        XCTAssertTrue(
            settingsForm.waitForExistence(timeout: 5),
            "Settings form should still render after toggling a plain checkbox"
        )
        let sidebar = element(app, id: "hubSidebar")
        XCTAssertTrue(sidebar.exists, "Sidebar should still be present after toggling a checkbox")
    }
}
