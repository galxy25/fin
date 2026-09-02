import Foundation

/// Decision table for the always-on watchdog: the 5-second tick that checks what each
/// agent runtime is doing and unwedges it. Factored pure so every condition is
/// table-testable without a runtime, a session, or a real clock — and so the tick's
/// contract is auditable in one place: it never makes a model call by itself, it only
/// escalates to a heartbeat turn when a correction is actually needed.
enum AgentWatchdog {
    /// `AgentRuntime.RunState` flattened to what the decisions need — the watchdog
    /// never cares which call is awaiting approval or what a failure said.
    enum StateKind {
        case idle
        case thinking
        case awaitingApproval
        case failed
    }

    enum Action: Equatable {
        /// The armed monitor has no live loop and no pending resume poll: restart it.
        case resumeMonitoring
        /// A failure has sat unretried past `recoveryDelay`: run one recovery
        /// heartbeat turn now.
        case recoveryHeartbeat
        /// The last beat is more than a full interval overdue: fire one immediately —
        /// the missed-beats-coalesce-on-foreground path made deterministic.
        case overdueHeartbeat
        /// The runtime has been thinking continuously past the wedge threshold:
        /// surface it once — never kill it, long awaits are legitimate.
        case thinkingWedgeNotice
        /// An idle auto-mode agent with an unfinished conversation and no monitor
        /// armed: arm one — the agent forgot to call its monitor tool, and the
        /// tick's contract is to unwedge it anyway. Never fired out of manual mode,
        /// and never against a suppression stamped by an earlier disarm.
        case armIdleUnfinished
    }

    /// How long a `.failed` state must persist before the watchdog intervenes — long
    /// enough that the heartbeat loop's own next-beat retry usually gets there first.
    static let recoveryDelay: TimeInterval = 30
    /// Continuous thinking beyond this earns a notice.
    static let thinkingWedgeThreshold: TimeInterval = 10 * 60
    /// Consolidation must succeed at least once per this window whenever
    /// unconsolidated episodic memories exist.
    static let consolidationFloor: TimeInterval = 24 * 60 * 60
    /// The consolidation machinery's own pacing between attempts (successful or
    /// not). The floor consults it too, so a due-but-paced tick doesn't audit-log
    /// and dispatch a guaranteed no-op every 5 seconds.
    static let consolidationPacing: TimeInterval = 30 * 60
    /// Consecutive failed recoveries beyond this pause auto-recovery entirely until
    /// the user interacts or the app is next foregrounded — five straight failures is
    /// an endpoint that is down, not flaky, and retrying forever only grows the
    /// transcript it re-sends on every attempt.
    static let maxRecoveryFailures = 5
    /// A conversation whose newest real (user/assistant) message is older than this
    /// is history, not work in flight — a week-old restored transcript must not arm
    /// a monitor at launch.
    static let conversationStaleAfter: TimeInterval = 24 * 60 * 60
    /// How long a conversation must have sat idle-and-unfinished before the tick
    /// auto-arms a monitor for it. Rapid back-and-forth chat never trips this — the
    /// user is right there, driving — while a genuinely walked-away conversation
    /// gets one reflective check a minute later.
    static let idleArmDelay: TimeInterval = 60
    /// The loop cadence a console/tool-armed monitor falls back to after
    /// `maxRecoveryFailures` straight failed beats. Sanctioned episodes are never
    /// disarmed by endpoint failures — a transient blip must not permanently stop
    /// an overnight user-armed monitor — they just retry this slowly until a beat
    /// succeeds.
    static let failedBeatBackoffSeconds = 300
    /// Beats a watchdog-armed monitoring episode may spend without acting on the
    /// terminal. A beat that actually delivers `send_input` bytes to a connected
    /// session is doing real work and refreshes the whole budget; a beat that only
    /// reads or replies — or whose send was denied or never delivered — consumes
    /// one. Console- and tool-armed episodes are user- or model-sanctioned and
    /// carry no budget.
    static let watchdogArmBeatBudget = 10

    /// Floor between recovery heartbeats. Never below a minute, but a user who chose
    /// a slow heartbeat chose that cadence for model calls generally — recovery
    /// retries must respect it rather than hammer at 60s regardless.
    static func recoveryCooldown(heartbeatSeconds: Int) -> TimeInterval {
        max(60, TimeInterval(heartbeatSeconds))
    }

    static func evaluate(
        armed: Bool,
        deviceMatches: Bool,
        serverMatches: Bool,
        mode: AgentMode,
        heartbeatSeconds: Int,
        heartbeatRunning: Bool,
        autoResumePending: Bool,
        sessionConnected: Bool,
        conversationUnfinished: Bool,
        conversationStale: Bool,
        idleSince: Date?,
        suppressed: Bool,
        state: StateKind,
        failedSince: Date?,
        thinkingSince: Date?,
        wedgeNoticePosted: Bool,
        lastHeartbeatAt: Date?,
        lastRecoveryAt: Date?,
        recoveryFailures: Int,
        now: Date,
        configurationBlocked: () -> Bool
    ) -> [Action] {
        var actions: [Action] = []
        // The same composite `shouldAutoResume` requires: the armed flag syncs across
        // devices, but only the device that armed the monitor, against the server it
        // was watching, may act on it.
        let monitored = armed && deviceMatches && serverMatches
            && mode == .auto && heartbeatSeconds > 0

        if monitored, !heartbeatRunning, !autoResumePending {
            actions.append(.resumeMonitoring)
        }

        // Unarmed is the gap the always-on tick exists for: an auto-mode agent that
        // never called its monitor tool sits idle mid-task with nothing scheduled to
        // nudge it. Requires a connected session (a heartbeat against a dead terminal
        // only fails) and at least `idleArmDelay` of continuous idle-unfinished time
        // (rapid back-and-forth chat is the user driving, not a wedge). Never fires
        // against a suppression — THE INVARIANT: the watchdog may only auto-arm when
        // the newest user-intent event postdates the last disarm — nor against a
        // stale conversation (old restored history is not work in flight), and
        // respects the recovery pause cap. Manual mode must never self-arm.
        // The configuration check is a closure — for on-device agents it queries
        // FoundationModels availability — and is consulted only after every free
        // gate passes, so the all-quiet 5s tick stays a pure in-memory read.
        if !armed, mode == .auto, state == .idle, !heartbeatRunning, !autoResumePending,
           sessionConnected, conversationUnfinished, !conversationStale, !suppressed,
           recoveryFailures < maxRecoveryFailures,
           idleSince.map({ now.timeIntervalSince($0) >= idleArmDelay }) ?? false,
           !configurationBlocked() {
            actions.append(.armIdleUnfinished)
        }

        let cooldown = recoveryCooldown(heartbeatSeconds: heartbeatSeconds)
        if monitored, state == .failed, let failedSince,
           now.timeIntervalSince(failedSince) >= recoveryDelay,
           recoveryFailures < maxRecoveryFailures,
           lastRecoveryAt.map({ now.timeIntervalSince($0) >= cooldown }) ?? true {
            actions.append(.recoveryHeartbeat)
        }

        // Only while the loop is alive: a dead loop is `resumeMonitoring`'s problem,
        // and firing turns before the resume poll confirms the session would race it.
        if monitored, heartbeatRunning, state == .idle, let lastHeartbeatAt,
           lastHeartbeatAt.addingTimeInterval(TimeInterval(2 * heartbeatSeconds)) < now {
            actions.append(.overdueHeartbeat)
        }

        // Deliberately not gated on `monitored`: a user-submitted turn can wedge just
        // as thoroughly as a heartbeat's.
        if state == .thinking, !wedgeNoticePosted, let thinkingSince,
           now.timeIntervalSince(thinkingSince) > thinkingWedgeThreshold {
            actions.append(.thinkingWedgeNotice)
        }

        return actions
    }

    /// The daily floor on memory consolidation: due when a full window has passed since
    /// the last *success* (distinct from the pacing stamp, which is written on every
    /// attempt) and there is actually something to consolidate. A busy runtime skips
    /// and retries next tick rather than resetting run attribution mid-turn.
    /// The memories check is a closure — it costs a SwiftData fetch — and is consulted
    /// only after the free checks say the floor is otherwise due, so the all-quiet 5s
    /// tick stays a pure read.
    static func consolidationFloorDue(
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        isBusy: Bool,
        now: Date,
        hasUnconsolidatedMemories: () -> Bool
    ) -> Bool {
        guard !isBusy,
              now.timeIntervalSince(lastSuccessAt ?? .distantPast) >= consolidationFloor,
              now.timeIntervalSince(lastAttemptAt ?? .distantPast) >= consolidationPacing
        else { return false }
        return hasUnconsolidatedMemories()
    }
}
