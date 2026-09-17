import Foundation
import CloudKit
import CryptoKit

/// What this device's iCloud sync looks like from the outside, for the app site's
/// heartbeat.
///
/// WHY THIS EXISTS: on 2026-09-17 a server created on the iPhone would not appear on
/// any other device, and answering "why" took hours — because the control plane could
/// see every device was alive and nothing about whether they could sync. The heartbeat
/// proves an app is talking to the CONTROL PLANE, which is bearer-token auth; the
/// server list travels over CLOUDKIT, which is the iCloud account. Two devices can be
/// perfectly live and perfectly unable to exchange a row, and until now that was
/// invisible from anywhere but the device itself.
///
/// `accountFingerprint` is the piece that answers it in one query: the ubiquity
/// identity token hashed to 8 hex characters. Two devices on the SAME iCloud account
/// produce the SAME fingerprint; different accounts differ; no Apple ID, and nothing
/// reversible, leaves the device. "Are these two on the same account?" stops being a
/// guess.
enum CloudSyncTelemetry {
    /// Cheap enough for a 20s heartbeat: the token is a local property-list read, the
    /// hash is over a handful of bytes, and the account status is cached by the
    /// framework. Nothing here does a network round trip.
    @MainActor
    static func capabilities() -> [String: Any] {
        var fields: [String: Any] = [:]
        fields["icloud_account"] = accountFingerprint ?? "none"
        let monitor = CloudSyncActivityMonitor.shared
        fields["icloud_partial_failures"] = monitor.partialFailureCount
        switch monitor.activity {
        case .idle:
            fields["icloud_sync"] = "idle"
        case .inFlight:
            fields["icloud_sync"] = "in-flight"
        case .succeeded:
            fields["icloud_sync"] = "ok"
        case .degraded:
            fields["icloud_sync"] = "partial-failure"
        case .failed:
            fields["icloud_sync"] = "failed"
        }
        if let detail = monitor.lastErrorDescription {
            fields["icloud_last_error"] = String(detail.prefix(160))
        }
        return fields
    }

    /// Stable per iCloud account, per this app's sandbox. nil when no account is
    /// signed in — which is itself the answer to a sync question.
    static var accountFingerprint: String? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
            return nil
        }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The account's own state, fetched off the heartbeat path since it can block.
    static func accountStatus() async -> String {
        guard let status = try? await CKContainer(identifier: "iCloud.dev.levischoen.fin").accountStatus() else {
            return "unknown"
        }
        switch status {
        case .available: return "available"
        case .noAccount: return "no-account"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "could-not-determine"
        case .temporarilyUnavailable: return "temporarily-unavailable"
        @unknown default: return "unknown"
        }
    }
}
