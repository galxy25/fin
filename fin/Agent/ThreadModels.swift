import Foundation

// docs/THREADS.md: a thread is one user request plus everything it caused. This
// file is the pure, Foundation-only half shared by every target (the tvOS app
// compiles it too — see project.yml): the control plane's thread shapes, the
// status chip, the default-selection rule, and turn membership. Nothing here
// talks to the network or knows about `ControlPlaneClient`.

/// A JSON value as the control plane sends it — used for a thread event's
/// `detail`, whose keys vary per kind (README "Threads" table). Rendered back
/// to text for the debug sheet; looked up by key for the timeline.
indirect enum JSONValue: Equatable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .bool(value); return }
        if let value = try? single.decode(Double.self) { self = .number(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        if let value = try? single.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? single.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a JSON value"))
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    /// Compact JSON text, keys sorted — deterministic for the debug sheet and tests.
    var jsonText: String {
        switch self {
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!.jsonText)" }.joined(separator: ",") + "}"
        }
    }
}

/// One decoder for every thread shape, usable from targets that have no
/// `ControlPlaneClient` (tvOS). The Lambda writes `%Y-%m-%dT%H:%M:%SZ`; a
/// fractional-seconds stamp is accepted too so a future change can't blank
/// every date.
enum ThreadDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO8601: \(text)"))
            }
            return date
        }
        return decoder
    }()

    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        plain.date(from: text) ?? fractional.date(from: text)
    }
}

/// Derived on the control plane, never stored (`_thread_status`); `unknown`
/// keeps a future status from failing the whole list.
enum ThreadStatus: String, Decodable, Equatable, CaseIterable {
    case waitingOnYou = "waiting_on_you"
    case stalled
    case working
    case answered
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThreadStatus(rawValue: raw) ?? .unknown
    }

    /// The chip: label, SF Symbol, and a tint name the views map to a color.
    /// Pure so the mapping is table-tested.
    var chip: ThreadChip {
        switch self {
        case .waitingOnYou: return ThreadChip(label: "waiting on you", systemImage: "hand.raised", tint: .orange)
        case .stalled: return ThreadChip(label: "stalled", systemImage: "exclamationmark.triangle", tint: .red)
        case .working: return ThreadChip(label: "Fin working", systemImage: "gearshape.2", tint: .blue)
        case .answered: return ThreadChip(label: "answered", systemImage: "checkmark.circle", tint: .green)
        case .unknown: return ThreadChip(label: "unknown", systemImage: "questionmark.circle", tint: .gray)
        }
    }
}

struct ThreadChip: Equatable {
    enum Tint: Equatable { case orange, red, blue, green, gray }
    let label: String
    let systemImage: String
    let tint: Tint
}

/// `GET /threads` row, and `thread` in `GET /threads/{id}`.
struct ThreadSummary: Decodable, Equatable, Identifiable {
    var id: String { threadId }
    let threadId: String
    let agent: String?
    let title: String
    let status: ThreadStatus
    let messageCount: Int
    let lastActivityAt: Date?
    let createdAt: Date?
    let participants: [String]
    let openGoal: String?

    enum CodingKeys: String, CodingKey {
        case threadId, agent, title, status, messageCount, lastActivityAt, createdAt, participants, openGoal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(String.self, forKey: .threadId)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(ThreadStatus.self, forKey: .status) ?? .unknown
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        lastActivityAt = try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        openGoal = try c.decodeIfPresent(String.self, forKey: .openGoal)
    }

    init(threadId: String, agent: String? = nil, title: String, status: ThreadStatus, messageCount: Int = 1,
         lastActivityAt: Date? = nil, createdAt: Date? = nil, participants: [String] = [], openGoal: String? = nil) {
        self.threadId = threadId; self.agent = agent; self.title = title; self.status = status
        self.messageCount = messageCount; self.lastActivityAt = lastActivityAt; self.createdAt = createdAt
        self.participants = participants; self.openGoal = openGoal
    }

    /// The picker's title: the first message, or a placeholder for a thread
    /// whose root row is gone.
    var displayTitle: String { title.isEmpty ? "Untitled request" : title }
}

struct ThreadListResponse: Decodable {
    let agent: String?
    let threads: [ThreadSummary]
}

/// One `fin-thread-events` row as `_public_thread_event` renders it.
struct ThreadEvent: Decodable, Equatable, Identifiable {
    var id: String { "\(threadId)#\(seq)" }
    let threadId: String
    let seq: Int
    let agent: String?
    let kind: String
    let actor: String
    let detail: [String: JSONValue]
    let at: Date?

    enum CodingKeys: String, CodingKey { case threadId, seq, agent, kind, actor, detail, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try c.decode(String.self, forKey: .threadId)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        actor = try c.decodeIfPresent(String.self, forKey: .actor) ?? "system"
        detail = try c.decodeIfPresent([String: JSONValue].self, forKey: .detail) ?? [:]
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
    }

    init(threadId: String, seq: Int, kind: String, actor: String, detail: [String: JSONValue] = [:], at: Date?, agent: String? = nil) {
        self.threadId = threadId; self.seq = seq; self.kind = kind; self.actor = actor
        self.detail = detail; self.at = at; self.agent = agent
    }

    func string(_ key: String) -> String? { detail[key]?.stringValue }
    func int(_ key: String) -> Int? { detail[key]?.intValue }
    /// Compact JSON of the detail dictionary, for the debug sheet.
    var detailText: String { JSONValue.object(detail).jsonText }
}

struct ThreadEventsResponse: Decodable {
    let threadId: String?
    let events: [ThreadEvent]
}

/// docs/THREADS.md §4: the picker's default is the newest thread that is not
/// *answered*, else the newest. Pure; the list is sorted here rather than
/// trusted, so a cached or hand-built list behaves the same.
enum ThreadSelection {
    static func sorted(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        threads.sorted { a, b in
            let at = a.lastActivityAt ?? a.createdAt ?? .distantPast
            let bt = b.lastActivityAt ?? b.createdAt ?? .distantPast
            if at != bt { return at > bt }
            return a.threadId > b.threadId
        }
    }

    static func defaultThreadID(_ threads: [ThreadSummary]) -> String? {
        let ordered = sorted(threads)
        return (ordered.first { $0.status != .answered } ?? ordered.first)?.threadId
    }
}

/// Which pane a relay line speaks to. The structured `target` field wins; an
/// older line (or a `send_input` tool call) is read from its text as a last
/// resort so the pane still renders as its own party.
enum PaneRelay {
    static let sendTools: Set<String> = ["send_session", "send_input"]
    static let readTools: Set<String> = ["read_session", "read_screen"]

    static func isRelay(_ record: AgentMirrorRecord) -> Bool {
        guard let tool = record.toolName else { return false }
        return sendTools.contains(tool) || readTools.contains(tool)
    }

    static func target(of record: AgentMirrorRecord) -> String? {
        guard isRelay(record) else { return nil }
        if let target = record.target { return target }
        return targetInText(record.text)
    }

    /// `target: main:2.0`, `"target": "main:2.0"`, `target=main:2.0`.
    static func targetInText(_ text: String) -> String? {
        guard let range = text.range(of: #"target"?\s*[:=]\s*"?([A-Za-z0-9_@$%.:-]+)"#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let sep = match.range(of: #"[:=]"#, options: .regularExpression) else { return nil }
        let value = match[sep.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
        return value.isEmpty ? nil : value
    }
}

/// Turn membership (docs/THREADS.md §4, "filtered to that thread's thread_id /
/// in_reply_to set"). A turn belongs to the thread any of its lines names via
/// `thread_id`; failing that, its prompt's `in_reply_to` is resolved through
/// the control-plane rows (`messageId → threadId`); failing THAT, the message
/// id itself is taken as its own root, which is exactly what the control plane
/// does for a row written before threads existed.
enum ThreadMembership {
    static func threadID(of turn: TranscriptTurns.Turn, threadOfMessage: [String: String]) -> String? {
        let lines = [turn.prompt].compactMap { $0 } + turn.steps + [turn.reply].compactMap { $0 }
        if let explicit = lines.lazy.compactMap(\.threadID).first { return explicit }
        guard let reply = turn.prompt?.inReplyTo else { return nil }
        return threadOfMessage[reply] ?? reply
    }

    static func turns(_ turns: [TranscriptTurns.Turn], in threadID: String?, threadOfMessage: [String: String]) -> [TranscriptTurns.Turn] {
        guard let threadID else { return turns }
        return turns.filter { self.threadID(of: $0, threadOfMessage: threadOfMessage) == threadID }
    }

    /// Records grouped by the turn they fall in, filtered the same way — for
    /// the Logs view, which groups by run rather than by turn.
    static func recordsMatch(_ records: [AgentMirrorRecord], threadID: String, threadOfMessage: [String: String]) -> Bool {
        TranscriptTurns.turns(from: records).contains { self.threadID(of: $0, threadOfMessage: threadOfMessage) == threadID }
    }
}
