import XCTest
import SwiftUI
@testable import fin

/// The attention tile (docs/CARPLAY-IMESSAGE-DESIGN.md §3.4): the pure
/// content-state derivation from `FinPresence`, the start/update/end
/// decision loop, the token-upload wire shape, and a layout pass over the
/// widget's views. No ActivityKit here — that half is iOS-only and needs a
/// device; everything below runs on every platform the test bundle does.
@MainActor
final class LiveActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func site(_ name: String, state: String, live: Bool = true, agent: String = "Fin") -> FinSite {
        let json: [String: Any] = [
            "siteId": "abcd1234-0000-4000-8000-000000000000", "siteId8": "abcd1234", "agent": agent,
            "kind": "resident", "displayName": name, "priority": 100, "state": state, "live": live,
            "capabilities": [:] as [String: Any],
        ]
        return try! ControlPlaneClient.decoder.decode(FinSite.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Content state from presence (pure)

    func testContentStateIsPresenceVocabularyVerbatim() {
        let working = FinLiveActivityPlan.contentState(for: .working(siteName: "Levi's iMac"), now: t0)
        XCTAssertEqual(working.headline, "Fin is working")
        XCTAssertEqual(working.detail, "on Levi's iMac")
        XCTAssertEqual(working.glyph, "gearshape.2")
        XCTAssertEqual(working.status, .working)
        XCTAssertEqual(working.updatedAt, t0.timeIntervalSince1970)

        let needs = FinLiveActivityPlan.contentState(for: .needsInput(siteName: "Cloud"), now: t0)
        XCTAssertEqual(needs.headline, "Fin needs your input")
        XCTAssertEqual(needs.detail, "on Cloud")
        XCTAssertEqual(needs.glyph, "exclamationmark.bubble")
        XCTAssertEqual(needs.status.rawValue, "needsInput")

        let idle = FinLiveActivityPlan.contentState(for: .idle, now: t0)
        XCTAssertEqual(idle.headline, "Fin is ready")
        XCTAssertEqual(idle.status, .idle)
        XCTAssertNil(idle.detail)
        let asleep = FinLiveActivityPlan.contentState(for: .asleep, now: t0)
        XCTAssertEqual(asleep.glyph, "moon.zzz")
        XCTAssertEqual(asleep.status, .idle)

        // The fold the controller feeds in is the same one the console header uses.
        let presence = FinPresence.fold([site("A", state: "working"), site("B", state: "needs-input")])
        XCTAssertEqual(FinLiveActivityPlan.contentState(for: presence, now: t0).status, .needsInput)
    }

    func testWireShapeMatchesTheLambdaContract() throws {
        // The Lambda mirrors these keys (`_activity_content_state`); a rename
        // on either side silently blanks the tile, so the JSON is pinned here.
        let state = FinLiveActivityPlan.contentState(for: .working(siteName: "iMac"), now: t0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(json).keys), ["headline", "detail", "glyph", "status", "updatedAt"])
        XCTAssertEqual(json?["status"] as? String, "working")
        XCTAssertEqual(json?["updatedAt"] as? Double, t0.timeIntervalSince1970)
        // And what the Lambda sends decodes: `detail: null`, epoch seconds.
        let pushed = """
        {"headline":"Fin answered","detail":null,"glyph":"checkmark.bubble","status":"answered","updatedAt":1800000000}
        """
        let decoded = try JSONDecoder().decode(FinActivityAttributes.ContentState.self, from: Data(pushed.utf8))
        XCTAssertEqual(decoded.status, .answered)
        XCTAssertNil(decoded.detail)
        let attributes = try JSONDecoder().decode(
            FinActivityAttributes.self, from: Data(#"{"agentName":"Fin","agentID":""}"#.utf8)
        )
        XCTAssertEqual(attributes.agentName, "Fin")
    }

    // MARK: - Decision loop

    func testTrackerStartsUpdatesAndEndsAfterTheQuietGrace() {
        var tracker = FinLiveActivityPlan.Tracker()
        // Idle with nothing running: never a tile.
        XCTAssertEqual(tracker.step(.idle, now: t0), .nothing)
        XCTAssertEqual(tracker.step(.asleep, now: t0), .nothing)
        XCTAssertFalse(tracker.isRunning)

        // Working: start once, then silence while the sample repeats.
        guard case .start(let started) = tracker.step(.working(siteName: "iMac"), now: t0) else {
            return XCTFail("expected start")
        }
        XCTAssertEqual(started.status, .working)
        XCTAssertEqual(tracker.step(.working(siteName: "iMac"), now: t0.addingTimeInterval(15)), .nothing)

        // A different headline/detail is an update; the timestamp alone is not.
        guard case .update(let updated) = tracker.step(.needsInput(siteName: "iMac"), now: t0.addingTimeInterval(30)) else {
            return XCTFail("expected update")
        }
        XCTAssertEqual(updated.status, .needsInput)

        // Quiet: one idle update, then nothing until the grace lapses, then end.
        guard case .update(let idle) = tracker.step(.idle, now: t0.addingTimeInterval(60)) else {
            return XCTFail("expected the idle update")
        }
        XCTAssertEqual(idle.status, .idle)
        XCTAssertEqual(tracker.step(.idle, now: t0.addingTimeInterval(120)), .nothing)
        XCTAssertEqual(tracker.step(.idle, now: t0.addingTimeInterval(179)), .nothing)
        guard case .end = tracker.step(.idle, now: t0.addingTimeInterval(181)) else {
            return XCTFail("expected end after \(FinLiveActivityPlan.quietGrace)s of quiet")
        }
        XCTAssertFalse(tracker.isRunning)
        XCTAssertNil(tracker.lastState)
    }

    func testAFlapInsideTheGraceKeepsOneTile() {
        var tracker = FinLiveActivityPlan.Tracker()
        _ = tracker.step(.working(siteName: "iMac"), now: t0)
        _ = tracker.step(.idle, now: t0.addingTimeInterval(20))
        guard case .update(let back) = tracker.step(.working(siteName: "iMac"), now: t0.addingTimeInterval(40)) else {
            return XCTFail("expected an update, not a restart")
        }
        XCTAssertEqual(back.status, .working)
        XCTAssertNil(tracker.quietSince)
        XCTAssertTrue(tracker.isRunning)
    }

    func testAnAnsweredTileIsKeptThroughTheGraceAndExternalEndsAreHonoured() {
        let answered = FinActivityAttributes.ContentState(
            headline: "Fin answered", detail: "It is noon.", glyph: "checkmark.bubble", status: .answered,
            updatedAt: t0.timeIntervalSince1970
        )
        var tracker = FinLiveActivityPlan.Tracker(isRunning: true, lastState: answered)
        // The control plane's reply stays on screen; no idle overwrite.
        XCTAssertEqual(tracker.step(.idle, now: t0.addingTimeInterval(5)), .nothing)
        XCTAssertEqual(tracker.lastState?.status, .answered)
        tracker.activityEnded()
        XCTAssertFalse(tracker.isRunning)
        // After an external end, idle stays quiet and work starts fresh.
        XCTAssertEqual(tracker.step(.idle, now: t0.addingTimeInterval(10)), .nothing)
        guard case .start = tracker.step(.working(siteName: "iMac"), now: t0.addingTimeInterval(20)) else {
            return XCTFail("expected a fresh start")
        }
    }

    // MARK: - Token upload

    func testLiveActivityTokenRequestShape() throws {
        let start = try XCTUnwrap(DeviceTokenUplink.request(
            tokenHex: "ab", platform: "iOS", deviceName: "Levi's iPhone", deviceID8: "a4a1d987",
            kind: "activity-start", endpoint: "https://cp.example/", bearer: "t"
        ))
        XCTAssertEqual(start.httpMethod, "PUT")
        XCTAssertEqual(start.url?.absoluteString, "https://cp.example/device-tokens")
        let startObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(start.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(startObject.keys), ["token", "platform", "deviceName", "deviceId8", "kind"])
        XCTAssertEqual(startObject["kind"] as? String, "activity-start")

        let update = try XCTUnwrap(DeviceTokenUplink.request(
            tokenHex: "cd", platform: "iOS", deviceName: nil, deviceID8: "a4a1d987",
            kind: "activity-update", activityID: "act-1", endpoint: "https://cp.example", bearer: "t"
        ))
        let updateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(update.httpBody)) as? [String: Any])
        XCTAssertEqual(updateObject["kind"] as? String, "activity-update")
        XCTAssertEqual(updateObject["activityId"] as? String, "act-1")
        // The alert token's shape is untouched: no kind key at all.
        let alert = try XCTUnwrap(DeviceTokenUplink.request(
            tokenHex: "ef", platform: "iOS", deviceName: nil, deviceID8: "a4a1d987", endpoint: "https://cp.example", bearer: "t"
        ))
        let alertObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(alert.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(alertObject.keys), ["token", "platform", "deviceId8"])
    }

    func testUploadUsesTheTransportAndReportsOnlySuccess() async throws {
        let original = DeviceTokenUplink.transport
        defer { DeviceTokenUplink.transport = original }
        var seen: [URLRequest] = []
        var status: Int? = 200
        DeviceTokenUplink.transport = { request in
            seen.append(request)
            return status
        }
        let request = try XCTUnwrap(DeviceTokenUplink.request(
            tokenHex: "ab", platform: "iOS", deviceName: nil, kind: "activity-start",
            endpoint: "https://cp.example", bearer: "secret"
        ))
        let ok = await DeviceTokenUplink.upload(request, label: "activity-start")
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.value(forHTTPHeaderField: "authorization"), "Bearer secret")
        status = 500
        let failed = await DeviceTokenUplink.upload(request, label: "activity-start")
        XCTAssertFalse(failed)
        status = nil
        let dropped = await DeviceTokenUplink.upload(request, label: "activity-start")
        XCTAssertFalse(dropped)
        XCTAssertEqual(seen.count, 3)
    }

    // MARK: - Views

    /// Hosts the tile's views in a real window and forces layout — the same
    /// discipline as AgentViewRenderTests: a body that traps only traps when
    /// evaluated. No widget host is needed; the views are plain SwiftUI.
    private func render(_ view: some View, width: CGFloat) {
        #if os(macOS)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 160)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThan(window.frame.width, 2_000, "a tile view is demanding unbounded width")
        window.orderOut(nil)
        #else
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 160))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.isHidden = true
        #endif
    }

    func testTileViewsLayOutForEveryStatus() {
        let states: [FinActivityAttributes.ContentState] = [
            FinLiveActivityPlan.contentState(for: .working(siteName: "Levi's iMac"), now: t0),
            FinLiveActivityPlan.contentState(for: .needsInput(siteName: "Cloud computer"), now: t0),
            FinLiveActivityPlan.contentState(for: .asleep, now: t0),
            FinActivityAttributes.ContentState(
                headline: "Fin answered", detail: String(repeating: "evals passed, 212 of 212. ", count: 6),
                glyph: "checkmark.bubble", status: .answered, updatedAt: t0.timeIntervalSince1970
            ),
        ]
        for state in states {
            render(FinActivityLockScreenView(agentName: "Fin", state: state), width: 402)
            // The CarPlay Dashboard / Smart Stack small family is narrow.
            render(FinActivitySmallView(state: state), width: 180)
            render(HStack { FinActivityGlyph(state: state); FinActivityCompactTrailing(state: state) }, width: 120)
            render(FinActivityExpandedCenter(state: state), width: 260)
        }
        XCTAssertEqual(FinActivityCompactTrailing(state: states[1]).shortLabel, "Input")
    }
}
