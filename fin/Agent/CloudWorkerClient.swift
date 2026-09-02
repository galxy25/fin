import Foundation

/// Launches a CLOUD-hosted agent's harness on demand: one POST to the control
/// plane (`CloudControlPlaneConfig`), which starts a per-agent EC2 worker.
///
/// Fire-and-forget on purpose — nothing here polls the worker's lifecycle. The
/// harness's transcript showing up in the remote console (`CloudAgentChannel`)
/// is the confirmation that it booted, so this call answers only whether the
/// launch was accepted, already satisfied, or refused.
enum CloudWorkerClient {
    /// `.failed`'s text renders in the console, so it must never carry the
    /// endpoint or the token: both are credentials, and a control-plane error
    /// body is the only untrusted string that reaches it.
    enum Outcome: Equatable {
        case started(instanceType: String)
        case alreadyRunning
        case notConfigured
        case failed(String)
    }

    static func requestWorker(agentName: String) async -> Outcome {
        guard CloudControlPlaneConfig.isConfigured else { return .notConfigured }
        var base = CloudControlPlaneConfig.endpointURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/workers") else {
            return .failed("control plane URL is not a valid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": agentName])
        // Longer than the transcript fetch: the Lambda runs a RunInstances call
        // before it answers, and a launch that took must not read as a failure.
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return outcome(status: nil, body: nil)
        }
        return outcome(status: (response as? HTTPURLResponse)?.statusCode, body: data)
    }

    /// The response table, split out pure so every branch is testable without a
    /// server. A body that isn't the documented JSON degrades to the status code
    /// rather than surfacing raw bytes to the console.
    static func outcome(status: Int?, body: Data?) -> Outcome {
        guard let status else { return .failed("network error") }
        let fields = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        switch status {
        case 200, 201:
            // A launch that omits the instance type is still a launch.
            return .started(instanceType: fields?["instanceType"] as? String ?? "unknown")
        case 409:
            return .alreadyRunning
        default:
            let message = (fields?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .failed(message ?? "HTTP \(status)")
        }
    }
}
