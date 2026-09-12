import XCTest
@testable import fin

/// The pure halves of the sites/messages client (docs/SITES.md Phase 1d):
/// the presence fold, the observation lines the memory view and compactor
/// share, the response decoders, the pending-row state table, and the mirror
/// merge's dedupe/collapse. No network, no ModelContainer.
final class SitesAndMessagesTests: XCTestCase {
    private func site(
        _ name: String, id8: String = "abcd1234", kind: String = "resident", state: String = "idle",
        live: Bool = true, sessions: [FinSite.Capabilities.TmuxSession]? = nil, beat: Date? = Date()
    ) -> FinSite {
        let json: [String: Any] = [
            "siteId": "\(id8)-0000-4000-8000-000000000000", "siteId8": id8, "agent": "Fin",
            "kind": kind, "displayName": name, "priority": 100, "state": state, "live": live,
            "capabilities": [:] as [String: Any],
        ]
        var decoded = try! ControlPlaneClient.decoder.decode(FinSite.self, from: JSONSerialization.data(withJSONObject: json))
        if sessions != nil || beat != nil {
            // Re-decode with the extras present; simpler than a memberwise init on a Decodable.
            var withExtras = json
            if let beat { withExtras["lastHeartbeatAt"] = ISO8601DateFormatter().string(from: beat) }
            if let sessions {
                withExtras["capabilities"] = ["tmux_sessions": sessions.map { s -> [String: Any] in
                    var d: [String: Any] = ["session": s.session]
                    if let note = s.activityNote { d["activity_note"] = note }
                    if let panes = s.panes {
                        d["panes"] = panes.map { p -> [String: Any] in
                            var pd: [String: Any] = ["target": p.target]
                            if let t = p.title { pd["title"] = t }
                            if let c = p.command { pd["command"] = c }
                            if let w = p.cwd { pd["cwd"] = w }
                            return pd
                        }
                    }
                    return d
                }]
            }
            decoded = try! ControlPlaneClient.decoder.decode(FinSite.self, from: JSONSerialization.data(withJSONObject: withExtras))
        }
        return decoded
    }

    private func pane(_ target: String, title: String? = nil, command: String? = nil, cwd: String? = nil) -> FinSite.Capabilities.TmuxSession.Pane {
        let json: [String: Any?] = ["target": target, "title": title, "command": command, "cwd": cwd]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(FinSite.Capabilities.TmuxSession.Pane.self, from: data)
    }

    private func session(_ name: String, panes: [FinSite.Capabilities.TmuxSession.Pane] = [], note: String? = nil) -> FinSite.Capabilities.TmuxSession {
        var json: [String: Any] = ["session": name, "panes": panes.map { p -> [String: Any] in
            var d: [String: Any] = ["target": p.target]
            if let t = p.title { d["title"] = t }
            if let c = p.command { d["command"] = c }
            if let w = p.cwd { d["cwd"] = w }
            return d
        }]
        if let note { json["activity_note"] = note }
        return try! JSONDecoder().decode(FinSite.Capabilities.TmuxSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - FinPresence

    func testPresenceFoldOrdersNeedsInputOverWorkingOverIdle() {
        let imac = site("Levi's iMac", id8: "aaaaaaaa", state: "working")
        let cloud = site("Cloud computer", id8: "bbbbbbbb", kind: "ec2", state: "needs-input")
        XCTAssertEqual(FinPresence.fold([imac, cloud]), .needsInput(siteName: "Cloud computer"))
        XCTAssertEqual(FinPresence.fold([imac]), .working(siteName: "Levi's iMac"))
        XCTAssertEqual(FinPresence.fold([site("x", state: "idle")]), .idle)
    }

    func testPresenceIsAsleepWhenNoSiteIsLive() {
        XCTAssertEqual(FinPresence.fold([]), .asleep)
        XCTAssertEqual(FinPresence.fold([site("dead", state: "working", live: false)]), .asleep)
        XCTAssertEqual(FinPresence.fold([site("gone", state: "retired", live: true)]), .asleep)
    }

    func testPresenceHeadlinesNeverNameAComputerExceptInTheDetail() {
        let presence = FinPresence.working(siteName: "Levi's iMac")
        XCTAssertEqual(presence.headline, "Fin is working")
        XCTAssertEqual(presence.detail, "on Levi's iMac")
        XCTAssertNil(FinPresence.asleep.detail)
    }

    // MARK: - Observation lines (what the memory view shows and the compactor reads)

    func testObservationLinesNameEachPaneByItsTitle() {
        let now = Date()
        let imac = site("Levi's iMac", state: "working", sessions: [
            session("main", panes: [
                pane("main:0.0", title: "Resume from last work point", command: "node", cwd: "/Users/x/forges/levi/pocketdj"),
                pane("main:1.0", title: "multi-tenancy-cloud-control-plane", cwd: "/Users/x/forges/levi/fin"),
                pane("main:2.0", command: "fish", cwd: "/Users/x/scratch"),
            ], note: "Deploying the sites control plane"),
        ], beat: now.addingTimeInterval(-120))
        let lines = SiteDirectory.observationLines([imac], now: now)
        XCTAssertEqual(lines, [
            "Levi's iMac (working, 2m ago): main:0.0 pocketdj — Resume from last work point",
            "Levi's iMac (working, 2m ago): main:1.0 fin — multi-tenancy-cloud-control-plane",
            "Levi's iMac (working, 2m ago): main:2.0 scratch — fish",
            "Levi's iMac (working, 2m ago): main note — Deploying the sites control plane",
        ])
    }

    func testObservationLinesOmitRetiredAndDateOfflineSites() {
        let now = Date()
        let offline = site("Old box", state: "stale", live: false, beat: now.addingTimeInterval(-7200))
        let retired = site("Gone", state: "retired", live: false)
        let lines = SiteDirectory.observationLines([offline, retired], now: now)
        XCTAssertEqual(lines, ["Old box (offline, last seen 2h ago)"])
    }

    // MARK: - Decoders

    func testSitesResponseDecodesWithMinimalCapabilities() throws {
        let body = """
        {"generatedAt":"2026-09-12T14:00:00Z","sites":[{"siteId":"a4a1d987-0000-4000-8000-000000000000",
        "siteId8":"a4a1d987","agent":"Fin","kind":"resident","displayName":"Levi's iMac","priority":100,
        "state":"idle","live":true,"lastHeartbeatAt":"2026-09-12T13:59:50Z","capabilities":{"daemon_version":"1.5.0"}}]}
        """.data(using: .utf8)!
        guard case .success(let sites) = ControlPlaneClient.decode(ControlPlaneClient.SitesResponse.self, status: 200, body: body).map(\.sites) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].capabilities.daemonVersion, "1.5.0")
        XCTAssertNil(sites[0].capabilities.tmuxSessions)
        XCTAssertEqual(sites[0].statusLabel, "online")
    }

    func testDecodeSurfacesTheServersErrorStringWithoutTheEndpoint() {
        let body = #"{"error":"agent must match [A-Za-z0-9]"}"#.data(using: .utf8)!
        guard case .failure(let failure) = ControlPlaneClient.decode(ControlPlaneClient.SitesResponse.self, status: 400, body: body) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(failure, .http(400, "agent must match [A-Za-z0-9]"))
        XCTAssertEqual(ControlPlaneClient.errorMessage(status: 503, body: Data("<html>".utf8)), "HTTP 503")
    }

    func testMessageDecodesTheRoutingFields() throws {
        let body = """
        {"messageId":"m-1","agent":"Fin","text":"hi","source":"app","createdAt":"2026-09-12T14:00:00Z",
        "state":"queued","routedBy":"clarify","clarifyCandidates":["Levi's iMac","Cloud computer"]}
        """.data(using: .utf8)!
        guard case .success(let message) = ControlPlaneClient.decode(ControlPlaneClient.Message.self, status: 200, body: body) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(message.routedBy, "clarify")
        XCTAssertEqual(message.clarifyCandidates, ["Levi's iMac", "Cloud computer"])
        XCTAssertEqual(AgentRemoteConsoleView.pendingState(for: message), .queued)
    }

    func testPendingStateTable() throws {
        func message(_ state: String) -> ControlPlaneClient.Message {
            try! ControlPlaneClient.decoder.decode(ControlPlaneClient.Message.self, from: #"{"messageId":"m-1","state":"\#(state)"}"#.data(using: .utf8)!)
        }
        XCTAssertEqual(AgentRemoteConsoleView.pendingState(for: message("claimed")), .claimed)
        XCTAssertEqual(AgentRemoteConsoleView.pendingState(for: message("applied")), .applied)
        XCTAssertEqual(AgentRemoteConsoleView.pendingState(for: message("answered")), .answered)
        XCTAssertEqual(AgentRemoteConsoleView.pendingState(for: message("expired")), .queued)
    }

    func testMessageIDsAreMintedInTheDesignsShape() {
        let id = ControlPlaneClient.newMessageID()
        XCTAssertTrue(id.hasPrefix("m-"))
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotEqual(id, ControlPlaneClient.newMessageID())
    }

    // MARK: - Mirror merge

    private func record(_ id: String, kind: AgentLogKind = .userMessage, text: String = "t", at: TimeInterval, site: String? = nil, name: String? = nil, replyTo: String? = nil) -> AgentMirrorRecord {
        AgentMirrorRecord(id: id, kind: kind, text: text, timestamp: Date(timeIntervalSince1970: at), sequence: 0, runID: id, siteID8: site, siteName: name, inReplyTo: replyTo)
    }

    func testMergeDropsTheSameIDSeenTwice() {
        let merged = AgentMirrorReader.merge([[record("a", at: 1)], [record("a", at: 1), record("b", at: 2)]])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
    }

    func testMergeCollapsesAMessageAppliedByTwoBodiesAndSaysSo() {
        // §6.4's one at-least-once window: stated, not hidden.
        let merged = AgentMirrorReader.merge([[
            record("x", text: "deploy it", at: 10, site: "aaaaaaaa", name: "Levi's iMac", replyTo: "m-1"),
            record("y", text: "deploy it", at: 12, site: "bbbbbbbb", name: "Cloud computer", replyTo: "m-1"),
            record("z", kind: .assistantMessage, text: "done", at: 13, site: "aaaaaaaa"),
        ]])
        XCTAssertEqual(merged.map(\.id), ["x", "z"])
        XCTAssertEqual(merged[0].text, "deploy it\n(handled by Levi's iMac and Cloud computer)")
    }

    func testOldLinesWithoutSiteFieldsStillDecode() {
        let line = #"{"kind":"assistantMessage","text":"hello","timestamp":"2026-09-12T14:00:00Z","sequence":3,"run_id":"r"}"#
        let record = AgentMirrorRecord(jsonlLine: line)
        XCTAssertNotNil(record)
        XCTAssertNil(record?.siteID8)
        XCTAssertNil(record?.inReplyTo)
        let withSite = AgentMirrorRecord(jsonlLine: #"{"kind":"userMessage","text":"x","timestamp":"2026-09-12T14:00:00Z","site_id8":"a4a1d987","site_name":"Levi's iMac","in_reply_to":"m-9"}"#)
        XCTAssertEqual(withSite?.siteName, "Levi's iMac")
        XCTAssertEqual(withSite?.inReplyTo, "m-9")
    }
}
