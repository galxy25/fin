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
            endpoint: CloudControlPlaneConfig.endpointURL,
            bearer: CloudControlPlaneConfig.token
        ) else {
            logger.warning("device-token upload skipped: control plane URL is not a valid URL")
            return
        }
        Task {
            guard let (_, response) = try? await URLSession.shared.data(for: request) else {
                logger.warning("device-token upload failed: network error")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                logger.warning("device-token upload failed: HTTP \(status)")
                return
            }
        }
    }

    // MARK: - Wire shape (pure, testable)

    /// The wire form of the token: APNs hands over opaque bytes; the contract is
    /// lowercase hex.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The `/device-tokens` contract: `{"token", "platform", "deviceName"?}`.
    /// `deviceName` is omitted when blank rather than sent empty.
    static func request(
        tokenHex: String,
        platform: String,
        deviceName: String?,
        endpoint: String,
        bearer: String
    ) -> URLRequest? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/device-tokens") else { return nil }
        var object: [String: Any] = ["token": tokenHex, "platform": platform]
        let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { object["deviceName"] = trimmedName }
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
