import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The daemon's artifacts filesystem client: PUT/GET/DELETE one text file, or list them
/// all, through the control plane's `/artifacts` routes — same authenticated bearer-token
/// relay every other control-plane client here uses, no presigned URL. One flat, shared
/// space per Fin account (`ARTIFACT_PREFIX` in `lambda.py`), reachable from both the
/// daemon and the app, so a file an agent writes here is a "second filesystem apart from
/// the iOS native one," as Levi put it.
@MainActor
final class DaemonArtifactClient {
    static let requestTimeout: TimeInterval = 10
    static let failureAuditWindow: TimeInterval = 5 * 60

    let endpointURL: String
    private let token: String

    var transport: (URLRequest) async throws -> (Data, URLResponse)
    let audit: (String) -> Void
    private var lastFailureAuditAt: [String: Date] = [:]

    init(
        endpointURL: String,
        token: String,
        audit: @escaping (String) -> Void = { _ in },
        transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpointURL = endpointURL
        self.token = token
        self.audit = audit
        self.transport = transport
    }

    private func request(path: String, method: String) -> URLRequest? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let escapedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: base + escapedPath) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        return request
    }

    func write(path: String, content: String) async -> AgentArtifactWriteOutcome {
        guard var httpRequest = request(path: "/artifacts/\(path)", method: "PUT") else {
            return .failed("control plane URL is not configured")
        }
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["content": content]) else {
            return .failed("could not encode the artifact")
        }
        httpRequest.httpBody = body
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[artifacts] write failed: HTTP \(status)")
                return .failed(Self.errorMessage(from: data) ?? "control plane returned HTTP \(status)")
            }
            let size = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["size"] as? Int } ?? content.utf8.count
            return .saved(size: size)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[artifacts] write failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    func read(path: String) async -> AgentArtifactReadOutcome {
        guard let httpRequest = request(path: "/artifacts/\(path)", method: "GET") else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse else {
                registerFailure("[artifacts] read failed: no HTTP response")
                return .failed("no response from the control plane")
            }
            if http.statusCode == 404 { return .notFound }
            guard (200..<300).contains(http.statusCode) else {
                registerFailure("[artifacts] read failed: HTTP \(http.statusCode)")
                return .failed(Self.errorMessage(from: data) ?? "control plane returned HTTP \(http.statusCode)")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let content = object["content"] as? String
            else {
                return .failed("the control plane's response was not the expected shape")
            }
            return .found(content: content)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[artifacts] read failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    func list() async -> AgentArtifactListOutcome {
        guard let httpRequest = request(path: "/artifacts", method: "GET") else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[artifacts] list failed: HTTP \(status)")
                return .failed(Self.errorMessage(from: data) ?? "control plane returned HTTP \(status)")
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = object["artifacts"] as? [[String: Any]]
            else {
                return .found([])
            }
            let entries = items.compactMap { item -> AgentArtifactEntry? in
                guard let path = item["path"] as? String else { return nil }
                return AgentArtifactEntry(path: path, size: item["size"] as? Int ?? 0)
            }
            return .found(entries)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[artifacts] list failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    func delete(path: String) async -> AgentArtifactDeleteOutcome {
        guard let httpRequest = request(path: "/artifacts/\(path)", method: "DELETE") else {
            return .failed("control plane URL is not configured")
        }
        do {
            let (data, response) = try await transport(httpRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                registerFailure("[artifacts] delete failed: HTTP \(status)")
                return .failed(Self.errorMessage(from: data) ?? "control plane returned HTTP \(status)")
            }
            return .deleted
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[artifacts] delete failed: \(text.prefix(200))")
            return .failed("could not reach the control plane")
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private func registerFailure(_ message: String) {
        let now = Date()
        if let last = lastFailureAuditAt[message],
           now.timeIntervalSince(last) < Self.failureAuditWindow {
            return
        }
        lastFailureAuditAt[message] = now
        audit(message)
    }
}
