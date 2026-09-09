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

    /// The harness's rolling transcript for one agent: the latest hourly chunk merged
    /// with the previous hour's (when one exists), through the control plane's
    /// authenticated `/transcript-chunks` route — same bearer-token relay `/memory` and
    /// `/notify` use, no presigned URL. `fin-agentd` stopped writing the old rolling
    /// presigned-URL object once it moved to hourly S3 chunks (`DaemonTranscriptUplink`);
    /// this follows it. `agentID` stays in the signature for source compatibility with
    /// existing callers — the route itself keys by name, like every other control-plane
    /// document.
    static func fetchTranscript(agentID: UUID, agentName: String) async -> [AgentMirrorRecord] {
        await fetchTranscriptChunks(agentName: agentName).records
    }

    /// One page of the chunked transcript: every known hour key (oldest first — what
    /// `AgentRemoteConsoleView`'s "load earlier" affordance pages through) plus merged
    /// records for one window. Omitting `hour` fetches the latest chunk, merged with the
    /// previous hour's when one exists — Levi's "always quickly load the recent
    /// conversation" without a visible shrink right after an hour boundary; passing an
    /// explicit `hour` fetches exactly that one chunk, for paging further back.
    struct TranscriptChunksPage {
        let hours: [String]
        let records: [AgentMirrorRecord]
    }

    static func fetchTranscriptChunks(agentName: String, hour: String? = nil) async -> TranscriptChunksPage {
        guard CloudControlPlaneConfig.isConfigured,
              let first = await fetchTranscriptChunksOnce(agentName: agentName, hour: hour)
        else { return TranscriptChunksPage(hours: [], records: []) }

        guard hour == nil, let latestHour = first.chunkHour,
              let index = first.hours.firstIndex(of: latestHour), index > 0
        else {
            return TranscriptChunksPage(hours: first.hours, records: first.records)
        }
        guard let previous = await fetchTranscriptChunksOnce(agentName: agentName, hour: first.hours[index - 1])
        else {
            return TranscriptChunksPage(hours: first.hours, records: first.records)
        }
        return TranscriptChunksPage(
            hours: first.hours,
            records: AgentMirrorReader.merge([first.records, previous.records])
        )
    }

    private struct RawTranscriptChunksResponse {
        let hours: [String]
        let chunkHour: String?
        let records: [AgentMirrorRecord]
    }

    /// One `/transcript-chunks` GET. Total: returns nil on anything short of a decodable
    /// 200, never partial/garbage data.
    private static func fetchTranscriptChunksOnce(agentName: String, hour: String?) async -> RawTranscriptChunksResponse? {
        var base = CloudControlPlaneConfig.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty,
              let encodedName = agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        var path = "/transcript-chunks?agent=\(encodedName)"
        if let hour, let encodedHour = hour.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&hour=\(encodedHour)"
        }
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(CloudControlPlaneConfig.token)", forHTTPHeaderField: "authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let hours = (object["hours"] as? [String]) ?? []
        let chunk = object["chunk"] as? [String: Any]
        let lines = (chunk?["lines"] as? [String]) ?? []
        return RawTranscriptChunksResponse(
            hours: hours,
            chunkHour: chunk?["hour"] as? String,
            records: AgentMirrorReader.parseLines(lines.joined(separator: "\n"))
        )
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
