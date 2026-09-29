import XCTest
#if canImport(UIKit)
import UIKit
#endif

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
            #if os(macOS)
            // Opt into the REAL relay for the terminal/desktop/browser shots by naming
            // the site to dial (one line, a site id from the fleet). Absent, those
            // screens are the synthetic ones from ScreenshotDemoScreens.
            let live = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/fin-screenshots/live-site-id")
            if let id = try? String(contentsOf: live, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                app.launchEnvironment["FIN_SCREENSHOT_LIVE_SITE_ID"] = id
            }
            #else
            // Simulators run on the host and can read its files: the throwaway loopback
            // key (a real ssh to this Mac) and the real browser frame the Mac run saved.
            let dir = "/Users/deepspacenine/Library/Application Support/fin-screenshots"
            app.launchEnvironment["FIN_SCREENSHOT_KEY_PATH"] = dir + "/id_ed25519"
            app.launchEnvironment["FIN_SCREENSHOT_SSH_USER"] = "deepspacenine"
            app.launchEnvironment["FIN_SCREENSHOT_FRAMES_DIR"] = dir + "/frames"
            #endif
        }
    }

    private var isVision: Bool {
        #if os(visionOS)
        return true
        #else
        return false
        #endif
    }

    private func shoot(_ app: XCUIApplication, _ name: String, viaHost: Bool = false) {
        #if !os(macOS)
        // Host-side capture (see vision-watch.sh) for visionOS, where XCTest screenshots are
        // 1x1, and for a rotated phone, where they come back clipped.
        if viaHost || isVision {
        // The host takes the picture (`xcrun simctl io <sim> screenshot`, watched for by
        // scripts/screenshots/vision-watch.sh): drop a marker, wait for its .done.
        let dir = "/Users/deepspacenine/Library/Application Support/fin-screenshots/vision-ready"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: "\(dir)/\(name).done")   // a previous run's
        FileManager.default.createFile(atPath: "\(dir)/\(name).ready", contents: Data())
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: "\(dir)/\(name).done") { sleep(1) }
        return
        }
        #endif
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

    // MARK: - Phone / pad / headset story
    //
    // One test per screen, each a fresh launch: a screen reached by navigating back from
    // the last one is at the mercy of that platform's back affordance, and a launch is
    // cheap next to a run that fails halfway.

    private func waitForServers(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, id: "homeMode_Terminal").waitForExistence(timeout: 30), "home never appeared")
        _ = firstStartingWith(app, "siteRow_").waitForExistence(timeout: 5)
        sleep(3)
    }

    private func label(_ app: XCUIApplication, beginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A streamed desktop or browser is landscape; on a phone in portrait it is a thin
    /// strip between two black bars. Rotate the phone for those two shots (an iPad's
    /// canvas is wide enough as it is, and visionOS has no orientation).
    private func rotatePhoneToLandscape() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
        }
        #endif
    }

    private func restorePortrait() {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func testMobile01Servers() throws {
        let app = app()
        waitForServers(app)
        shoot(app, "m-01-servers")
    }

    func testMobile02Desktop() throws {
        let app = app()
        waitForServers(app)
        let open = label(app, beginsWith: "Open Studio iMac")
        let desktop = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Open Studio iMac\u{2019}s desktop")).firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "desktop button missing (\(open.exists))")
        desktop.tapCenter()
        sleep(4)
        rotatePhoneToLandscape()
        sleep(3)
        shoot(app, "m-02-desktop", viaHost: true)
        restorePortrait()
    }

    func testMobile03Browser() throws {
        let app = app()
        waitForServers(app)
        let browser = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Open Build Box\u{2019}s browser")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 10), "browser button missing")
        browser.tapCenter()
        sleep(4)
        rotatePhoneToLandscape()
        sleep(3)
        shoot(app, "m-03-browser", viaHost: true)
        restorePortrait()
    }

    func testMobile04RelayTerminal() throws {
        let app = app()
        waitForServers(app)
        let row = label(app, beginsWith: "Build Box, via")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "relay server row missing")
        row.tapCenter()
        sleep(8)
        shoot(app, "m-04-relay-terminal")
    }

    func testMobile05DirectTerminal() throws {
        let app = app()
        waitForServers(app)
        let row = label(app, beginsWith: "This Mac")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "loopback server row missing")
        row.tapCenter()
        sleep(14)
        shoot(app, "m-05-direct-terminal")
    }

    func testMobile06Voice() throws {
        let app = app()
        waitForServers(app)
        let voice = app.buttons["Set up voice button"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10), "voice setup button missing")
        voice.tapCenter()
        sleep(3)
        shoot(app, "m-06-voice")
    }

    func testMobile07Agents() throws {
        let app = app()
        waitForServers(app)
        element(app, id: "homeMode_Agents").tapCenter()
        _ = firstStartingWith(app, "agentRow_").waitForExistence(timeout: 10)
        sleep(2)
        shoot(app, "m-07-agents")
        let row = firstStartingWith(app, "agentRow_")
        if row.exists {
            row.tapCenter()
            sleep(4)
            shoot(app, "m-08-agent-hub")
        }
    }

    func testMobile09Console() throws {
        let app = app()
        waitForServers(app)
        let row = label(app, beginsWith: "Build Box, via")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "relay server row missing")
        row.tapCenter()
        let strip = element(app, id: "controlStrip_agent")
        XCTAssertTrue(strip.waitForExistence(timeout: 30), "control strip missing")
        sleep(3)
        strip.tapCenter()
        sleep(4)
        shoot(app, "m-09-console")
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

    /// The features the product page leads with besides the local terminal: a terminal
    /// reached through Fin's relay (SSH tunnelled over HTTPS), Remote Desktop, Remote
    /// Browser, and the Siri setup. Runs from the servers list; each remote window is
    /// closed after its shot because a macOS window capture is a screen-region grab —
    /// two windows at one frame photograph whichever is on top.
    func testCaptureMacRemote() throws {
        let app = app()

        var terminalTab = element(app, id: "homeMode_Terminal")
        if !terminalTab.waitForExistence(timeout: 10) {
            let servers = element(app, id: "controlStrip_servers")
            XCTAssertTrue(servers.waitForExistence(timeout: 10), "no way into the tabs")
            servers.tapCenter()
            terminalTab = element(app, id: "homeMode_Terminal")
        }
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 15))
        _ = firstStartingWith(app, "siteRow_").waitForExistence(timeout: 10)
        let main = app.windows.matching(identifier: "main-AppWindow-1").firstMatch

        // Remote Desktop and Remote Browser on the Build Box site.
        for (kind, name) in [("desktop", "remote-01-desktop"), ("browser", "remote-02-browser")] {
            // By label: the button's own identifier does not surface under the row's
            // container identifier, its accessibility label ("Open Build Box's desktop")
            // does.
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open Build Box' AND label ENDSWITH %@", kind)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 15), "\(kind) button missing")
            button.tapCenter()
            // The stream's Image is not in the accessibility tree; the window is. SwiftUI
            // names a WindowGroup's windows "<id>-AppWindow-N".
            let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'remote-browser'")).firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 30), "\(name): the remote window never opened")
            // Relay wake + first frames + a settled page.
            sleep(25)
            if kind == "browser" {
                // The shared browser may be parked on anything (last time: a third
                // party's staging admin console). Point it at the developer's own site so the
                // shot shows the feature, not whatever was open.
                let address = window.textFields.firstMatch
                if address.waitForExistence(timeout: 10) {
                    address.tapCenter()
                    address.typeText("https://africanintellect.club/\n")
                }
                sleep(15)
                // The daemon reports a tab's URL and title one navigation late; a second
                // visit to the same page brings the address bar and title level with it.
                if address.exists {
                    address.tapCenter()
                    address.typeText("https://africanintellect.club/\n")
                }
                sleep(25)
            }
            shootWindow(window, name)
            window.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
            sleep(3)
            XCTAssertFalse(window.exists, "\(name): window still open — the next shot would photograph it")
        }

        // The relay terminal: the Build Box server row, which has no address at all.
        let buildBox = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'serverRow_' AND label CONTAINS 'Build Box'"))
            .firstMatch
        XCTAssertTrue(buildBox.waitForExistence(timeout: 10), "Build Box row missing")
        shootWindow(main, "remote-00-servers")
        buildBox.tapCenter()
        XCTAssertTrue(element(app, id: "controlStrip_agent").waitForExistence(timeout: 120), "relay terminal never opened")
        // A brand-new tmux session on a real, in-use laptop takes a while to draw.
        sleep(30)
        // A shell on a real machine that has been in use: clear its greeting and ask
        // for things that say what it is without naming anything private.
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).click()
        // The owner's fish prompt prints a banner on every prompt; a plain bash with a
        // neutral prompt (as the loopback session does) and no tmux status bar.
        app.typeText("tmux set status off; exec env PS1='fin % ' bash --norc --noprofile\n")
        sleep(4)
        app.typeText("clear; sw_vers; echo; uptime; echo; df -h / | tail -1\n")
        sleep(10)
        shootWindow(main, "remote-03-relay-terminal")
    }

    /// Drives the INSTALLED, signed-in app (real servers, real synced keys, real
    /// Keychain session) instead of the throwaway-store build, for the shots that
    /// must go over the live relay to a real machine. Attaches by path because the
    /// test-hosted build shares its bundle id. Exploratory first: dumps the tree.
    func testExploreRealApp() throws {
        let app = XCUIApplication(url: URL(fileURLWithPath: "/Applications/fin.app"))
        app.launch()
        app.activate()
        sleep(6)
        let servers = element(app, id: "controlStrip_servers")
        if servers.waitForExistence(timeout: 10) { servers.tapCenter(); sleep(3) }
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = "real-tree"
        dump.lifetime = .keepAlways
        add(dump)
        for index in 0..<app.windows.count {
            shootWindow(app.windows.element(boundBy: index), "real-window-\(index)")
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
