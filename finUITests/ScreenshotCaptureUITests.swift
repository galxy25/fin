import XCTest

/// Drives the app through the screens that belong on the App Store product page
/// and attaches a full-screen capture of each, so a capture run is reproducible
/// rather than a hand-held photo session that has to be redone from memory every
/// release.
///
/// Runs against the app launched with `FIN_SCREENSHOT_MODE=1`, which seeds the
/// demo rows in `ScreenshotFixtures` — without it every shot is an empty state,
/// which is exactly how the first set of store screenshots ended up showing "No
/// Servers" and "No Files".
///
/// Extract the results with:
///   xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>
final class ScreenshotCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func app() -> XCUIApplication {
        launchFinApp { app in
            app.launchEnvironment["FIN_SCREENSHOT_MODE"] = "1"
        }
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        // Screenshot the APP, not XCUIScreen.main: on a multi-display Mac "main"
        // is a physical display that may not be the one the window is on.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #if os(macOS)
        // On a Mac that app screenshot is the whole desktop — wallpaper, desktop
        // icons, other apps' windows — so it can't ship as-is. Record every
        // window's frame (points; multiply by the backing scale for pixels)
        // alongside it so the capture can be cropped to the app deterministically
        // instead of by eyeballing coordinates.
        let frames = (0..<app.windows.count).map { index -> String in
            let f = app.windows.element(boundBy: index).frame
            return "\(index):\(f.origin.x),\(f.origin.y),\(f.size.width),\(f.size.height)"
        }
        let dump = XCTAttachment(string: frames.joined(separator: "\n"))
        dump.name = "\(name)-frames"
        dump.lifetime = .keepAlways
        add(dump)
        #endif
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func firstStartingWith(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    func testCaptureProductPageScreens() throws {
        let app = app()

        // 1 — Servers. The seeded list, which is where a new user starts.
        let terminalTab = element(app, id: "homeMode_Terminal")
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 20), "home picker never appeared")
        shoot(app, "01-servers")

        // 2 — Agents. The product's actual pitch: an agent per machine.
        let agentsTab = element(app, id: "homeMode_Agents")
        if agentsTab.waitForExistence(timeout: 5) {
            agentsTab.tapCenter()
            _ = firstStartingWith(app, "agentRow_").waitForExistence(timeout: 10)
            shoot(app, "02-agents")

            // 3 — One agent's settings/hub: provider, model, limits, prompt.
            // No wait on "agentSettingsForm": that identifier is on AgentEditView's
            // macOS body only, and on iOS the row pushes AgentHubView instead. Give
            // the push time to settle and capture whatever the platform lands on.
            let agentRow = firstStartingWith(app, "agentRow_")
            if agentRow.exists {
                agentRow.tapCenter()
                sleep(3)
                shoot(app, "03-agent-settings")
                goBackIfPossible(app)
            }
        }

        // 4 — Files, and 5 — a rendered markdown document.
        let filesTab = element(app, id: "homeMode_Files")
        if filesTab.waitForExistence(timeout: 5) {
            filesTab.tapCenter()
            _ = element(app, id: "fileListView").waitForExistence(timeout: 10)
            shoot(app, "04-files")

            let fileRow = firstStartingWith(app, "fileRow_")
            if fileRow.waitForExistence(timeout: 5) {
                fileRow.tapCenter()
                _ = element(app, id: "markdownReaderScroll").waitForExistence(timeout: 10)
                shoot(app, "05-markdown-reader")
                goBackIfPossible(app)
            }
        }

        // 6 — The paywall. Doubles as the Guideline 3.1.2(c) evidence: title,
        // length, price, renewal terms, and both policy links on one screen.
        // The toolbar item is a Label("Fin Pro", systemImage: "crown") carrying an
        // explicit accessibilityLabel, and which of the two strings actually lands
        // on the AX element differs by platform — so try both rather than guessing.
        for key in ["Fin Pro subscription", "Fin Pro"] {
            let proButton = app.buttons[key].firstMatch
            if proButton.waitForExistence(timeout: 5) {
                proButton.tapCenter()
                sleep(3)
                shoot(app, "06-paywall")
                break
            }
        }
    }

    #if os(macOS)
    /// macOS captures the WINDOWS, never `app.screenshot()`: on a Mac the latter
    /// is the whole desktop — wallpaper, desktop icons, and whatever other apps
    /// happen to be on screen — which is both unusable as a product-page asset
    /// and a privacy leak waiting to happen. Each window is attached on its own
    /// so a capture can be composed deliberately afterwards (a single window, or
    /// two side by side for the multi-window story).
    func testCaptureMacWindows() throws {
        let app = app()

        // Same defensive entry as AgentHubWindowUITests.openAgentHubWindow: an
        // auto-reconnected terminal session puts the tabs behind the control
        // strip's server-rack button rather than showing them directly.
        var terminalTab = element(app, id: "homeMode_Terminal")
        if !terminalTab.waitForExistence(timeout: 10) {
            let servers = element(app, id: "controlStrip_servers")
            XCTAssertTrue(servers.waitForExistence(timeout: 10), "no way into the tabs")
            servers.tapCenter()
            terminalTab = element(app, id: "homeMode_Terminal")
        }
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 15))
        sleep(1)
        shootWindow(app.windows.firstMatch, "mac-01-servers")

        // Re-query every element after a capture: the screenshot round-trip can
        // outlive the cached snapshot, and a stale handle reports "not found"
        // for a control that is plainly on screen.
        let agentsTab = element(app, id: "homeMode_Agents")
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 15), "Agents tab never appeared")
        agentsTab.tapCenter()
        var agentRow = firstStartingWith(app, "agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 15))
        shootWindow(app.windows.firstMatch, "mac-02-agents")

        agentRow = firstStartingWith(app, "agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 10))
        agentRow.tapCenter()
        let hub = app.windows.containing(.any, identifier: "agentSettingsForm").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "agent hub window never opened")
        sleep(2)
        shootWindow(hub, "mac-03-agent-hub")

        // Sidebar hop: logs & traces is the drill-down story.
        let logsRow = element(app, id: "hubSidebarRow_logs")
        if logsRow.waitForExistence(timeout: 5) {
            logsRow.tapCenter()
            sleep(2)
            shootWindow(hub, "mac-04-agent-logs")
        }
    }

    /// The product-page story on a Mac, with real content: the seeded servers and
    /// Fin's computers, a LIVE loopback terminal ("This Mac", see
    /// ScreenshotFixtures) with the agent console beside it showing a restored
    /// conversation, then the hub's settings, memory and traces. Every window is
    /// attached on its own; scripts/screenshots/compose-mac.py frames them.
    func testCaptureMacStory() throws {
        let app = app()

        var terminalTab = element(app, id: "homeMode_Terminal")
        if !terminalTab.waitForExistence(timeout: 10) {
            let servers = element(app, id: "controlStrip_servers")
            XCTAssertTrue(servers.waitForExistence(timeout: 10), "no way into the tabs")
            servers.tapCenter()
            terminalTab = element(app, id: "homeMode_Terminal")
        }
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 15))
        // Fin's computers arrive a beat after the servers (the directory refresh
        // runs in a task); shooting before they settle catches the list
        // mid-insertion, scrolled past its first row.
        _ = firstStartingWith(app, "siteRow_").waitForExistence(timeout: 10)
        // Only one window exists this early, so firstMatch is the main window;
        // once the hub is open it is whichever is frontmost (run 6's "paywall"
        // was a photo of the Logs window), so the last shot re-finds the main
        // window by the control strip instead.
        let main = app.windows.firstMatch
        // The list keeps its offset relative to the Servers section when the
        // computers section lands above it, hiding the first computer under the
        // header. A hop to Files and back rebuilds the list at the top with the
        // computers already present.
        element(app, id: "homeMode_Files").tapCenter()
        sleep(1)
        element(app, id: "homeMode_Terminal").tapCenter()
        sleep(2)
        shootWindow(main, "story-01-servers")

        // The live row. Identified by label, not id: the id carries a UUID minted
        // at seed time.
        let thisMac = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'serverRow_' AND label CONTAINS 'This Mac'"))
            .firstMatch
        XCTAssertTrue(thisMac.waitForExistence(timeout: 10), "the loopback server row is missing — was the key prepared?")
        thisMac.tapCenter()
        // The tab bar only renders with two or more tabs; the control strip is
        // what proves the terminal screen is up.
        let strip = element(app, id: "controlStrip_agent")
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "the terminal screen never opened")
        // SSH handshake + tmux attach, then a prompt. Generous on purpose: a
        // capture that types into a shell that is still spawning loses the line.
        sleep(8)
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        app.typeText("clear; sw_vers; echo; xcodebuild -version; echo; top -l 1 -n 8 -stats pid,command,cpu,mem | head -20\n")
        sleep(5)
        shootWindow(main, "story-02-terminal")

        // The console beside the terminal: history restored from the seeded trail.
        let agentButton = element(app, id: "controlStrip_agent")
        XCTAssertTrue(agentButton.waitForExistence(timeout: 10))
        agentButton.tapCenter()
        sleep(3)
        shootWindow(main, "story-03-terminal-agent")

        // Into the agent hub: Agents live behind the server-rack button once a
        // terminal is open (the picker sheet), same as testCaptureMacWindows.
        let servers = element(app, id: "controlStrip_servers")
        XCTAssertTrue(servers.waitForExistence(timeout: 10))
        servers.tapCenter()
        let agentsTab = element(app, id: "homeMode_Agents")
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 15), "Agents tab never appeared")
        agentsTab.tapCenter()
        sleep(1)
        shootWindow(main, "story-04-agents")

        // First row is "Fin": the fixture seeds it first and the list sorts by
        // creation. (A label match fails here — the row's label is its custom view.)
        let agentRow = firstStartingWith(app, "agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 10))
        agentRow.tapCenter()
        // Found by its sidebar, which every hub section keeps — a handle keyed on
        // the settings form stops matching the moment Memory replaces it, and the
        // memory shot then silently skips (run 5).
        let hub = app.windows.containing(.any, identifier: "hubSidebar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "agent hub window never opened")
        XCTAssertTrue(element(app, id: "agentSettingsForm").waitForExistence(timeout: 10))
        sleep(3)
        shootWindow(hub, "story-05-agent-settings")

        // Bring the hub to the front — it opens centred on top of a main window
        // of the same size, and a List's rows are not reliably in the
        // accessibility tree for a window that is not key (runs 2-4: the
        // sidebar existed, its rows did not).
        hub.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        sleep(1)
        XCTAssertTrue(element(app, id: "hubSidebar").waitForExistence(timeout: 15), "hub sidebar never appeared")
        for (section, name) in [("memory", "story-06-memory"), ("logs", "story-07-logs")] {
            let row = hub.descendants(matching: .any).matching(identifier: "hubSidebarRow_\(section)").firstMatch
            guard row.waitForExistence(timeout: 15) else {
                // Leave the tree behind so the next run can see what the sidebar
                // actually exposed, rather than guessing.
                let dump = XCTAttachment(string: hub.debugDescription)
                dump.name = "hub-tree-\(section)"
                dump.lifetime = .keepAlways
                add(dump)
                XCTFail("hub sidebar row \(section) never appeared")
                continue
            }
            row.tapCenter()
            sleep(3)
            shootWindow(hub, name)
        }

        // The paywall last, from the picker sheet still open in the main window:
        // dismissing it with Escape mid-flow also unsettled the sheet the agent
        // row lives in, and the hub never opened (run 4).
        // A window screenshot on macOS is a screen-region grab of that window's
        // frame, and the hub is sized to the SAME frame as the main window — so
        // while the hub is up, "the main window" photographs the hub (runs 6, 9,
        // 10). Close the hub first; the main window is then the only one there.
        hub.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        sleep(2)
        // SwiftUI names a WindowGroup's windows "<id>-AppWindow-N"; the hub is
        // its own group ("agent-hub-AppWindow-1"), so this cannot resolve to it.
        let mainAgain = app.windows.matching(identifier: "main-AppWindow-1").firstMatch
        XCTAssertTrue(mainAgain.waitForExistence(timeout: 10), "main window lost")
        XCTAssertFalse(hub.exists, "the hub window is still open; the paywall shot would photograph it")
        mainAgain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        sleep(1)
        for key in ["Fin Pro subscription", "Fin Pro"] {
            let proButton = app.buttons[key].firstMatch
            if proButton.waitForExistence(timeout: 5) {
                proButton.tapCenter()
                sleep(3)
                shootWindow(mainAgain, "story-08-paywall")
                break
            }
        }
    }

    private func shootWindow(_ window: XCUIElement, _ name: String) {
        guard window.exists else { return }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    /// A short, focused drive to the paywall, for screen-recording it as the
    /// Guideline 3.1.2(c) evidence App Review asked for ("reply to this message
    /// with a screen recording to confirm"). Kept separate from the product-page
    /// capture so the recording isn't 30 seconds of unrelated navigation.
    func testCapturePaywallForReview() throws {
        let app = app()

        let terminalTab = element(app, id: "homeMode_Terminal")
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 20))
        sleep(2)

        for key in ["Fin Pro subscription", "Fin Pro"] {
            let proButton = app.buttons[key].firstMatch
            if proButton.waitForExistence(timeout: 5) {
                proButton.tapCenter()
                break
            }
        }
        // Hold on the disclosure long enough to be legible in the recording.
        sleep(8)
        shoot(app, "paywall-review-evidence")
    }

    /// Back out of a pushed screen when the platform has a back affordance;
    /// a no-op where there isn't one (a macOS window, for instance).
    private func goBackIfPossible(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable {
            back.tap()
            sleep(1)
        }
    }
}
