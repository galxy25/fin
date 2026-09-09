import Foundation

/// The app's half of "a second filesystem apart from the iOS native one": PUT/GET/DELETE
/// one plain-text file, or list them all, through the control plane's `/artifacts`
/// routes — same authenticated bearer-token relay `CloudWorkerClient`/`AgentMemorySyncService`
/// use, no presigned URL. One flat, shared space per Fin account
/// (`ARTIFACT_PREFIX` in `lambda.py`) — not scoped per agent, since any agent's tools can
/// write here — reachable from both the daemon (`DaemonArtifactClient`, the tool-calling
/// half) and this browser (the human-facing half).
enum ArtifactsClient {
    static let requestTimeout: TimeInterval = 15

    struct Entry: Identifiable, Equatable {
        let path: String
        let size: Int
        var id: String { path }
    }

    enum ListOutcome: Equatable {
        case found([Entry])
        case notConfigured
        case failed(String)
    }

    enum ReadOutcome: Equatable {
        case found(String)
        case notFound
        case notConfigured
        case failed(String)
    }

    enum WriteOutcome: Equatable {
        case saved(size: Int)
        case notConfigured
        case failed(String)
    }

    enum DeleteOutcome: Equatable {
        case deleted
        case notConfigured
        case failed(String)
    }

    static func list() async -> ListOutcome {
        guard let httpRequest = request(path: "/artifacts", method: "GET") else { return .notConfigured }
        guard let (data, response) = try? await URLSession.shared.data(for: httpRequest) else {
            return .failed("could not reach the control plane")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failed(errorMessage(from: data) ?? "control plane returned HTTP \(status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["artifacts"] as? [[String: Any]]
        else { return .found([]) }
        let entries = items.compactMap { item -> Entry? in
            guard let path = item["path"] as? String else { return nil }
            return Entry(path: path, size: item["size"] as? Int ?? 0)
        }
        return .found(entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    static func read(path: String) async -> ReadOutcome {
        guard let httpRequest = request(path: "/artifacts/\(encodedPath(path))", method: "GET") else {
            return .notConfigured
        }
        guard let (data, response) = try? await URLSession.shared.data(for: httpRequest) else {
            return .failed("could not reach the control plane")
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed("no response from the control plane")
        }
        if http.statusCode == 404 { return .notFound }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(errorMessage(from: data) ?? "control plane returned HTTP \(http.statusCode)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = object["content"] as? String
        else { return .failed("the control plane's response was not the expected shape") }
        return .found(content)
    }

    static func write(path: String, content: String) async -> WriteOutcome {
        guard var httpRequest = request(path: "/artifacts/\(encodedPath(path))", method: "PUT") else {
            return .notConfigured
        }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": content]) else {
            return .failed("could not encode the file")
        }
        httpRequest.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: httpRequest) else {
            return .failed("could not reach the control plane")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failed(errorMessage(from: data) ?? "control plane returned HTTP \(status)")
        }
        let size = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["size"] as? Int } ?? content.utf8.count
        return .saved(size: size)
    }

    static func delete(path: String) async -> DeleteOutcome {
        guard let httpRequest = request(path: "/artifacts/\(encodedPath(path))", method: "DELETE") else {
            return .notConfigured
        }
        guard let (data, response) = try? await URLSession.shared.data(for: httpRequest) else {
            return .failed("could not reach the control plane")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failed(errorMessage(from: data) ?? "control plane returned HTTP \(status)")
        }
        return .deleted
    }

    /// Percent-encodes each path segment individually so a name like "notes/a b.txt"
    /// survives as two segments, matching `DaemonArtifactClient`'s own encoding — both
    /// sides of this route must agree on the wire shape.
    static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func request(path: String, method: String) -> URLRequest? {
        guard CloudControlPlaneConfig.isConfigured else { return nil }
        var base = CloudControlPlaneConfig.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        return request
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }
}
