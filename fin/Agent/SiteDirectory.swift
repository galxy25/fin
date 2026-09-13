import Foundation

/// One body Fin can run in — an EC2 worker, the resident daemon on a Mac, a
/// BYO box, or an app install — as `GET /sites` describes it. Display names
/// only ever reach the conversation; ids live behind a Details disclosure.
struct FinSite: Decodable, Equatable, Identifiable {
    var id: String { siteId }
    let siteId: String
    let siteId8: String
    let agent: String
    let kind: String
    let displayName: String
    let priority: Int
    let state: String
    let live: Bool
    let enrolledAt: Date?
    let lastHeartbeatAt: Date?
    let leaseUntil: Date?
    let capabilities: Capabilities
    let runId: String?
    let workerId: String?

    /// What a site reported in its last heartbeat. Everything optional: an
    /// older daemon reports less, a phone reports almost nothing.
    struct Capabilities: Decodable, Equatable {
        let daemonVersion: String?
        let alwaysOn: Bool?
        let browser: Bool?
        let brain: Brain?
        let tmuxSessions: [TmuxSession]?

        struct Brain: Decodable, Equatable {
            let kind: String?
            let model: String?
        }

        struct TmuxSession: Decodable, Equatable {
            let session: String
            let registered: Bool?
            let tasks: [String]?
            let activityNote: String?
            let noteAt: Date?
            let panes: [Pane]?

            struct Pane: Decodable, Equatable {
                let target: String
                let title: String?
                let command: String?
                let cwd: String?
            }

            enum CodingKeys: String, CodingKey {
                case session, registered, tasks, panes
                case activityNote = "activity_note"
                case noteAt = "note_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case browser, brain
            case daemonVersion = "daemon_version"
            case alwaysOn = "always_on"
            case tmuxSessions = "tmux_sessions"
        }
    }

    var kindGlyph: String {
        switch kind {
        case "ec2": return "cloud"
        case "app": return "iphone"
        default: return "desktopcomputer"
        }
    }

    /// "Levi's iMac · Fin lives here · online" — the row subtitle vocabulary.
    var roleLabel: String {
        switch kind {
        case "resident": return "Fin lives here"
        case "ec2": return "Cloud computer"
        case "byo": return "Fin can run here"
        default: return "This device"
        }
    }

    var statusLabel: String {
        if state == "retired" { return "retired" }
        if !live { return state == "stale" ? "lost contact" : "offline" }
        switch state {
        case "working": return "working"
        case "needs-input": return "needs your input"
        case "draining": return "finishing up"
        default: return "online"
        }
    }
}

/// The one-line header fold over every site: what the user needs to know
/// about Fin, not about any computer. Pure so it is tested directly.
enum FinPresence: Equatable {
    case needsInput(siteName: String)
    case working(siteName: String)
    case idle
    case asleep

    static func fold(_ sites: [FinSite]) -> FinPresence {
        let live = sites.filter { $0.live && $0.state != "retired" }
        if let needs = live.first(where: { $0.state == "needs-input" }) { return .needsInput(siteName: needs.displayName) }
        if let working = live.first(where: { $0.state == "working" }) { return .working(siteName: working.displayName) }
        return live.isEmpty ? .asleep : .idle
    }

    var headline: String {
        switch self {
        case .needsInput: return "Fin needs your input"
        // Levi (2026-09-12, from the car): the device belongs in the headline so
        // the small CarPlay Dashboard tile names it. Mirrored in the Lambda's
        // `_activity_content_state`; change both together.
        case .working(let name): return "Fin on it: \(name)"
        case .idle: return "Fin is ready"
        case .asleep: return "Fin is asleep — no computer is reachable"
        }
    }

    var detail: String? {
        switch self {
        case .needsInput(let name): return "on \(name)"
        case .working, .idle, .asleep: return nil
        }
    }

    var glyph: String {
        switch self {
        case .needsInput: return "exclamationmark.bubble"
        case .working: return "gearshape.2"
        case .idle: return "checkmark.circle"
        case .asleep: return "moon.zzz"
        }
    }
}

/// True inside a unit-test host. View tasks that would otherwise reach the
/// control plane no-op here: a render test must never depend on the network,
/// and — live, 2026-09-12 — an async fetch finishing after a render test had
/// torn its window down trapped inside SwiftData's @Query observer.
enum TestHost {
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["FIN_UI_TESTING"] != nil
}

/// The cloud transcript's records for one agent, for the Logs view — an
/// observable store rather than view state, so a fetch that lands after the
/// view is gone updates nothing that SwiftUI still owns.
@MainActor
final class CloudTraceStore: ObservableObject {
    @Published private(set) var records: [AgentMirrorRecord] = []
    private var loop: Task<Void, Never>?

    func start(agentName: String) {
        guard loop == nil, CloudControlPlaneConfig.isConfigured, !TestHost.isUnitTest else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                let page = await CloudAgentChannel.fetchTranscriptChunks(agentName: agentName)
                if !page.records.isEmpty { self.records = page.records }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}

/// A short-lived cache over `GET /sites`, shared by every view that shows
/// presence, so the console, the servers list, and the memory view don't each
/// hammer the control plane on their own refresh cadence.
@MainActor
final class SiteDirectory: ObservableObject {
    static let shared = SiteDirectory()
    static let cacheLifetime: TimeInterval = 15

    @Published private(set) var sites: [FinSite] = []
    @Published private(set) var lastError: String?
    @Published private(set) var fetchedAt: Date?
    private var inFlight: Task<[FinSite], Never>?

    var presence: FinPresence { FinPresence.fold(sites) }

    /// Returns the cached list when it is fresh, otherwise refetches. Never
    /// throws; an unconfigured control plane yields an empty list quietly.
    @discardableResult
    func refresh(force: Bool = false, now: Date = Date()) async -> [FinSite] {
        if TestHost.isUnitTest { return sites }
        if !force, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.cacheLifetime { return sites }
        if let inFlight { return await inFlight.value }
        let task = Task<[FinSite], Never> {
            guard CloudControlPlaneConfig.isConfigured else { return [] }
            switch await ControlPlaneClient.listSites() {
            case .success(let list): return list
            case .failure(let failure):
                await MainActor.run { self.lastError = Self.describe(failure) }
                return self.sites
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        sites = result
        fetchedAt = now
        if !result.isEmpty { lastError = nil }
        return result
    }

    nonisolated static func describe(_ failure: ControlPlaneClient.Failure) -> String {
        switch failure {
        case .notConfigured: return "control plane not configured"
        case .network: return "network error"
        case .http(_, let message): return message
        }
    }

    /// The observation lines the memory compactor and the memory view share:
    /// "Levi's iMac (working, 2m ago): main:1 fin — multi-tenancy-cloud-control-plane".
    nonisolated static func observationLines(_ sites: [FinSite], now: Date = Date()) -> [String] {
        var lines: [String] = []
        for site in sites where site.state != "retired" {
            let age = site.lastHeartbeatAt.map { Self.relativeAge(now.timeIntervalSince($0)) } ?? "never"
            let status = site.live ? site.statusLabel : "offline, last seen \(age)"
            let head = "\(site.displayName) (\(status)\(site.live ? ", \(age)" : ""))"
            let sessions = site.capabilities.tmuxSessions ?? []
            if sessions.isEmpty {
                lines.append(head)
                continue
            }
            for session in sessions {
                let panes = session.panes ?? []
                if panes.isEmpty {
                    var line = "\(head): tmux \(session.session)"
                    if let note = session.activityNote, !note.isEmpty { line += " — \(note)" }
                    lines.append(line)
                    continue
                }
                for pane in panes {
                    var line = "\(head): \(pane.target)"
                    if let cwd = pane.cwd, let last = cwd.split(separator: "/").last { line += " \(last)" }
                    if let title = pane.title, !title.isEmpty { line += " — \(title)" }
                    else if let command = pane.command, !command.isEmpty { line += " — \(command)" }
                    lines.append(line)
                }
                if let note = session.activityNote, !note.isEmpty {
                    lines.append("\(head): \(session.session) note — \(note)")
                }
            }
        }
        return lines
    }

    nonisolated static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}
