import Foundation
import Crypto
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// This body's presence on the control plane (docs/SITES.md §3.3, §6.3): the
/// 20-second heartbeat, and the claim/hold/apply/ack protocol for messages the
/// heartbeat offers.
///
/// Runs on its OWN task, independent of the turn loop — that is the whole
/// reason it exists as a separate client. Today's status uplink only runs in
/// the wait between turns, and a multi-tool turn on a local 12B model takes
/// minutes, so the site working hardest is exactly the one that looks dead to
/// every lease. Here `state: "working"` goes up every beat while a turn runs.
///
/// What it does NOT do: apply messages. It claims them at receipt (so the
/// conversation stays with a busy primary instead of drifting to a standby)
/// and holds them; the daemon's run loop pops `nextHeldMessage()` between
/// turns, submits, and acks through `markApplied`/`markAnswered`. Held and
/// unacked ids persist in a small sibling ledger so a restart resumes them —
/// `unacked` is the crash-recovery list §6.4 describes.
///
/// An `actor`, deliberately not `@MainActor`: the daemon is one main-actor
/// class whose turn loop holds that actor for the length of a turn's synchronous
/// stretches, so a main-actor heartbeat task would inherit the exact starvation
/// it exists to fix. Its providers are `@Sendable` and awaited, so the daemon
/// answers them on its own actor when it can.
actor DaemonSiteClient {
    static let requestTimeout: TimeInterval = 10
    static let failureAuditWindow: TimeInterval = 5 * 60
    static let defaultHeartbeatSeconds = 20
    static let claimLeaseSeconds = 120

    struct Offer: Equatable {
        let id: String
        let text: String
        let source: String
    }

    struct Command: Equatable {
        let id: String
        let kind: String
    }

    /// One heartbeat's answer, decoded tolerantly: every field optional, unknown
    /// keys ignored, so a newer control plane never breaks an older daemon.
    struct HeartbeatResponse: Equatable {
        var role: String?
        var leaseUntil: String?
        var heartbeatSeconds: Int?
        var messages: [Offer]
        var commands: [Command]
        var urlsExpireAt: String?
        var urls: [String: String] = [:]
    }

    /// `held` = claimed, not yet submitted. `unacked` = submitted, `applied` ack
    /// not yet confirmed. Both survive a restart; the first heartbeat after one
    /// carries `unacked` so the control plane acks them under our claim before
    /// any other body can be offered them.
    struct Ledger: Codable, Equatable {
        var held: [HeldMessage]
        var unacked: [String]

        struct HeldMessage: Codable, Equatable {
            let id: String
            let text: String
            let source: String
            /// The thread the control plane put the message in at claim time
            /// (docs/THREADS.md §2) — its root's id, or its own id when it roots
            /// a thread of its own. Nil for a ledger written before threads
            /// existed; the daemon then reads the message as its own root.
            var threadID: String?

            init(id: String, text: String, source: String, threadID: String? = nil) {
                self.id = id
                self.text = text
                self.source = source
                self.threadID = threadID
            }

            /// Whether the sender chose the thread (a reply inside a thread view):
            /// then the control plane keeps that membership whatever the daemon
            /// proposes, so there is nothing for the pane match to decide.
            var hasExplicitThread: Bool {
                guard let threadID, !threadID.isEmpty else { return false }
                return threadID != id
            }
        }

        init(held: [HeldMessage] = [], unacked: [String] = []) {
            self.held = held
            self.unacked = unacked
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            held = try container.decodeIfPresent([HeldMessage].self, forKey: .held) ?? []
            unacked = try container.decodeIfPresent([String].self, forKey: .unacked) ?? []
        }
    }

    nonisolated let siteID: String
    nonisolated let siteID8: String
    nonisolated let displayName: String
    nonisolated let heartbeatSeconds: Int
    private let endpointURL: String
    private let token: String
    private let ledgerPath: String
    private let audit: (String) -> Void

    /// Injected so tests never touch the network.
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// What this body is doing right now — "working" while a turn is in flight.
    var stateProvider: @Sendable () async -> String = { "idle" }
    /// The heartbeat's `capabilities`; nil entries are omitted.
    var capabilitiesProvider: @Sendable () async -> [String: Any] = { [:] }
    var runID: String?
    /// Delivered commands, handled by the daemon (restart = exit 0 under
    /// launchd KeepAlive; drain = stop claiming).
    var onCommand: @Sendable (Command) async -> Void = { _ in }

    func setClaimHandler(_ handler: @escaping @Sendable () async -> Void) {
        onClaimed = handler
    }

    func setURLHandler(_ handler: @escaping @Sendable ([String: String]) async -> Void) {
        onURLs = handler
    }

    func configure(
        runID: String?,
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        state: @escaping @Sendable () async -> String,
        capabilities: @escaping @Sendable () async -> [String: Any],
        onCommand: @escaping @Sendable (Command) async -> Void
    ) {
        self.runID = runID
        if let transport { self.transport = transport }
        self.stateProvider = state
        self.capabilitiesProvider = capabilities
        self.onCommand = onCommand
    }

    /// When the URLs the last heartbeat handed us lapse; sent back on every beat
    /// so the control plane re-signs within 20 minutes of expiry. Nil until the
    /// first beat, which therefore always brings a fresh set — that is how a
    /// site whose config shipped with no presigned URLs at all gets them.
    private var urlsExpireAt: String?
    private var onURLs: (@Sendable ([String: String]) async -> Void)?
    /// Fired after a successful claim so the daemon can preempt a heartbeat turn:
    /// a user's message should never wait behind minutes of reflective model time.
    private var onClaimed: (@Sendable () async -> Void)?
    private(set) var role: String = "standby"
    private(set) var ledger: Ledger
    private(set) var isDraining = false
    private var lastFailureAuditAt: [String: Date] = [:]
    private var loop: Task<Void, Never>?

    /// The app-side Agent UUID this body speaks for (`config.agentID`), sent
    /// on the answered ack so the control plane's reply push carries
    /// `fin.agentID` + `thread-id` — without it the app can neither deep-link a
    /// tap nor address a typed Reply (`AgentNotificationService.replyTarget`
    /// needs id AND name). Nil for an unpaired daemon: the push still lands.
    let agentID: UUID?
    /// This Mac's `DeviceIdentity.short`-equivalent (`config.deviceToken8`),
    /// sent on the answered ack as `originDeviceID8`: the control plane leaves
    /// this device's own tokens out of the reply fan-out and tells every other
    /// device the reply did not originate locally. Empty = not sent.
    let originDeviceID8: String

    init(
        siteID: String, displayName: String, token: String, heartbeatSeconds: Int?,
        endpointURL: String, ledgerPath: String, agentID: UUID? = nil, originDeviceID8: String = "",
        audit: @escaping (String) -> Void
    ) {
        self.siteID = siteID.lowercased()
        self.siteID8 = String(siteID.lowercased().prefix(8))
        self.displayName = displayName
        self.token = token
        self.agentID = agentID
        self.originDeviceID8 = originDeviceID8
        self.heartbeatSeconds = max(5, heartbeatSeconds ?? Self.defaultHeartbeatSeconds)
        self.endpointURL = endpointURL
        self.ledgerPath = ledgerPath
        self.audit = audit
        self.ledger = Self.loadLedger(from: ledgerPath)
    }

    // MARK: - The loop

    func start() {
        guard loop == nil else { return }
        let seconds = heartbeatSeconds
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.beat()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One heartbeat: renew, report, claim what was offered, run commands.
    func beat() async {
        var body: [String: Any] = [
            "schema": 2,
            "state": await stateProvider(),
            "wantsPrimary": !isDraining,
            "held": ledger.held.map(\.id),
            "unacked": ledger.unacked,
            "capabilities": await capabilitiesProvider(),
        ]
        if let urlsExpireAt { body["urlsExpireAt"] = urlsExpireAt }
        if let runID { body["runId"] = runID }

        guard let (status, data) = await post("/sites/\(siteID)/heartbeat", body: body) else { return }
        guard (200..<300).contains(status) else {
            registerFailure("[site] heartbeat failed: HTTP \(status)")
            return
        }
        let response = Self.decodeHeartbeat(data)
        if !response.urls.isEmpty {
            urlsExpireAt = response.urlsExpireAt
            await onURLs?(response.urls)
        }
        let newRole = response.role ?? "standby"
        if newRole != role {
            audit("[site] role: \(newRole)")
            role = newRole
        }
        // An unacked id the control plane has now acked (it did so before answering
        // this beat) is done; the ledger no longer needs to carry it.
        if !ledger.unacked.isEmpty {
            ledger.unacked = []
            persistLedger()
        }
        for offer in response.messages where !ledger.held.contains(where: { $0.id == offer.id }) {
            guard !isDraining else { break }
            await claim(offer)
        }
        for command in response.commands {
            audit("[site] command \(command.kind) (\(command.id))")
            if command.kind == "drain" { isDraining = true }
            await onCommand(command)
        }
    }

    // MARK: - Claim / hold / apply / ack

    private func claim(_ offer: Offer) async {
        guard let (status, data) = await post(
            "/messages/\(offer.id)/claim", body: ["leaseSeconds": Self.claimLeaseSeconds]
        ) else { return }
        switch status {
        case 200..<300:
            // The claim answers with the public row, thread included; the heartbeat's
            // offer does not carry it.
            ledger.held.append(.init(
                id: offer.id, text: offer.text, source: offer.source,
                threadID: Self.threadID(inResponse: data)
            ))
            persistLedger()
            audit("[site] claimed \(offer.id)")
            await onClaimed?()
        case 409:
            // Another body won. Forget it; the row is theirs.
            break
        default:
            registerFailure("[site] claim \(offer.id) failed: HTTP \(status)")
        }
    }

    /// The run loop's pop: the oldest held message moves to `unacked` in one
    /// atomic ledger write BEFORE the caller submits it — the same
    /// mark-before-submit at-most-once discipline the directive channel keeps.
    func nextHeldMessage() -> Ledger.HeldMessage? {
        guard !ledger.held.isEmpty else { return nil }
        let message = ledger.held.removeFirst()
        ledger.unacked.append(message.id)
        persistLedger()
        return message
    }

    /// A thread proposal for an ack (docs/THREADS.md §2): the thread the daemon
    /// believes this message belongs to, and why (`pane:<target>` — the request
    /// relayed into the same pane as an earlier one). The control plane validates
    /// the id, keeps an explicit membership over it, and logs the decision.
    struct ThreadProposal: Equatable {
        let threadID: String
        let reason: String
    }

    /// The applied ack, with the pre-turn thread proposal when the daemon has
    /// one. Returns the thread the control plane settled on (its `threadId`),
    /// or nil when the ack did not go through — the daemon's pane map records
    /// what the control plane confirmed, never what was merely proposed.
    @discardableResult
    func markApplied(_ id: String, runID: String?, thread: ThreadProposal? = nil) async -> String? {
        var body: [String: Any] = ["state": "applied"]
        if let runID { body["runId"] = runID }
        if let thread {
            body["threadId"] = thread.threadID
            body["threadReason"] = thread.reason
        }
        guard let (status, data) = await post("/messages/\(id)/ack", body: body) else { return nil }
        if (200..<300).contains(status) || status == 409 {
            // 409 = already past applied (a restart re-acked it via `unacked`).
            ledger.unacked.removeAll { $0 == id }
            persistLedger()
            return Self.threadID(inResponse: data)
        }
        registerFailure("[site] ack applied \(id) failed: HTTP \(status)")
        return nil
    }

    /// The answered ack: `{state, replyPreview}` plus `agentID` /
    /// `originDeviceID8` when known (omitted, never null, when not) — the two
    /// fields that make the control plane's reply push usable on the app side —
    /// and `threadId` / `threadReason` when the turn's pane relays settled the
    /// thread only after the applied ack had gone (the turn-end fallback).
    /// Pure and tested (`DaemonSiteClientTests`).
    static func answeredAckBody(
        replyPreview: String, agentID: UUID?, originDeviceID8: String, thread: ThreadProposal? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "state": "answered",
            "replyPreview": String(MemoryRedactor.redact(replyPreview).prefix(500)),
        ]
        if let agentID { body["agentID"] = agentID.uuidString }
        if !originDeviceID8.isEmpty { body["originDeviceID8"] = originDeviceID8 }
        if let thread {
            body["threadId"] = thread.threadID
            body["threadReason"] = thread.reason
        }
        return body
    }

    /// Returns the thread the control plane settled on, nil when the ack did
    /// not go through (same contract as `markApplied`).
    @discardableResult
    func markAnswered(_ id: String, replyPreview: String, thread: ThreadProposal? = nil) async -> String? {
        guard let (status, data) = await post(
            "/messages/\(id)/ack",
            body: Self.answeredAckBody(
                replyPreview: replyPreview, agentID: agentID, originDeviceID8: originDeviceID8, thread: thread
            )
        ) else { return nil }
        if (200..<300).contains(status) || status == 409 {
            return Self.threadID(inResponse: data)
        }
        registerFailure("[site] ack answered \(id) failed: HTTP \(status)")
        return nil
    }

    /// The `threadId` of a claim or ack response body, nil when absent — an older
    /// control plane answers without one and the daemon treats the message as
    /// its own root.
    nonisolated static func threadID(inResponse data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let threadID = object["threadId"] as? String, !threadID.isEmpty
        else { return nil }
        return threadID
    }

    // MARK: - update

    /// The `update` command (docs/SITES.md §3.5): ask the control plane for the
    /// published macOS binary and its sha256, download to a sibling temp file,
    /// verify, rename over `binaryPath` (a running process keeps its old inode;
    /// exit 0 afterwards and launchd respawns the new one). Returns the new
    /// version string on success, nil on any failure — never a half-installed
    /// binary: the rename is the only step that touches the real path.
    func performUpdate(binaryPath: String) async -> String? {
        guard let (status, data) = await post("/presign", body: ["kinds": ["agentdBinary"]]),
              (200..<300).contains(status),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urls = object["urls"] as? [String: Any],
              let get = urls["agentdBinaryGet"] as? String, let url = URL(string: get),
              let expected = (urls["agentdBinarySha256"] as? String)?.lowercased(), !expected.isEmpty
        else {
            audit("[site] update: no published binary (HTTP presign failed)")
            return nil
        }
        let temp = binaryPath + ".update-\(ProcessInfo.processInfo.processIdentifier)"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        do {
            let (bytes, response) = try await transport(URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200, !bytes.isEmpty else {
                audit("[site] update: download failed")
                return nil
            }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else {
                audit("[site] update: sha256 mismatch — refusing to install")
                return nil
            }
            try bytes.write(to: URL(fileURLWithPath: temp), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp)
            let version = Self.versionOf(temp)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: binaryPath), withItemAt: URL(fileURLWithPath: temp))
            audit("[site] update: installed fin-agentd \(version ?? "?") — restarting")
            return version ?? "unknown"
        } catch {
            audit("[site] update failed: \(error.localizedDescription.prefix(160))")
            return nil
        }
    }

    nonisolated static func versionOf(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - Wire shape (pure, tested)

    nonisolated static func decodeHeartbeat(_ data: Data) -> HeartbeatResponse {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let messages = (object["messages"] as? [[String: Any]] ?? []).compactMap { entry -> Offer? in
            guard let id = entry["id"] as? String, let text = entry["text"] as? String else { return nil }
            return Offer(id: id, text: text, source: entry["source"] as? String ?? "app")
        }
        let commands = (object["commands"] as? [[String: Any]] ?? []).compactMap { entry -> Command? in
            guard let id = entry["id"] as? String, let kind = entry["kind"] as? String else { return nil }
            return Command(id: id, kind: kind)
        }
        return HeartbeatResponse(
            role: object["role"] as? String,
            leaseUntil: object["leaseUntil"] as? String,
            heartbeatSeconds: object["heartbeatSeconds"] as? Int,
            messages: messages,
            commands: commands,
            urlsExpireAt: object["urlsExpireAt"] as? String,
            urls: (object["urls"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        )
    }

    // MARK: - Transport

    private func post(_ path: String, body: [String: Any]) async -> (Int, Data)? {
        var base = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            registerFailure("[site] control plane URL is not a valid URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue(siteID, forHTTPHeaderField: "X-Fin-Site")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let (data, response) = try await transport(request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            registerFailure("[site] \(path) unreachable: \(text.prefix(160))")
            return nil
        }
    }

    private func registerFailure(_ line: String) {
        let key = String(line.prefix(40))
        let now = Date()
        if let last = lastFailureAuditAt[key], now.timeIntervalSince(last) < Self.failureAuditWindow { return }
        lastFailureAuditAt[key] = now
        audit(line)
    }

    // MARK: - Ledger file

    nonisolated static func loadLedger(from path: String) -> Ledger {
        guard let data = FileManager.default.contents(atPath: path),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data)
        else { return Ledger() }
        return ledger
    }

    private func persistLedger() {
        do {
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: URL(fileURLWithPath: ledgerPath), options: .atomic)
        } catch {
            registerFailure("[site] ledger write failed: \(error.localizedDescription.prefix(120))")
        }
    }
}
