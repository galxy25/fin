import Foundation

/// Device-local address of the serverless control plane that launches cloud
/// workers on demand (`CloudWorkerClient`): the API Gateway endpoint and the
/// bearer token it authenticates with.
///
/// Device-WIDE, not per-agent like `CloudAgentConfig`: the agent is named in the
/// request body, so one control plane serves every cloud-hosted agent here.
///
/// UserDefaults only, never the synced store — same reasoning as
/// `RemoteSupervisionConfig`: the token is a capability grant (it launches EC2
/// instances), not portable configuration, and syncing it would hand every
/// device, present and future, the right to spend money.
enum CloudControlPlaneConfig {
    static let endpointURLKey = "fin.cloudcp.endpointURL"
    static let tokenKey = "fin.cloudcp.token"

    static var endpointURL: String {
        UserDefaults.standard.string(forKey: endpointURLKey) ?? ""
    }
    static var token: String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    /// Both halves or nothing: an endpoint without a token only earns 401s, and
    /// a token without an endpoint has nowhere to go.
    static var isConfigured: Bool { !endpointURL.isEmpty && !token.isEmpty }

    static func setEndpointURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: endpointURLKey)
    }

    static func setToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
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
