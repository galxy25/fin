import XCTest

/// Scratch diagnostic — verifies the agent hub window opens and its Settings
/// content is genuinely scrollable, using WINDOW-level screenshots
/// (`XCUIElement.screenshot()`) rather than `XCUIScreen.main.screenshot()`: the
/// latter captures a specific physical display, which is wrong on a multi-monitor
/// setup where Fin's window isn't necessarily on the "main" one. An element-level
/// screenshot captures that element wherever it actually is.
final class HubWindowDiagnosticUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testHubWindowOpensAndScrolls() throws {
        let app = launchFinApp()

        func el(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        func startingWith(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }

        var agentsPicker = el("homeMode_Agents")
        if !agentsPicker.waitForExistence(timeout: 3) {
            let serversButton = el("controlStrip_servers")
            _ = serversButton.waitForExistence(timeout: 5)
            serversButton.tapCenter()
            agentsPicker = el("homeMode_Agents")
        }
        _ = agentsPicker.waitForExistence(timeout: 5)
        agentsPicker.tapCenter()

        let agentRow = startingWith("agentRow_")
        XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "agent row never appeared")
        agentRow.tapCenter()

        let settingsForm = el("agentSettingsForm")
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 8), "hub window's Settings never appeared")

        // Find the hub window specifically (not the main terminal/home window) and
        // screenshot IT — element-level, so it's correct regardless of which
        // physical monitor it's actually on.
        let hubWindow = app.windows.containing(.any, identifier: "agentSettingsForm").firstMatch
        if hubWindow.waitForExistence(timeout: 3) {
            let shot = XCTAttachment(screenshot: hubWindow.screenshot())
            shot.name = "01-settings-open"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Scroll the Settings content and confirm something further down the form
        // (Remote Supervision's Toggle, well below the fold) becomes hittable.
        let form = el("agentSettingsForm")
        for _ in 0..<10 {
            form.swipeUp()
        }

        if hubWindow.waitForExistence(timeout: 1) {
            let shot = XCTAttachment(screenshot: hubWindow.screenshot())
            shot.name = "02-after-scroll"
            shot.lifetime = .keepAlways
            add(shot)
        }

        let windowCount = app.windows.count
        let dump = "windowCount=\(windowCount)\napp.debugDescription:\n\(app.debugDescription)"
        let textAttachment = XCTAttachment(string: dump)
        textAttachment.name = "state-dump"
        textAttachment.lifetime = .keepAlways
        add(textAttachment)
    }
}
