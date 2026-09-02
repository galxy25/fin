import Foundation

/// S3-side I/O for a CLOUD-hosted agent (`AgentHostingMode.cloud`): the app never
/// talks to the harness directly — it GETs the rolling transcript the harness
/// PUTs (mirror-format JSONL, rendered by the same `AgentMirrorRecord` parser as
/// the iCloud mirror), and appends user messages to the harness's inbox document
/// (same schema as the supervision directives document, ids prefixed "m-").
///
/// The inbox append is GET-merge-PUT with no locking: the app is the only writer
/// of this document (the supervisor writes the separate directives document), and
/// concurrent composes from two devices are rare enough that last-writer-wins on
/// a sub-second window is an accepted v1 risk — losing one queued message loses a
/// retype, not data.
enum CloudAgentChannel {
    /// Mirrors `AgentRelayApplier.maxTextLength` — one cap for both compose paths.
    static var maxTextLength: Int { AgentRelayApplier.maxTextLength }

    /// The inbox never grows unbounded: older applied entries age out of the
    /// document tail. The harness's applied-id ledger is what prevents re-runs,
    /// so dropping old entries here is safe.
    static let maxInboxEntries = 200

    /// Appends one user message to an inbox document, returning the new document
    /// bytes. Pure and total for testability: unparseable or absent existing data
    /// starts a fresh document rather than failing — the first compose is exactly
    /// the case where the object doesn't exist yet.
    static func appendedInboxDocument(
        existing: Data?, agentName: String, text: String, id: String
    ) -> Data {
        var entries: [[String: Any]] = []
        if let existing,
           let object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
           let current = object["directives"] as? [[String: Any]] {
            entries = current
        }
        entries.append([
            "id": id,
            "agent": agentName,
            "kind": "user_message",
            "text": text,
        ])
        if entries.count > maxInboxEntries {
            entries.removeFirst(entries.count - maxInboxEntries)
        }
        let document: [String: Any] = ["version": 1, "directives": entries]
        // Serialization of string/int-only trees cannot fail; the fallback keeps
        // the signature total anyway.
        return (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
            ?? Data("{\"version\":1,\"directives\":[]}".utf8)
    }

    /// The harness's rolling transcript, parsed with the mirror parser. Empty on
    /// any failure — the view's refresh loop retries every few seconds, so one
    /// failed fetch must never surface as an error state. A 304 never happens
    /// (no ETag caching here): the file is small by construction (the harness
    /// caps its line count) and the view polls at 10s.
    static func fetchTranscript(urlString: String) async -> [AgentMirrorRecord] {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return AgentMirrorReader.parseLines(content)
    }

    /// GET-merge-PUT of one user message. True when the PUT succeeded.
    static func sendMessage(
        inboxGetURL: String, inboxPutURL: String, agentName: String, text: String
    ) async -> Bool {
        guard let putURL = URL(string: inboxPutURL), !inboxPutURL.isEmpty else { return false }
        var existing: Data?
        if let getURL = URL(string: inboxGetURL), !inboxGetURL.isEmpty {
            var getRequest = URLRequest(url: getURL)
            getRequest.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: getRequest),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                existing = data
            }
        }
        let body = appendedInboxDocument(
            existing: existing,
            agentName: agentName,
            text: text,
            id: "m-\(UUID().uuidString.lowercased())"
        )
        var putRequest = URLRequest(url: putURL)
        putRequest.httpMethod = "PUT"
        // The presigned URL must be SigV4-signed WITH this content type — the
        // same gotcha as the daemon's status PUT (see daemon/README.md).
        putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putRequest.httpBody = body
        putRequest.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: putRequest),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status)
        else { return false }
        return true
    }
}
