import Foundation
import os

/// docs/THREADS.md §4: the app's view of threads for one agent — `GET /threads`
/// polled on the console cadence (10 s), cached per agent across instances so a
/// freshly opened screen shows the last list instantly, thread details fetched
/// on demand, and the current selection (`nil` = All activity). Every fetch,
/// merge and selection change is logged with counts only — never a title, a
/// message, or an id beyond its 8-char prefix.
@MainActor
final class ThreadStore: ObservableObject {
    static let log = Logger(subsystem: "dev.levischoen.fin", category: "threads")
    static let pollSeconds: UInt64 = 10

    /// Last successful list per agent, shared by every store instance.
    private static var cache: [String: [ThreadSummary]] = [:]

    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var details: [String: ControlPlaneClient.ThreadDetail] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetchAt: Date?
    /// nil = "All activity". Set through `select` so the change is logged and
    /// the default rule stops applying once the user has chosen.
    @Published private(set) var selectedThreadID: String?
    private var userChoseSelection = false

    private(set) var agentName: String
    private var loop: Task<Void, Never>?

    init(agentName: String = "") {
        self.agentName = agentName
        if !agentName.isEmpty, let cached = Self.cache[agentName] {
            threads = cached
            selectedThreadID = ThreadSelection.defaultThreadID(cached)
        }
    }

    var isAvailable: Bool { CloudControlPlaneConfig.isConfigured && !TestHost.isUnitTest && !agentName.isEmpty }

    var selectedThread: ThreadSummary? {
        selectedThreadID.flatMap { id in threads.first { $0.threadId == id } }
    }

    /// Threads whose status is not answered — the hub sidebar's "open" rows.
    var openThreads: [ThreadSummary] { threads.filter { $0.status != .answered } }

    /// `messageId → threadId` across every row this store has seen, for
    /// resolving a legacy `in_reply_to` line into its thread.
    var threadOfMessage: [String: String] {
        var map: [String: String] = [:]
        for detail in details.values {
            for message in detail.messages { map[message.messageId] = message.resolvedThreadID }
        }
        return map
    }

    // MARK: - Selection

    func select(_ threadID: String?, byUser: Bool = true) {
        if byUser { userChoseSelection = true }
        guard threadID != selectedThreadID else { return }
        selectedThreadID = threadID
        let label = threadID.map { "thread " + String($0.prefix(8)) } ?? "all"
        let count = threads.count
        Self.log.info("selection changed: \(label, privacy: .public) byUser=\(byUser) of \(count) threads")
        if let threadID { Task { await self.loadDetail(threadID) } }
    }

    /// The initial selection a caller hands in (a notification tap, the hub
    /// sidebar): counts as the user's choice so a later list refresh keeps it.
    func preselect(_ threadID: String?) {
        guard let threadID else { return }
        select(threadID, byUser: true)
    }

    // MARK: - Polling

    func start(agentName: String) {
        if self.agentName != agentName {
            self.agentName = agentName
            threads = Self.cache[agentName] ?? []
            if !userChoseSelection { selectedThreadID = ThreadSelection.defaultThreadID(threads) }
        }
        guard loop == nil, isAvailable else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One `GET /threads`; call on the caller's own cadence when not polling.
    func refresh() async {
        guard isAvailable else { return }
        switch await ControlPlaneClient.listThreads(agent: agentName) {
        case .success(let fetched):
            merge(fetched)
        case .failure(let failure):
            let reason = Self.describe(failure)
            lastError = reason
            Self.log.error("list failed: \(reason, privacy: .public)")
        }
    }

    /// Adopt a fetched list (also the test seam — no transport needed).
    func merge(_ fetched: [ThreadSummary]) {
        let sorted = ThreadSelection.sorted(fetched)
        let changed = sorted != threads
        threads = sorted
        Self.cache[agentName] = sorted
        lastFetchAt = Date()
        lastError = nil
        let open = sorted.filter { $0.status != .answered }.count
        Self.log.info("merged \(sorted.count) threads (\(open) open, changed=\(changed)) for agent")
        if !userChoseSelection {
            let wanted = ThreadSelection.defaultThreadID(sorted)
            if wanted != selectedThreadID { select(wanted, byUser: false) }
        } else if let selected = selectedThreadID, !sorted.contains(where: { $0.threadId == selected }), !sorted.isEmpty {
            // The chosen thread fell off the list (aged out of the 50): keep the
            // choice — its detail still loads by id — but say so.
            Self.log.notice("selected thread is no longer listed; keeping selection")
        }
        if let selected = selectedThreadID { Task { await self.loadDetail(selected) } }
    }

    // MARK: - Details

    func detail(for threadID: String) -> ControlPlaneClient.ThreadDetail? { details[threadID] }

    @discardableResult
    func loadDetail(_ threadID: String) async -> ControlPlaneClient.ThreadDetail? {
        guard isAvailable else { return details[threadID] }
        switch await ControlPlaneClient.thread(id: threadID) {
        case .success(let detail):
            details[threadID] = detail
            let short = String(threadID.prefix(8)), status = detail.thread.status.rawValue
            Self.log.info("detail \(short, privacy: .public): \(detail.messages.count) messages, \(detail.events.count) events, status \(status, privacy: .public)")
            return detail
        case .failure(let failure):
            let short = String(threadID.prefix(8)), reason = Self.describe(failure)
            Self.log.error("detail \(short, privacy: .public) failed: \(reason, privacy: .public)")
            return details[threadID]
        }
    }

    /// The debug tail: raw events after `after`.
    func events(for threadID: String, after: Int = 0) async -> Result<[ThreadEvent], ControlPlaneClient.Failure> {
        let result = await ControlPlaneClient.threadEvents(id: threadID, after: after)
        if case .success(let events) = result {
            let short = String(threadID.prefix(8))
            Self.log.info("events \(short, privacy: .public) after \(after): \(events.count)")
        }
        return result
    }

    /// Test seam: adopt a detail without a transport.
    func adopt(detail: ControlPlaneClient.ThreadDetail) {
        details[detail.thread.threadId] = detail
    }

    private static func describe(_ failure: ControlPlaneClient.Failure) -> String {
        switch failure {
        case .notConfigured: return "control plane not configured"
        case .network: return "network error"
        case .http(let status, _): return "HTTP \(status)"
        }
    }
}

// MARK: - Timeline

/// Who is speaking in a thread item (docs/THREADS.md §1's party table).
enum ThreadParty: Equatable {
    /// The user, by the device (`authorSiteId8`) the message came from.
    case levi(deviceID8: String?)
    /// A Fin site, by its `siteId8`.
    case fin(siteID8: String?)
    /// A tmux pane the turn relayed into.
    case pane(target: String)
    /// A Claude operator session (`POST /notify` without a site).
    case `operator`
    case system

    var label: String {
        switch self {
        case .levi(let device): return device.map { "You · \($0)" } ?? "You"
        case .fin(let site): return site.map { "Fin · \($0)" } ?? "Fin"
        case .pane(let target): return "pane \(target)"
        case .operator: return "operator"
        case .system: return "system"
        }
    }

    var systemImage: String {
        switch self {
        case .levi: return "person"
        case .fin: return "sparkles"
        case .pane: return "terminal"
        case .operator: return "person.crop.rectangle"
        case .system: return "gearshape"
        }
    }
}

/// One row of a thread's merged timeline.
struct ThreadItem: Identifiable, Equatable {
    enum Kind: Equatable { case prompt, reply, step, relaySent, relayRead, notify, event }
    enum Source: Equatable { case message, record, event }

    let id: String
    let party: ThreadParty
    let kind: Kind
    let text: String
    let timestamp: Date
    /// Short state words shown as chips ("queued", "answered", "delivered 2").
    let status: [String]
    let source: Source
    /// Records keep their run/sequence so ties inside a second sort correctly.
    let sequence: Int
}

/// Pure: merge a thread's three sources — control-plane rows, transcript
/// records, thread events — into one ordered list. Dedupe rules:
///  - a message row already applied into the transcript (a user line with the
///    same `in_reply_to`) is one item, the record's, carrying the row's state;
///  - two user records sharing an `in_reply_to` (the at-least-once window the
///    console already collapses in `MirrorRecords.merge`) keep the first;
///  - a `notify.sent` / `relay.*` event whose site also wrote the matching
///    tool-call line within two minutes is folded into that line's chips
///    rather than shown twice; operator notifications always show.
enum ThreadTimeline {
    static let foldWindow: TimeInterval = 120

    static func build(
        thread: ThreadSummary?,
        messages: [ControlPlaneClient.Message],
        records: [AgentMirrorRecord],
        events: [ThreadEvent]
    ) -> [ThreadItem] {
        let byMessageID = Dictionary(messages.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [ThreadItem] = []
        var appliedMessageIDs = Set<String>()
        var seenRecordIDs = Set<String>()
        // A `read_session` result carries no target of its own; it shows what
        // the pane the run last addressed said.
        var lastPaneTargetByRun: [String: String] = [:]

        // Records first: they carry the actual conversation.
        for record in records {
            guard record.kind != .notice, record.kind != .turnStarted, record.kind != .turnProgress else { continue }
            guard seenRecordIDs.insert(record.id).inserted else { continue }
            switch record.kind {
            case .userMessage:
                if let reply = record.inReplyTo {
                    guard appliedMessageIDs.insert(reply).inserted else { continue }
                }
                let row = record.inReplyTo.flatMap { byMessageID[$0] }
                items.append(ThreadItem(
                    id: "r:" + record.id, party: .levi(deviceID8: row?.authorSiteId8), kind: .prompt,
                    text: record.text, timestamp: record.timestamp,
                    status: row.map { messageChips($0) } ?? [], source: .record, sequence: record.sequence
                ))
            case .assistantMessage:
                guard !record.text.isEmpty, record.text != "(tool call only)" else { continue }
                items.append(ThreadItem(
                    id: "r:" + record.id, party: .fin(siteID8: record.siteID8), kind: .reply,
                    text: record.text, timestamp: record.timestamp, status: [], source: .record, sequence: record.sequence
                ))
            case .toolCall where record.toolName == "notify":
                items.append(ThreadItem(
                    id: "r:" + record.id, party: .fin(siteID8: record.siteID8), kind: .notify,
                    text: record.text, timestamp: record.timestamp, status: [], source: .record, sequence: record.sequence
                ))
            case .toolCall, .toolResult:
                if let target = PaneRelay.target(of: record) ?? (PaneRelay.isRelay(record) ? lastPaneTargetByRun[record.runID] : nil) {
                    lastPaneTargetByRun[record.runID] = target
                    let isRead = PaneRelay.readTools.contains(record.toolName ?? "")
                    items.append(ThreadItem(
                        id: "r:" + record.id, party: .pane(target: target),
                        kind: isRead || record.kind == .toolResult ? .relayRead : .relaySent,
                        text: record.text, timestamp: record.timestamp, status: [], source: .record, sequence: record.sequence
                    ))
                } else {
                    items.append(ThreadItem(
                        id: "r:" + record.id, party: .fin(siteID8: record.siteID8), kind: .step,
                        text: record.text, timestamp: record.timestamp, status: [], source: .record, sequence: record.sequence
                    ))
                }
            default:
                items.append(ThreadItem(
                    id: "r:" + record.id, party: .fin(siteID8: record.siteID8), kind: .step,
                    text: record.text, timestamp: record.timestamp, status: [], source: .record, sequence: record.sequence
                ))
            }
        }

        // Message rows not yet in the transcript: queued / claimed / in flight.
        for message in messages where !appliedMessageIDs.contains(message.messageId) {
            guard let text = message.text, !text.isEmpty else { continue }
            items.append(ThreadItem(
                id: "m:" + message.messageId, party: .levi(deviceID8: message.authorSiteId8), kind: .prompt,
                text: text, timestamp: message.createdAt ?? .distantPast,
                status: messageChips(message), source: .message, sequence: 0
            ))
        }

        // Events: the notify / relay / goal transitions, folded when a record shows them.
        for event in events {
            guard let at = event.at else { continue }
            switch event.kind {
            case "notify.sent":
                let chips = deliveryChips(event)
                if event.actor != "operator",
                   let index = items.firstIndex(where: { item in
                       item.kind == .notify && item.source == .record
                           && item.party == .fin(siteID8: event.actor)
                           && abs(item.timestamp.timeIntervalSince(at)) <= foldWindow
                           && item.status.isEmpty
                   }) {
                    items[index] = withStatus(items[index], chips)
                    continue
                }
                let title = event.string("title") ?? event.string("event") ?? "notification"
                let body = event.string("body")
                items.append(ThreadItem(
                    id: "e:" + event.id, party: event.actor == "operator" ? .operator : .fin(siteID8: event.actor),
                    kind: .notify, text: body.map { "\(title) — \($0)" } ?? title, timestamp: at,
                    status: chips, source: .event, sequence: event.seq
                ))
            case "relay.sent", "relay.read":
                guard let target = event.string("target") else { continue }
                let kind: ThreadItem.Kind = event.kind == "relay.read" ? .relayRead : .relaySent
                if items.contains(where: { item in
                    item.kind == kind && item.source == .record && item.party == .pane(target: target)
                        && abs(item.timestamp.timeIntervalSince(at)) <= foldWindow
                }) { continue }
                items.append(ThreadItem(
                    id: "e:" + event.id, party: .pane(target: target), kind: kind,
                    text: event.string("text") ?? "", timestamp: at, status: [], source: .event, sequence: event.seq
                ))
            case "goal.followup":
                let title = event.string("title") ?? "follow-up"
                let next = event.string("nextAction")
                items.append(ThreadItem(
                    id: "e:" + event.id, party: .system, kind: .event,
                    text: next.map { "follow-up: \(title) — next: \($0)" } ?? "follow-up: \(title)",
                    timestamp: at, status: event.string("target").map { ["→ \($0)"] } ?? [], source: .event, sequence: event.seq
                ))
            case "thread.assigned":
                let reason = event.string("reason") ?? "root"
                guard reason != "root", reason != "explicit" else { continue }
                items.append(ThreadItem(
                    id: "e:" + event.id, party: .system, kind: .event,
                    text: "joined this thread (\(reason))", timestamp: at, status: [], source: .event, sequence: event.seq
                ))
            default:
                // message.queued / claimed / applied / answered are state, shown
                // as chips on the message item, not as rows of their own.
                continue
            }
        }

        return items.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            if a.source != b.source { return rank(a.source) < rank(b.source) }
            return a.sequence < b.sequence
        }
    }

    private static func rank(_ source: ThreadItem.Source) -> Int {
        switch source { case .message: return 0; case .record: return 1; case .event: return 2 }
    }

    private static func withStatus(_ item: ThreadItem, _ status: [String]) -> ThreadItem {
        ThreadItem(id: item.id, party: item.party, kind: item.kind, text: item.text, timestamp: item.timestamp,
                   status: status, source: item.source, sequence: item.sequence)
    }

    /// The chips for a message row: its state, and who has it.
    static func messageChips(_ message: ControlPlaneClient.Message) -> [String] {
        switch message.state {
        case "queued": return message.routedBy == "clarify" ? ["which computer?"] : ["queued"]
        case "claimed": return [message.targetSiteName.map { "claimed by \($0)" } ?? "claimed"]
        case "applied": return [message.targetSiteName.map { "\($0) working" } ?? "working"]
        case "answered": return message.pushedAt == nil ? ["answered"] : ["answered", "pushed"]
        default: return message.state.isEmpty ? [] : [message.state]
        }
    }

    static func deliveryChips(_ event: ThreadEvent) -> [String] {
        var chips: [String] = []
        if let name = event.string("event"), !name.isEmpty { chips.append(name) }
        if let delivered = event.int("delivered") { chips.append("delivered \(delivered)") }
        if let failed = event.int("failed"), failed > 0 { chips.append("failed \(failed)") }
        if let suppressed = event.int("suppressed"), suppressed > 0 { chips.append("suppressed \(suppressed)") }
        return chips
    }
}
