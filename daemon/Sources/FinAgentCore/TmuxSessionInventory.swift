// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

// The write half of the read/write pair `TmuxSessionRead.swift`'s docstring already
// names as future work — same second-exec-channel-over-existing-SSH pattern
// (docs/SITES.md §3.3), read-only, DEFAULT socket, no new execution mechanism, only a
// new fixed argv and a pure parser.
public enum TmuxSessionInventory {
    /// Tab-separated; these fields are consumed here as data, never re-interpolated
    /// into a shell, so no quoting concern like `TmuxSessionRead.listFormat`'s.
    public static let listPanesFormat = "#{session_name}\t#{window_index}.#{pane_index}\t"
        + "#{pane_current_path}\t#{pane_current_command}\t#{session_windows}"

    /// `-a` lists panes across every session on the DEFAULT socket in one round trip —
    /// the whole inventory, one exec channel, one command.
    public static func listPanesArguments() -> [String] {
        ["tmux", "list-panes", "-a", "-F", listPanesFormat]
    }

    public struct DiscoveredPane: Equatable, Sendable {
        public let session: String
        public let paneTarget: String    // "window.pane", e.g. "0.1"
        public let cwd: String
        public let currentCommand: String
        public let windowCount: Int

        public init(session: String, paneTarget: String, cwd: String, currentCommand: String, windowCount: Int) {
            self.session = session
            self.paneTarget = paneTarget
            self.cwd = cwd
            self.currentCommand = currentCommand
            self.windowCount = windowCount
        }
    }

    public struct SessionSnapshot: Equatable, Sendable {
        public let session: String
        public let kind: String                 // "coding-agent" | "shell"
        public let cwd: String?
        public let agentPaneTarget: String?      // "session:window.pane", nil unless kind == "coding-agent"

        public init(session: String, kind: String, cwd: String?, agentPaneTarget: String?) {
            self.session = session
            self.kind = kind
            self.cwd = cwd
            self.agentPaneTarget = agentPaneTarget
        }
    }

    /// Tolerant: a malformed row (unexpected tmux build, mid-write race) is skipped,
    /// never thrown — this runs unattended on a timer.
    public static func parsePanes(_ raw: String) -> [DiscoveredPane] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let windowCount = Int(fields[4]) else { return nil }
            return DiscoveredPane(
                session: String(fields[0]), paneTarget: String(fields[1]),
                cwd: String(fields[2]), currentCommand: String(fields[3]),
                windowCount: windowCount
            )
        }
    }

    /// The "actual terminal agent, not just any shell" test. Overridable via
    /// `DaemonConfig.SessionActivityConfig.knownAgentProcesses`.
    public static let defaultCoderAgentProcessNames: Set<String> = [
        "fin", "fin-agentd", "claude", "claude-code", "codex", "aider",
        "cursor-agent", "amp", "opencode",
    ]

    /// Groups panes by session. A session counts as `"coding-agent"` if ANY of its
    /// panes runs a known-agent process; `cwd`/`agentPaneTarget` come from the FIRST
    /// such pane (falling back to the session's first pane at all when none match, for
    /// `cwd` only — a plain shell still gets a useful cwd in the registry even though
    /// its kind is `"shell"` and no activity note will ever be produced for it).
    public static func groupBySession(
        _ panes: [DiscoveredPane], knownAgents: Set<String> = defaultCoderAgentProcessNames
    ) -> [SessionSnapshot] {
        let bySession = Dictionary(grouping: panes, by: \.session)
        return bySession.map { session, ps in
            if let agentPane = ps.first(where: { knownAgents.contains($0.currentCommand) }) {
                return SessionSnapshot(
                    session: session, kind: "coding-agent", cwd: agentPane.cwd,
                    agentPaneTarget: "\(session):\(agentPane.paneTarget)"
                )
            }
            return SessionSnapshot(session: session, kind: "shell", cwd: ps.first?.cwd, agentPaneTarget: nil)
        }.sorted { $0.session < $1.session }   // deterministic order for tests/audit lines
    }
}

// MARK: - Pane titles (docs/SITES.md §3.3 capabilities)

extension TmuxSessionInventory {
    /// A second fixed argv for the site heartbeat: the same `list-panes -a` over the
    /// DEFAULT socket, plus the pane TITLE — which coding agents (Claude Code among
    /// them) set to the task they are currently on. That title is the cheapest and
    /// most literal "what is this pane doing" signal there is: no model call, no
    /// scrollback capture, dated by the heartbeat that carried it.
    public static let paneTitlesFormat = "#{session_name}\t#{window_index}.#{pane_index}\t"
        + "#{pane_title}\t#{pane_current_command}\t#{pane_current_path}"

    public static func paneTitlesArguments() -> [String] {
        ["tmux", "list-panes", "-a", "-F", paneTitlesFormat]
    }

    public struct TitledPane: Equatable, Sendable {
        public let session: String
        public let target: String       // "session:window.pane"
        public let title: String
        public let currentCommand: String
        public let cwd: String

        public init(session: String, target: String, title: String, currentCommand: String, cwd: String) {
            self.session = session
            self.target = target
            self.title = title
            self.currentCommand = currentCommand
            self.cwd = cwd
        }
    }

    /// Tolerant like `parsePanes`. A title equal to the hostname (tmux's default when
    /// nothing set one) is blanked, so a bare shell reads as untitled rather than as
    /// "doing <hostname>".
    public static func parseTitledPanes(_ raw: String, hostname: String? = nil) -> [TitledPane] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5 else { return nil }
            var title = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let hostname, title == hostname { title = "" }
            return TitledPane(
                session: String(fields[0]),
                target: "\(fields[0]):\(fields[1])",
                title: title,
                currentCommand: String(fields[3]),
                cwd: String(fields[4])
            )
        }
    }

    /// The heartbeat's `tmux_sessions` value: one entry per session, its panes with
    /// titles, plus the registry's task vocabulary and activity note when the session
    /// is registered. Titles and notes pass through `MemoryRedactor` — a pane title is
    /// whatever a program chose to put there, and this leaves the machine.
    public static func capabilitySessions(
        panes: [TitledPane],
        registry: RegistryDocument?
    ) -> [[String: Any]] {
        var order: [String] = []
        var grouped: [String: [TitledPane]] = [:]
        for pane in panes {
            if grouped[pane.session] == nil { order.append(pane.session) }
            grouped[pane.session, default: []].append(pane)
        }
        return order.map { session in
            var entry: [String: Any] = ["session": session]
            entry["panes"] = (grouped[session] ?? []).map { pane -> [String: Any] in
                var d: [String: Any] = ["target": pane.target, "command": pane.currentCommand]
                if !pane.title.isEmpty { d["title"] = MemoryRedactor.redact(pane.title) }
                // The cwd's last path component only — enough to say "fin" or
                // "pocketdj", never a full home-directory path.
                if let last = pane.cwd.split(separator: "/").last { d["cwd"] = String(last) }
                return d
            }
            if let registered = registry?.sessions.first(where: { $0.session == session }) {
                entry["registered"] = true
                if !registered.tasks.isEmpty { entry["tasks"] = registered.tasks }
                if let note = registered.activityNote, !note.isEmpty {
                    entry["activity_note"] = MemoryRedactor.redact(note)
                }
                if let at = registered.activityNoteUpdatedAt { entry["note_at"] = at }
            } else {
                entry["registered"] = false
            }
            return entry
        }
    }

    /// The compaction's "Terminal panes right now" lines, from the same data:
    /// "main:1.0 fin — multi-tenancy-cloud-control-plane".
    public static func observationLines(panes: [TitledPane]) -> [String] {
        panes.map { pane in
            var line = pane.target
            if let last = pane.cwd.split(separator: "/").last { line += " \(last)" }
            line += " — " + (pane.title.isEmpty ? pane.currentCommand : MemoryRedactor.redact(pane.title))
            return line
        }
    }
}
