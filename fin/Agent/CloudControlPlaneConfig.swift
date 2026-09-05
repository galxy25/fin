import Foundation

/// Device-WIDE address of the serverless control plane that launches cloud
/// workers on demand (`CloudWorkerClient`): the API Gateway endpoint and the
/// bearer token it authenticates with. Device-wide, not per-agent like
/// `CloudAgentConfig` — the agent is named in the request body, so one control
/// plane serves every cloud-hosted agent here.
///
/// Both halves sync across the user's devices (Levi's directive: "all agent and
/// server config should sync via icloud" — a phone with no control-plane config
/// next to a fully configured Mac is exactly the failure this ends), each by the
/// storage class that fits it:
/// - The ENDPOINT URL is non-secret configuration, so it rides iCloud Key-Value
///   Storage via `SyncedDeviceConfig` with UserDefaults as the local cache every
///   read hits.
/// - The TOKEN is a capability grant (it launches EC2 instances), so it rides
///   the iCloud-synchronizable keychain (`KeychainStore.saveDeviceSecret`) —
///   end-to-end encrypted, offered only to the user's signed-in devices — and
///   never KVS, SwiftData, or CloudKit records, all plaintext to the server.
enum CloudControlPlaneConfig {
    static let endpointURLKey = "fin.cloudcp.endpointURL"
    static let tokenKey = "fin.cloudcp.token"

    /// Posted when `SyncedDeviceConfig`'s pull adopts an externally changed
    /// endpoint, so UI showing the redacted value can refresh without a relaunch.
    static let changedNotification = Notification.Name("fin.cloudcp.configurationChanged")

    /// Local-cache read; `SyncedDeviceConfig` keeps the cache current with the
    /// account (setter push, launch pull, external-change pull).
    static var endpointURL: String {
        UserDefaults.standard.string(forKey: endpointURLKey) ?? ""
    }

    /// Synced keychain first. A legacy plaintext UserDefaults value (pre-sync
    /// builds) is promoted INTO the keychain on first read — one-way, and only
    /// into an EMPTY keychain slot, since a keychain read that succeeds returns
    /// before the legacy value is even consulted; a non-empty synced token is
    /// never clobbered by a local one. The plaintext copy is deleted once the
    /// keychain holds it: the local keychain replica IS the local cache (reads
    /// never wait on iCloud), and a lingering plaintext token would outlive
    /// rotation. When the keychain refuses writes (unsigned test host,
    /// iCloud-less CI) the value simply stays in UserDefaults — local-only,
    /// degraded, silent.
    static var token: String {
        if let synced = KeychainStore.loadDeviceSecret(forKey: tokenKey) {
            // A pre-sync plaintext copy can survive here when keychain sync
            // delivered the item from another device before this one's first
            // read (so promotion never ran). It lost; retire it.
            if UserDefaults.standard.string(forKey: tokenKey) != nil {
                UserDefaults.standard.removeObject(forKey: tokenKey)
            }
            return synced
        }
        let legacy = UserDefaults.standard.string(forKey: tokenKey) ?? ""
        guard !legacy.isEmpty else { return "" }
        do {
            try KeychainStore.saveDeviceSecret(legacy, forKey: tokenKey)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        } catch {
            // Degraded mode: no entitled keychain. The defaults value keeps this
            // device working; promotion retries on the next read.
        }
        return legacy
    }

    /// Both halves or nothing: an endpoint without a token only earns 401s, and
    /// a token without an endpoint has nowhere to go.
    static var isConfigured: Bool { !endpointURL.isEmpty && !token.isEmpty }

    static func setEndpointURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: endpointURLKey)
        SyncedDeviceConfig.push(url, forKey: endpointURLKey)
    }

    static func setToken(_ token: String) {
        do {
            try KeychainStore.saveDeviceSecret(token, forKey: tokenKey)
            // The keychain owns it now (an empty save deletes account-wide);
            // drop any plaintext copy a pre-sync build left behind.
            UserDefaults.standard.removeObject(forKey: tokenKey)
        } catch {
            // Degraded mode (see `token`): keep the pre-sync behavior so the
            // feature still works on this device alone.
            UserDefaults.standard.set(token, forKey: tokenKey)
        }
    }

    /// Editor display form for the token. `RemoteSupervisionConfig.redactedDisplay`
    /// is URL-shaped and renders a bare token as "(unparseable URL)"; the token
    /// carries no host to show, so only its tail is — enough to tell two tokens
    /// apart, never enough to use one.
    static func redactedToken(_ token: String) -> String {
        guard !token.isEmpty else { return "not set" }
        return token.count > 4 ? "set (…\(token.suffix(4)))" : "set"
    }
}
