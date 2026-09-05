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

    /// The harness's rolling transcript for one agent, auto-refreshing the presigned
    /// URL when it is missing or expired (a fresh vend before the request) and once
    /// more if the GET still comes back 403 (a URL that died before its stated expiry).
    /// The refresh goes through the control plane (`PresignedURLService`); with no
    /// control plane configured this collapses to a single attempt against whatever URL
    /// is stored, exactly as before — the manual paste stays a working fallback.
    static func fetchTranscript(agentID: UUID, agentName: String) async -> [AgentMirrorRecord] {
        if CloudControlPlaneConfig.isConfigured, CloudAgentConfig.needsRefresh(agentID: agentID) {
            await PresignedURLService.refreshCloudAgentURLs(agentID: agentID, agentName: agentName)
        }
        let (records, status) = await fetchTranscriptOnce(
            urlString: CloudAgentConfig.transcriptURL(agentID: agentID)
        )
        if status == 403 || status == 401, CloudControlPlaneConfig.isConfigured,
           await PresignedURLService.refreshCloudAgentURLs(agentID: agentID, agentName: agentName) {
            return await fetchTranscriptOnce(
                urlString: CloudAgentConfig.transcriptURL(agentID: agentID)
            ).records
        }
        return records
    }

    /// One transcript GET. Returns the parsed records and the HTTP status (nil on a
    /// transport failure) so the caller can tell a 403/expired URL from a genuinely
    /// empty transcript — the raw fetch stays total, returning [] on anything but a
    /// 200. A 304 never happens (no ETag caching here): the file is small by
    /// construction (the harness caps its line count) and the view polls at 10s.
    static func fetchTranscriptOnce(
        urlString: String
    ) async -> (records: [AgentMirrorRecord], status: Int?) {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return ([], nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return ([], nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, let content = String(data: data, encoding: .utf8) else {
            return ([], status)
        }
        return (AgentMirrorReader.parseLines(content), status)
    }

    /// Delivers one user message to an agent's inbox, auto-refreshing the presigned
    /// URLs when they are missing or expired and once more if the PUT comes back 403.
    /// True when the PUT ultimately succeeded. Degrades to a single attempt with no
    /// control plane configured.
    static func sendMessage(agentID: UUID, agentName: String, text: String) async -> Bool {
        if CloudControlPlaneConfig.isConfigured, CloudAgentConfig.needsRefresh(agentID: agentID) {
            await PresignedURLService.refreshCloudAgentURLs(agentID: agentID, agentName: agentName)
        }
        let (delivered, status) = await sendMessageOnce(
            inboxGetURL: CloudAgentConfig.inboxGetURL(agentID: agentID),
            inboxPutURL: CloudAgentConfig.inboxPutURL(agentID: agentID),
            agentName: agentName, text: text
        )
        if !delivered, status == 403 || status == 401, CloudControlPlaneConfig.isConfigured,
           await PresignedURLService.refreshCloudAgentURLs(agentID: agentID, agentName: agentName) {
            return await sendMessageOnce(
                inboxGetURL: CloudAgentConfig.inboxGetURL(agentID: agentID),
                inboxPutURL: CloudAgentConfig.inboxPutURL(agentID: agentID),
                agentName: agentName, text: text
            ).delivered
        }
        return delivered
    }

    /// GET-merge-PUT of one user message. Returns whether the PUT succeeded and its
    /// HTTP status (nil on a transport failure); the status is the PUT's — the delivery
    /// call — so a 403 there is distinguishable and a stale inbox GET (tolerated: a
    /// missing document just starts fresh) never masks it.
    static func sendMessageOnce(
        inboxGetURL: String, inboxPutURL: String, agentName: String, text: String
    ) async -> (delivered: Bool, status: Int?) {
        guard let putURL = URL(string: inboxPutURL), !inboxPutURL.isEmpty else { return (false, nil) }
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
        guard let (_, response) = try? await URLSession.shared.data(for: putRequest) else {
            return (false, nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        return ((status.map { (200..<300).contains($0) } ?? false), status)
    }
}
