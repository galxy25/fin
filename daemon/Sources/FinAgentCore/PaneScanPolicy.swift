// FinAgentCore — canonical copy, shared between the Fin app target and fin-agentd.
// Keep this file free of UI, SwiftData, and app-only imports.
import Foundation

/// When the heartbeat's tmux pane inventory may run.
///
/// A pure decision, separated from `Daemon.siteCapabilities` for the usual reason in this
/// codebase: the rule is worth testing and the thing it lives inside needs a daemon, a
/// terminal and a network to exist at all.
///
/// THE BUG THIS ENCODES. The old rule was "not while a turn is in flight, except the very
/// first scan" — a courtesy, so a background scan would not spend one of the SSH
/// connection's scarce session slots while the agent was using them. A skipped scan copies
/// the previous inventory forward, which is correct for a scan deferred by a few seconds
/// and catastrophic for one deferred forever. On a site whose turns last longer than its
/// heartbeat interval there is no moment that is not mid-turn, so the inventory froze at
/// whatever the first beat saw — on the work laptop (2026-09-15) an EMPTY list, captured
/// before the user had started any tmux session, and never revisited. The app showed a
/// computer with no terminals for as long as the daemon ran, while `read_session` on that
/// same daemon listed them happily, because a user's question is a turn of its own.
///
/// So the courtesy keeps its two escapes: it does not apply at all where a fixed command is
/// cheap (a local PTY spawns a child process; nothing is shared), and it expires once the
/// inventory is older than `starvationInterval`. Stale data presented as current is a worse
/// failure than contention.
public enum PaneScanPolicy {
    /// How long the inventory may go unrefreshed before the scan runs even mid-turn.
    public static let starvationInterval: TimeInterval = 180

    /// - Parameters:
    ///   - scanIsCheap: the transport's `fixedCommandsCompeteWithTurn`, inverted — true
    ///     when a fixed command costs the agent's turn nothing.
    ///   - isTurnInFlight: whether the agent is mid-turn right now.
    ///   - lastScanAt: when the scan last actually RAN. Nil means never, which is always a
    ///     reason to scan: until the first one lands the app shows a computer with no panes.
    ///     It must NOT be the time capabilities were last composed — a skipped scan
    ///     refreshes that, so measuring against it could never see a starved scan.
    public static func shouldScan(
        scanIsCheap: Bool,
        isTurnInFlight: Bool,
        lastScanAt: Date?,
        now: Date = Date(),
        starvationInterval: TimeInterval = PaneScanPolicy.starvationInterval
    ) -> Bool {
        guard let lastScanAt else { return true }
        if scanIsCheap { return true }
        if !isTurnInFlight { return true }
        return now.timeIntervalSince(lastScanAt) >= starvationInterval
    }
}
