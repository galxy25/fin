import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Registers this device's APNs token with the control plane (`PUT
/// /device-tokens`) so the headless cloud harness can reach this device:
/// fin-agentd POSTs `/notify`, and the Lambda fans the alert out over APNs to
/// every token stored there. The app's own cross-device pushes ride CloudKit
/// signals (`AgentSignalSubscriber`) and never touch that table — this path
/// exists for senders with no CloudKit access at all.
///
/// Called from `FinAppDelegate` on every registration callback, deliberately:
/// APNs rotates tokens (reinstall, restore, OS update), the callback fires on
/// every launch, and the server dedupes by token — so re-PUTting each launch is
/// the cheap way to stay current. Inert when the control plane isn't
/// configured, the same both-or-nothing gate as every other control-plane
/// client.
///
/// Same discipline as `CloudWorkerClient`: no log line here may carry the
/// endpoint, the bearer token, or the device token. Failures log a status code
/// at most — push registration is best-effort, and the next launch retries.
///
/// `@MainActor` because `UIDevice` is: the only caller is the app delegate's
/// registration callback, which already arrives on the main actor.
@MainActor
enum DeviceTokenUplink {
    private static let logger = Logger(subsystem: "dev.levischoen.fin", category: "DeviceTokenUplink")

    static func register(deviceToken: Data) {
        guard CloudControlPlaneConfig.isConfigured else { return }
        guard let request = request(
            tokenHex: hex(deviceToken),
            platform: platform,
            deviceName: deviceName,
            deviceID8: DeviceIdentity.short,
            endpoint: CloudControlPlaneConfig.endpointURL,
            bearer: CloudControlPlaneConfig.token
        ) else {
            logger.warning("device-token upload skipped: control plane URL is not a valid URL")
            return
        }
        Task { _ = await upload(request, label: "device-token") }
    }

    /// Live Activity tokens (design §3.4) ride the same route with a `kind`:
    /// `activity-start` for the per-device push-to-start token, `activity-update`
    /// for one running activity's update token (with its `activityId`). The
    /// control plane keeps them in the same table and out of the alert
    /// fan-out — see lambda.py `put_device_token` / `_push_live_activity`.
    /// Returns whether the upload landed, so the controller can log once.
    @discardableResult
    static func registerLiveActivityToken(_ token: Data, kind: String, activityID: String?) async -> Bool {
        guard CloudControlPlaneConfig.isConfigured else { return false }
        guard let request = request(
            tokenHex: hex(token),
            platform: platform,
            deviceName: deviceName,
            deviceID8: DeviceIdentity.short,
            kind: kind,
            activityID: activityID,
            endpoint: CloudControlPlaneConfig.endpointURL,
            bearer: CloudControlPlaneConfig.token
        ) else {
            logger.warning("\(kind) token upload skipped: control plane URL is not a valid URL")
            return false
        }
        return await upload(request, label: kind)
    }

    /// The one transport, replaceable in tests. Returns the HTTP status, or
    /// nil for a transport error. Logs a status code at most — never the
    /// token or the endpoint.
    static var transport: (URLRequest) async -> Int? = { request in
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Internal (not private) so a test can drive it through a stubbed `transport`.
    static func upload(_ request: URLRequest, label: String) async -> Bool {
        guard let status = await transport(request) else {
            logger.warning("\(label) token upload failed: network error")
            return false
        }
        guard (200..<300).contains(status) else {
            logger.warning("\(label) token upload failed: HTTP \(status)")
            return false
        }
        return true
    }

    // MARK: - Wire shape (pure, testable)

    /// The wire form of the token: APNs hands over opaque bytes; the contract is
    /// lowercase hex.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The `/device-tokens` contract: `{"token", "platform", "deviceName"?,
    /// "deviceId8"?, "kind"?, "activityId"?}`. `deviceName` is omitted when blank rather than sent
    /// empty. `deviceId8` is this device's `DeviceIdentity.short` — the same
    /// value `AppSiteClient` puts in `originDeviceID8` when it acks a turn it
    /// hosted as answered, which is how the control plane knows to leave THIS
    /// device's tokens out of that reply's fan-out (design §3.7.3).
    static func request(
        tokenHex: String,
        platform: String,
        deviceName: String?,
        deviceID8: String = "",
        kind: String? = nil,
        activityID: String? = nil,
        endpoint: String,
        bearer: String
    ) -> URLRequest? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/device-tokens") else { return nil }
        var object: [String: Any] = ["token": tokenHex, "platform": platform]
        let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { object["deviceName"] = trimmedName }
        if !deviceID8.isEmpty { object["deviceId8"] = deviceID8 }
        // Absent for the plain APNs alert token (the pre-Phase-2 shape, which the
        // control plane reads as kind "alert"); present for Live Activity tokens.
        if let kind, !kind.isEmpty { object["kind"] = kind }
        if let activityID, !activityID.isEmpty { object["activityId"] = activityID }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        // Same cold-start allowance as the other control-plane clients.
        request.timeoutInterval = 15
        return request
    }

    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "iOS"
        #endif
    }

    /// A human label for the settings/debug view of the token table; generic
    /// ("iPhone") on modern iOS without the entitlement, which is fine — it is
    /// a label, not an identifier.
    static var deviceName: String? {
        #if os(macOS)
        return Host.current().localizedName
        #else
        return UIDevice.current.name
        #endif
    }
}
