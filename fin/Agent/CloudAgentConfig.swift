import Foundation

/// Device-local capability URLs for a CLOUD-hosted agent (`AgentHostingMode.cloud`):
/// the presigned S3 GET the remote console reads the harness's rolling transcript
/// from, and the presigned PUT/GET pair the composer appends inbox messages
/// through. UserDefaults only, keyed per agent, never the synced store — same
/// reasoning as `RemoteSupervisionConfig`: a presigned URL is a capability grant,
/// and syncing it would hand every device (and every future device) the bucket key.
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
}
