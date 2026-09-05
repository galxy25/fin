import Foundation

/// Device-local capability URLs for a CLOUD-hosted agent (`AgentHostingMode.cloud`):
/// the presigned S3 GET the remote console reads the harness's rolling transcript
/// from, and the presigned PUT/GET pair the composer appends inbox messages
/// through. UserDefaults only, keyed per agent, never synced — deliberately
/// exempt from the device-config sync (`SyncedDeviceConfig`): a presigned URL is
/// a short-lived per-device capability grant that any device re-vends on demand
/// through `POST /presign` once the SYNCED control-plane pair
/// (`CloudControlPlaneConfig`) lands, so syncing one would be pointless where it
/// matters and would still hand every device the bucket key in plaintext KVS.
enum CloudAgentConfig {
    private static func transcriptKey(_ agentID: UUID) -> String {
        "fin.cloud.transcriptURL.\(agentID.uuidString)"
    }
    private static func inboxGetKey(_ agentID: UUID) -> String {
        "fin.cloud.inboxGetURL.\(agentID.uuidString)"
    }
    private static func inboxPutKey(_ agentID: UUID) -> String {
        "fin.cloud.inboxPutURL.\(agentID.uuidString)"
    }
    /// When the last vended set of URLs is stated to expire (seconds since 1970). Only
    /// an upper bound: a presigned URL signed by the Lambda role dies with that role's
    /// temporary credentials, often before this stamp — the 403-retry path is what
    /// actually catches a URL that died early. Stored so `needsRefresh` can skip a URL
    /// already known to be past its stated life instead of paying a guaranteed-403.
    private static func expiresAtKey(_ agentID: UUID) -> String {
        "fin.cloud.urlExpiresAt.\(agentID.uuidString)"
    }

    static func transcriptURL(agentID: UUID) -> String {
        UserDefaults.standard.string(forKey: transcriptKey(agentID)) ?? ""
    }
    static func inboxGetURL(agentID: UUID) -> String {
        UserDefaults.standard.string(forKey: inboxGetKey(agentID)) ?? ""
    }
    static func inboxPutURL(agentID: UUID) -> String {
        UserDefaults.standard.string(forKey: inboxPutKey(agentID)) ?? ""
    }

    static func setTranscriptURL(_ url: String, agentID: UUID) {
        UserDefaults.standard.set(url, forKey: transcriptKey(agentID))
    }
    static func setInboxGetURL(_ url: String, agentID: UUID) {
        UserDefaults.standard.set(url, forKey: inboxGetKey(agentID))
    }
    static func setInboxPutURL(_ url: String, agentID: UUID) {
        UserDefaults.standard.set(url, forKey: inboxPutKey(agentID))
    }

    static func expiresAt(agentID: UUID) -> Date? {
        let stamp = UserDefaults.standard.double(forKey: expiresAtKey(agentID))
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// True when there is no usable URL yet, or the vended set is past its stated
    /// expiry. A present-but-secretly-dead URL still reads as fresh here on purpose —
    /// the 403 retry at the call site is what recovers a credential that died before
    /// its stamp. Used to refresh proactively before a request that would otherwise
    /// certainly fail.
    static func needsRefresh(agentID: UUID, now: Date = Date()) -> Bool {
        if transcriptURL(agentID: agentID).isEmpty || inboxPutURL(agentID: agentID).isEmpty {
            return true
        }
        if let expiresAt = expiresAt(agentID: agentID), expiresAt <= now { return true }
        return false
    }

    /// Writes a freshly vended set of URLs and their expiry together. Only a non-nil
    /// URL overwrites, so a partial vend never blanks a field the app still relies on.
    /// Like the individual setters this posts no notification — the console view
    /// re-reads these on its next refresh tick.
    static func applyPresigned(
        transcriptGet: String?, inboxGet: String?, inboxPut: String?,
        expiresAt: Date?, agentID: UUID
    ) {
        if let transcriptGet { setTranscriptURL(transcriptGet, agentID: agentID) }
        if let inboxGet { setInboxGetURL(inboxGet, agentID: agentID) }
        if let inboxPut { setInboxPutURL(inboxPut, agentID: agentID) }
        if let expiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: expiresAtKey(agentID))
        }
    }
}
