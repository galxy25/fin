import Foundation
import FinAgentCore

/// Ticked from the daemon's heartbeat wait-loop (`Daemon.swift`, right next to
/// `memoryConsolidator?.tickIfDue()`), on its own pacing — same shape as
/// `DaemonMemoryConsolidator`.
@MainActor
final class SessionInventoryScanner {
    nonisolated static let defaultIntervalSeconds: TimeInterval = 5 * 60

    private let registry: SessionRoutingRegistry
    private let intervalSeconds: TimeInterval
    private let knownAgentProcesses: Set<String>
    private let registeredByName: String
    private let audit: (String) -> Void

    /// Real default: runs the fixed `tmux list-panes -a` argv over the daemon's
    /// existing SSH connection's second exec channel (same mechanism `readSession`
    /// already uses). Tests replace this with a canned string — no tmux, no SSH, no
    /// network in CI. Same injectable shape as `DaemonMemoryConsolidator.completion`.
    var runInventory: () async throws -> String

    private var lastScanAt: Date?
    private var isRunning = false

    init(
        registry: SessionRoutingRegistry,
        session: HeadlessTerminalSession,
        intervalSeconds: TimeInterval = SessionInventoryScanner.defaultIntervalSeconds,
        knownAgentProcesses: Set<String> = TmuxSessionInventory.defaultCoderAgentProcessNames,
        registeredByName: String = "fin-agentd (auto)",
        audit: @escaping (String) -> Void
    ) {
        self.registry = registry
        self.intervalSeconds = intervalSeconds
        self.knownAgentProcesses = knownAgentProcesses
        self.registeredByName = registeredByName
        self.audit = audit
        self.runInventory = {
            let commandLine = TmuxSessionRead.commandLine(TmuxSessionInventory.listPanesArguments())
            let result = try await session.runFixedCommand(
                commandLine, maxResponseBytes: TmuxSessionRead.maxResponseBytes
            )
            return result.output
        }
    }

    func tickIfDue(now: Date = Date()) {
        guard !isRunning else { return }
        let due = lastScanAt.map { now.timeIntervalSince($0) >= intervalSeconds } ?? true
        guard due else { return }
        isRunning = true
        Task { [weak self] in
            await self?.run()
            self?.isRunning = false
        }
    }

    /// Internal (not private) so tests can await one pass directly, bypassing the
    /// fire-and-forget `Task` — same seam `DaemonMemoryConsolidator.run` gives.
    func run() async {
        lastScanAt = Date()
        let raw: String
        do {
            raw = try await runInventory()
        } catch {
            audit("[session-inventory] scan failed: \(error.localizedDescription)")
            return
        }
        let panes = TmuxSessionInventory.parsePanes(raw)
        let snapshots = TmuxSessionInventory.groupBySession(panes, knownAgents: knownAgentProcesses)
        var registered = 0
        for snapshot in snapshots {
            do {
                try await registry.observeDiscoveredSession(
                    session: snapshot.session, kind: snapshot.kind, cwd: snapshot.cwd,
                    agent: nil, agentPaneTarget: snapshot.agentPaneTarget,
                    registeredBy: registeredByName
                )
                registered += 1
            } catch {
                audit("[session-inventory] could not register \"\(snapshot.session)\": \(error.localizedDescription)")
            }
        }
        audit("[session-inventory] scan: \(snapshots.count) session(s) seen, \(registered) upserted")
    }
}
