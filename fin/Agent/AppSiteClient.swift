import Foundation
import SwiftUI

/// This app install as a site (docs/SITES.md §3.2 "App", §11 Phase 2/3): it
/// enrolls itself once (`app/<DeviceIdentity.id>`, kind `app`, priority 1),
/// heartbeats while the app is active, and — Phase 3 — claims messages pinned
/// or targeted to this device from its own queue and submits them to the local
/// runtime, retiring the CloudKit relay for dispatch whenever a control plane
/// is configured.
///
/// The site token is a device-LOCAL keychain item, never synced: a token
/// authenticates one body, and two devices sharing one would look like a
/// single site flapping between machines.
@MainActor
final class AppSiteClient: ObservableObject {
    static let heartbeatSeconds: UInt64 = 20
    static let siteIDKey = "fin.site.id"
    static let siteTokenKey = "fin.site.token"
    static let claimLeaseSeconds = 120

    struct Target {
        let agentID: UUID
        let agentName: String
        let submit: (String) -> Bool
        let isBusy: () -> Bool
        let needsInput: () -> Bool
        /// (assistant messages so far, the newest assistant text) — no timestamps on
        /// transcript messages, so "a reply landed" is "the count went up".
        let assistantReplies: () -> (count: Int, latest: String)
    }

    /// The daemon-shaped ledger, in memory: the app is foreground-only, so an
    /// unacked id that dies with the process is re-offered after its lease.
    private(set) var held: [(id: String, text: String, repliesAtSubmit: Int?)] = []
    private var answered = Set<String>()

    @Published private(set) var siteID: String?
    @Published private(set) var role: String = "standby"
    @Published private(set) var lastError: String?

    /// Where the local runtime lives; nil = this app hosts nothing right now.
    var targetProvider: () -> Target? = { nil }
    var audit: (String) -> Void = { _ in }
    private var loop: Task<Void, Never>?
    private var siteToken: String?

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        UIDevice.current.name
        #endif
    }

    func start() {
        guard loop == nil, CloudControlPlaneConfig.isConfigured else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.beat()
                try? await Task.sleep(nanoseconds: Self.heartbeatSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - Enrollment

    private func ensureEnrolled(agentName: String) async -> Bool {
        if siteID == nil {
            siteID = UserDefaults.standard.string(forKey: Self.siteIDKey)
            siteToken = KeychainStore.loadLocalSecret(forKey: Self.siteTokenKey)
        }
        if let siteID, siteToken != nil, !siteID.isEmpty { return true }
        let body: [String: Any] = [
            "agent": agentName, "kind": "app", "displayName": Self.deviceName,
            "enrollKey": "app/\(DeviceIdentity.id)", "siteId": DeviceIdentity.id,
        ]
        guard case .success((let status, let data)) = await ControlPlaneClient.perform(
            ControlPlaneClient.request("POST", path: "/sites/enroll", body: body)
        ), (200...299).contains(status) || status == 409,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            lastError = "could not enroll this device"
            return false
        }
        // 409 = our siteId exists under another enrollKey (a reinstall); re-enroll
        // by enrollKey instead, which rotates the token and keeps the row.
        if status == 409 {
            var again = body
            again.removeValue(forKey: "siteId")
            guard case .success((let s2, let d2)) = await ControlPlaneClient.perform(
                ControlPlaneClient.request("POST", path: "/sites/enroll", body: again)
            ), (200...299).contains(s2),
                  let o2 = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any]
            else { lastError = "could not re-enroll this device"; return false }
            return adopt(o2)
        }
        return adopt(object)
    }

    private func adopt(_ object: [String: Any]) -> Bool {
        guard let id = object["siteId"] as? String, let token = object["siteToken"] as? String else { return false }
        siteID = id
        siteToken = token
        UserDefaults.standard.set(id, forKey: Self.siteIDKey)
        try? KeychainStore.saveLocalSecret(token, forKey: Self.siteTokenKey)
        audit("[site] enrolled this device as \(Self.deviceName) (\(id.prefix(8)))")
        return true
    }

    // MARK: - Heartbeat + claims

    /// The agent this device speaks for when it hosts no runtime: Fin, the one
    /// conversation. A phone with no live terminal still IS a site — it shows in
    /// Fin's Computers and in presence, it just claims nothing.
    var defaultAgentName = "Fin"

    func beat() async {
        let target = targetProvider()
        guard await ensureEnrolled(agentName: target?.agentName ?? defaultAgentName), let siteID, let siteToken else { return }
        guard let target else {
            let body: [String: Any] = [
                "schema": 2, "state": "idle", "wantsPrimary": false, "held": [], "unacked": [],
                "capabilities": ["kind": "app", "hosts_runtime": false,
                                 "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""],
            ]
            if let (status, _) = await siteRequest("POST", "/sites/\(siteID)/heartbeat", body: body, siteID: siteID, token: siteToken),
               !(200...299).contains(status) {
                lastError = "heartbeat HTTP \(status)"
                if status == 401 { forgetIdentity() }
            } else {
                lastError = nil
            }
            return
        }
        // Answered acks first: a reply that landed since the last beat.
        let replies = target.assistantReplies()
        for index in held.indices.reversed() {
            let entry = held[index]
            guard let atSubmit = entry.repliesAtSubmit, !answered.contains(entry.id),
                  replies.count > atSubmit, !target.isBusy() else { continue }
            answered.insert(entry.id)
            // The control plane pushes a `fin.reply` notification to the user's
            // OTHER devices on this ack: `originDeviceID8` names this device (it
            // hosted the turn and already showed the reply — its local banner or
            // the visible conversation), so its own tokens — registered with the
            // same `deviceId8` by `DeviceTokenUplink` — are left out of the
            // fan-out. `agentID` is what lets a tap deep-link and a typed Reply be
            // addressed on the receiving device (`AgentNotificationService`).
            // Belt and braces: mark the id BEFORE the ack goes out so, if a token
            // registered by an older build still echoes the push back here,
            // `AgentNotificationService.willPresent` drops it.
            AgentNotificationService.shared.markSurfacedLocally(messageID: entry.id)
            _ = await siteRequest("POST", "/messages/\(entry.id)/ack",
                                  body: Self.answeredAckBody(replyPreview: replies.latest, agentID: target.agentID),
                                  siteID: siteID, token: siteToken)
            held.remove(at: index)
        }
        let state = target.needsInput() ? "needs-input" : (target.isBusy() ? "working" : "idle")
        let body: [String: Any] = [
            "schema": 2, "state": state, "wantsPrimary": true,
            "held": held.filter { $0.repliesAtSubmit == nil }.map(\.id),
            "unacked": [],
            "capabilities": ["kind": "app", "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""],
        ]
        guard let (status, data) = await siteRequest("POST", "/sites/\(siteID)/heartbeat", body: body, siteID: siteID, token: siteToken) else { return }
        guard (200...299).contains(status) else {
            if status == 401 { forgetIdentity() }
            lastError = "heartbeat HTTP \(status)"
            return
        }
        lastError = nil
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        role = object["role"] as? String ?? "standby"
        for offer in object["messages"] as? [[String: Any]] ?? [] {
            guard let id = offer["id"] as? String, let text = offer["text"] as? String,
                  !held.contains(where: { $0.id == id }) else { continue }
            guard let (claimStatus, _) = await siteRequest("POST", "/messages/\(id)/claim",
                                                            body: ["leaseSeconds": Self.claimLeaseSeconds],
                                                            siteID: siteID, token: siteToken),
                  (200...299).contains(claimStatus) else { continue }
            // The SAME path a typed message takes; a rejection leaves the claim to lapse.
            let before = target.assistantReplies().count
            guard target.submit(text) else { continue }
            held.append((id: id, text: text, repliesAtSubmit: before))
            _ = await siteRequest("POST", "/messages/\(id)/ack", body: ["state": "applied"], siteID: siteID, token: siteToken)
            audit("[site] applied message \(id.prefix(10)) from the control plane")
        }
    }

    /// The answered ack: `{state, replyPreview, agentID, originDeviceID8}` — the
    /// same shape the daemon's `DaemonSiteClient.answeredAckBody` sends, so the
    /// control plane's reply push is identical whichever body answered. Pure.
    nonisolated static func answeredAckBody(
        replyPreview: String, agentID: UUID, originDeviceID8: String = DeviceIdentity.short
    ) -> [String: Any] {
        [
            "state": "answered",
            "replyPreview": String(replyPreview.prefix(500)),
            "agentID": agentID.uuidString,
            "originDeviceID8": originDeviceID8,
        ]
    }

    /// Token revoked (retired in the app, or re-enrolled elsewhere): forget it and
    /// enroll afresh next beat.
    private func forgetIdentity() {
        siteID = nil; siteToken = nil
        UserDefaults.standard.removeObject(forKey: Self.siteIDKey)
        try? KeychainStore.saveLocalSecret("", forKey: Self.siteTokenKey)
    }

    private func siteRequest(_ method: String, _ path: String, body: [String: Any], siteID: String, token: String) async -> (Int, Data)? {
        guard var request = ControlPlaneClient.request(method, path: path, body: body) else { return nil }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(siteID, forHTTPHeaderField: "X-Fin-Site")
        guard case .success(let result) = await ControlPlaneClient.perform(request) else { return nil }
        return result
    }
}
