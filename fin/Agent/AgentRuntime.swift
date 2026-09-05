import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

#if os(iOS) || os(visionOS)
/// UIKit's background-task bookkeeping asserts (and aborts) when touched off the main
/// thread — a live TestFlight crash showed a turn's task completing on a background
/// executor despite the runtime's @MainActor annotation. These wrappers make the hop
/// explicit and unconditional, so the crash class cannot exist regardless of which
/// executor a task lands on.
enum BackgroundGraceWindow {
    @MainActor
    static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }

    /// Safe from any executor: hops to the main actor before touching UIKit.
    nonisolated static func end(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
#endif

/// The single per-agent source of truth for the watchdog's durable, device-local
/// monitoring state: the suppression stamped by every disarm, and the provenance of
/// the current armed episode. One agent can be live in several runtimes at once
/// (the same agent opened against two servers), and per-runtime mirrors desync —
/// a Stop in one console must hold in the other, immediately. Dictionary mirror
/// over UserDefaults persistence: each agent's keys are read at most once (lazily,
/// primed at runtime init), every set/clear writes both, and the 5s tick's reads
/// come from the dictionary alone — zero UserDefaults I/O on the quiet tick.
@MainActor
final class MonitorSuppressionStore {
    static let shared = MonitorSuppressionStore()

    /// UserDefaults key holding the last disarm's timestamp for one agent. Device-
    /// local on purpose: suppression records *this* user's stop on *this* device,
    /// and must not sync a disarm to a device whose monitor they left running.
    static func suppressionKey(for agentID: UUID) -> String {
        "fin.watchdog.suppressedAt.\(agentID.uuidString)"
    }

    /// UserDefaults key holding the current armed episode's provenance
    /// ("watchdog"/"console"/"tool"), so a relaunch resumes a watchdog-armed
    /// episode with its no-progress budget instead of laundering it into an
    /// unbudgeted console arm. Written on every arm, removed on every disarm.
    static func armSourceKey(for agentID: UUID) -> String {
        "fin.watchdog.armSource.\(agentID.uuidString)"
    }

    private var suppressionCache: [UUID: Bool] = [:]
    private var armSourceCache: [UUID: AgentRuntime.ArmSource?] = [:]

    func isSuppressed(_ agentID: UUID) -> Bool {
        if let cached = suppressionCache[agentID] { return cached }
        let stored = UserDefaults.standard
            .object(forKey: Self.suppressionKey(for: agentID)) != nil
        suppressionCache[agentID] = stored
        return stored
    }

    func suppress(_ agentID: UUID) {
        UserDefaults.standard.set(Date(), forKey: Self.suppressionKey(for: agentID))
        suppressionCache[agentID] = true
    }

    func liftSuppression(_ agentID: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.suppressionKey(for: agentID))
        suppressionCache[agentID] = false
    }

    func armSource(for agentID: UUID) -> AgentRuntime.ArmSource? {
        if let cached = armSourceCache[agentID] { return cached }
        let stored = UserDefaults.standard
            .string(forKey: Self.armSourceKey(for: agentID))
            .flatMap(AgentRuntime.ArmSource.init(rawValue:))
        armSourceCache[agentID] = stored
        return stored
    }

    func setArmSource(_ source: AgentRuntime.ArmSource, for agentID: UUID) {
        UserDefaults.standard.set(source.rawValue, forKey: Self.armSourceKey(for: agentID))
        armSourceCache[agentID] = source
    }

    func clearArmSource(for agentID: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.armSourceKey(for: agentID))
        armSourceCache[agentID] = .some(nil)
    }

    #if DEBUG
    /// Test seam: the shared instance outlives every test, so suites that scrub the
    /// persisted keys must drop the mirrors too or stale entries shadow the scrub.
    func resetCachesForTesting() {
        suppressionCache.removeAll()
        armSourceCache.removeAll()
    }
    #endif
}

/// Drives one agent against one terminal session: prompt in, tool calls out, results
/// fed back until the model stops asking for tools.
@MainActor
final class AgentRuntime: ObservableObject {
    enum RunState: Equatable {
        case idle
        case thinking
        /// A tool call is held pending an explicit approval — either because the console
        /// is in manual mode, or because the command tripped the destructive heuristic.
        case awaitingApproval(call: AgentToolCall, reason: ApprovalReason)
        case failed(String)
    }

    enum ApprovalReason: Equatable {
        case manualMode
        case destructiveCommand

        var explanation: String {
            switch self {
            case .manualMode:
                return "Manual mode — approve to run this."
            case .destructiveCommand:
                return "This looks destructive. Approve only if you're sure."
            }
        }
    }

    /// Ceiling on tool round-trips per user message, so a model that keeps calling tools
    /// without converging stops on its own instead of hammering the session.
    private static let maxToolRoundTrips = 8

    @Published private(set) var transcript = AgentTranscript()
    @Published private(set) var state: RunState = .idle {
        didSet {
            // Watchdog instrumentation, kept in one place so no assignment site can
            // forget it: how long the runtime has been continuously failed/thinking.
            if case .failed = state {
                if failedSince == nil { failedSince = Date() }
            } else {
                failedSince = nil
            }
            if case .thinking = state {
                if thinkingSince == nil { thinkingSince = Date() }
            } else {
                thinkingSince = nil
                // A wedge episode is one unbroken stretch of thinking; leaving it
                // re-arms the once-per-episode notice.
                thinkingWedgeNotified = false
            }
            // The idle-arm delay clock: every turn that runs (thinking, an approval
            // wait, a failure) resets it, so only an unbroken stretch of idleness
            // can reach `AgentWatchdog.idleArmDelay`.
            if case .idle = state {
                if idleSince == nil { idleSince = Date() }
            } else {
                idleSince = nil
            }
        }
    }
    @Published var mode: AgentMode {
        didSet {
            // A mode change is user intent; it supersedes any earlier disarm.
            liftMonitoringSuppression()
            // Unattended monitoring is only defensible while the agent may act on its
            // own; dropping out of auto must drop the heartbeat with it — including a
            // pending auto-resume and the persisted armed flag.
            if mode != .auto { stopHeartbeat() }
            // The console's choice is the durable preference: written through so
            // auto/manual survives relaunch and syncs with the agent itself.
            if agent.defaultMode != mode { agent.defaultMode = mode }
        }
    }
    /// Arms the heartbeat loop. Setting it drives `startHeartbeat`/`stopHeartbeat`, so
    /// the console toggle is the whole control surface.
    @Published var isMonitoring = false {
        didSet {
            guard oldValue != isMonitoring else { return }
            if isMonitoring {
                startHeartbeat()
            } else if !isSuspendingHeartbeat {
                stopHeartbeat()
            }
        }
    }
    /// True while an armed monitor is waiting for its session to connect before
    /// resuming, so the console can say so instead of showing the toggle off and then
    /// silently flipping it on.
    @Published private(set) var isAutoResumePending = false
    /// Lets `suspendHeartbeat` clear `isMonitoring` without the didSet escalating a
    /// teardown into a user-intent stop that disarms the persisted flag.
    private var isSuspendingHeartbeat = false

    // Watchdog instrumentation — cheap state the 5s tick reads, no side effects.
    private(set) var lastHeartbeatFiredAt: Date?
    private(set) var failedSince: Date?
    private(set) var thinkingSince: Date?
    /// When the current unbroken stretch of `.idle` began (stamped at init for the
    /// initial state, maintained by the `state` didSet after that). The watchdog's
    /// idle-unfinished arm requires it to be at least `AgentWatchdog.idleArmDelay`
    /// old, so a conversation the user is actively driving never self-arms.
    private(set) var idleSince: Date?
    /// Rate-limits watchdog recovery heartbeats (`AgentWatchdog.recoveryCooldown`).
    private var lastRecoveryAt: Date?
    /// Consecutive watchdog recovery turns that ended `.failed`; past
    /// `AgentWatchdog.maxRecoveryFailures` auto-recovery pauses until the user
    /// interacts (submit/approve/toggle) or the app is next foregrounded.
    /// In-memory only — a relaunch is itself a fresh start.
    private(set) var consecutiveRecoveryFailures = 0
    /// True once the current wedge episode's notice has been posted; cleared when the
    /// runtime leaves `.thinking`.
    private var thinkingWedgeNotified = false
    /// Durable, device-local suppression of the watchdog's idle-unfinished auto-arm.
    /// THE INVARIANT: the watchdog may only auto-arm when the newest user-intent
    /// event postdates the last disarm. Every disarm path stamps a suppression date
    /// — console toggle off, Stop, the model's monitor-stop, a TASK COMPLETE
    /// completion, beat-budget/failed-beat exhaustion, and a pending
    /// `request_input` — and only genuine user intent (submit, approve, reject,
    /// console toggle on, mode change) lifts it. Persisted per agent so a disarmed
    /// conversation stays disarmed across relaunch and runtime replacement. Reads
    /// the shared per-agent store (primed at init), never per-runtime state: the
    /// same agent live in two runtimes must see one truth, and the quiet 5s tick
    /// never reads UserDefaults.
    var monitoringSuppressed: Bool {
        MonitorSuppressionStore.shared.isSuppressed(agent.id)
    }

    /// Who armed the current monitoring episode. Watchdog-armed episodes carry the
    /// no-progress beat budget; console- and tool-armed episodes are user- or
    /// model-sanctioned and unbudgeted. Persisted per agent through
    /// `MonitorSuppressionStore` on every arm and cleared on every disarm, so a
    /// relaunch resumes a watchdog-armed episode with its budget intact.
    enum ArmSource: String { case console, tool, watchdog }
    private(set) var monitoringArmSource: ArmSource = .console
    /// Beats a watchdog-armed episode may still spend without `send_input` progress
    /// (`AgentWatchdog.watchdogArmBeatBudget`).
    private(set) var watchdogBeatsRemaining = 0
    /// Consecutive heartbeat beats — any armed episode — whose turn ended `.failed`.
    /// At `AgentWatchdog.maxRecoveryFailures` a watchdog-armed monitor pauses
    /// durably, while console/tool-armed ones back off to a 5-minute cadence — a
    /// dead endpoint can't be retried every interval forever, but a transient blip
    /// must never permanently stop a monitor the user sanctioned.
    private(set) var consecutiveFailedBeats = 0
    /// True while a console/tool-armed monitor rides out consecutive failed beats
    /// at the backed-off cadence; the first successful beat clears it.
    private(set) var monitorBackoffActive = false
    /// True once the current beat's run loop has actually delivered `send_input`
    /// bytes to a connected session — the signal that a watchdog-armed monitor is
    /// doing real work, not just reading. Deliberately NOT stamped on attempt: a
    /// denied or undeliverable send must not refresh the beat budget.
    private(set) var beatUsedSendInput = false
    /// True once this runtime has audited the stale-conversation refusal; explicit
    /// ticks record it once per runtime, never per tick.
    private var staleArmNoticeRecorded = false

    let agent: Agent
    private let session: TerminalSession
    let serverName: String
    /// Persists the audit trail. Injected so the runtime stays free of SwiftData.
    private let log: (AgentLogRecord) -> Void
    /// Long-term memory, injected as closures for the same SwiftData-free reason.
    private let memory: AgentMemoryAccess
    /// The system prompt actually in use: the agent's own, plus the injected user
    /// profile when one exists. Rebuilt on init and clearConversation.
    private var activeSystemPrompt: String

    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    /// Fired on the MainActor after any turn — submitted or heartbeat — settles, so
    /// the remote-supervision channel can poll for the next directive and uplink
    /// status without waiting out its 30s cadence.
    var onTurnFinished: () -> Void = {}

    init(
        agent: Agent,
        session: TerminalSession,
        serverName: String,
        log: @escaping (AgentLogRecord) -> Void = { _ in },
        memory: AgentMemoryAccess = .noop,
        history: [AgentMessage] = []
    ) {
        self.agent = agent
        self.session = session
        self.serverName = serverName
        self.log = log
        self.memory = memory
        self.mode = agent.defaultMode
        // Primes the shared store's lazy per-agent load here, off the tick path, so
        // the quiet 5s tick's suppression reads are pure in-memory. A fresh runtime
        // adopts the persisted suppression — creation is not user intent and must
        // not lift it.
        _ = MonitorSuppressionStore.shared.isSuppressed(agent.id)
        self.activeSystemPrompt = Self.composeSystemPrompt(
            base: agent.systemPrompt,
            profile: memory.readCumulative(),
            provider: agent.provider,
            routing: memory.readRoutingRegistry?() ?? nil
        )
        transcript.reset(systemPrompt: activeSystemPrompt)
        // Restores the conversation from the durable audit trail, so quitting the app
        // doesn't silently lose the thread. Only the prose turns come back: tool results
        // describe a terminal state that has since moved on, and replaying them as fact
        // would mislead the model more than omitting them does.
        for message in history {
            transcript.append(message)
        }
        if !history.isEmpty {
            transcript.appendLocalNotice("Earlier conversation restored.")
            // The restored transcript is the same logical conversation, so adopt its
            // episodic record too — a relaunch must continue one record, not mint a
            // fresh conversationID per launch.
            if let open = memory.latestOpenConversation(agent.id) {
                conversationID = open.id
                conversationTitle = open.title
                conversationDigest = open.digest
            }
        }
        // The initial `.idle` never passes through the didSet; a restored
        // unfinished conversation's idle clock starts at runtime creation, so the
        // watchdog's reflective check lands `idleArmDelay` after launch, not
        // instantly.
        idleSince = Date()
        resumeMonitoringIfArmed()
    }

    /// Whether a freshly-created runtime should re-arm unattended monitoring: the user
    /// left a monitor armed, the agent is still configured to run one, and — because
    /// the armed flag syncs across devices while resumption must stay exclusive —
    /// this is the device that armed it, against the server it was watching.
    nonisolated static func shouldAutoResume(
        monitoringArmed: Bool,
        mode: AgentMode,
        heartbeatSeconds: Int,
        deviceMatches: Bool,
        serverMatches: Bool
    ) -> Bool {
        monitoringArmed && mode == .auto && heartbeatSeconds > 0
            && deviceMatches && serverMatches
    }

    /// Re-arms an armed monitor once the session is usable. The runtime is created
    /// alongside its session when the terminal screen opens, so the SSH connection is
    /// usually still coming up here — arming immediately would fire heartbeat turns at
    /// a terminal that can't answer yet. Poll for a usable session instead, generously:
    /// a monitor the user armed should survive a slow reconnect, not just a fast one.
    /// Safe to call repeatedly (each foregrounding does); a live heartbeat is left alone
    /// and a stale poll is simply restarted.
    func resumeMonitoringIfArmed() {
        // Adopt the persisted provenance before the gate: a watchdog-armed episode
        // with no configured heartbeat runs on the runtime-local episode interval,
        // which `effectiveHeartbeatSeconds` only supplies once provenance is known.
        if agent.monitoringArmed,
           let persisted = MonitorSuppressionStore.shared.armSource(for: agent.id) {
            monitoringArmSource = persisted
        }
        guard heartbeatTask == nil,
              Self.shouldAutoResume(
                  monitoringArmed: agent.monitoringArmed,
                  mode: mode,
                  heartbeatSeconds: effectiveHeartbeatSeconds,
                  deviceMatches: agent.monitoringDeviceID == DeviceIdentity.id,
                  serverMatches: agent.monitoringServerID == session.id
              ) else { return }
        autoResumeTask?.cancel()
        isAutoResumePending = true
        autoResumeTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            while !Task.isCancelled, Date() < deadline {
                guard let self else { return }
                if self.session.state == .connected {
                    if self.mode == .auto {
                        self.record(.notice, "[monitor] auto-resumed on launch/foreground")
                        // Provenance was restored from the per-agent store above
                        // (console-armed when no record exists — legacy arms are
                        // sanctioned). A watchdog-armed episode resumes with a
                        // fresh no-progress budget: the bound survives relaunch,
                        // the spent portion doesn't need to.
                        if self.monitoringArmSource == .watchdog {
                            self.watchdogBeatsRemaining = AgentWatchdog.watchdogArmBeatBudget
                        }
                        self.isMonitoring = true
                    }
                    self.isAutoResumePending = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self else { return }
            self.isAutoResumePending = false
            // A give-up must say so — an armed monitor silently not resuming is
            // indistinguishable from one that never tried.
            if !Task.isCancelled {
                self.record(.notice, "[monitor] auto-resume timed out — no connected session")
            }
        }
    }

    /// Current episode. One run spans a user message through the agent's final answer,
    /// so exported entries reassemble into a trajectory rather than a flat event stream.
    private var currentRunID = UUID()
    private var runSequence = 0

    /// Identity of the whole conversation across runs — `currentRunID` changes per user
    /// message, so episodic memory keys on this instead.
    private(set) var conversationID = UUID()
    private var conversationTitle = ""
    /// Rolling digest persisted as the conversation's episodic memory: one Q/A line per
    /// turn plus any explicit `remember` notes, oldest lines dropped past ~4000 chars.
    private var conversationDigest = ""
    private var conversationTags: [String] = []

    private func record(
        _ kind: AgentLogKind,
        _ text: String,
        toolName: String? = nil,
        toolArguments: String? = nil,
        disposition: AgentToolDisposition? = nil,
        usage: AgentUsage = AgentUsage(),
        metrics: AgentTurnMetrics? = nil,
        toolDurationMS: Int? = nil,
        approvalWaitMS: Int? = nil,
        attempt: Int = 1,
        retryCount: Int = 0,
        isFailure: Bool = false
    ) {
        guard !text.isEmpty else { return }
        runSequence += 1
        log(AgentLogRecord(
            agentID: agent.id,
            agentName: agent.name,
            serverName: serverName,
            runID: currentRunID,
            sequence: runSequence,
            kind: kind,
            text: text,
            toolName: toolName,
            toolArguments: toolArguments,
            disposition: disposition,
            modelIdentifier: agent.modelIdentifier,
            temperature: agent.temperature,
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            latencyMS: metrics?.totalMS,
            timeToFirstTokenMS: metrics?.timeToFirstTokenMS,
            interTokenMeanMS: metrics?.interTokenMeanMS,
            reasoningMS: metrics?.reasoningMS,
            contentMS: metrics?.contentMS,
            toolDurationMS: toolDurationMS,
            approvalWaitMS: approvalWaitMS,
            attempt: attempt,
            retryCount: retryCount,
            isFailure: isFailure
        ))
    }

    /// Remote-supervision audit entry point: lands "[s3] …" lines in this agent's
    /// own trail — and, behind the mirror gate, iCloud — with run attribution intact.
    func recordSupervisionNotice(_ text: String) {
        record(.notice, text)
    }

    var isBusy: Bool {
        switch state {
        case .idle, .failed: return false
        case .thinking, .awaitingApproval: return true
        }
    }

    var pendingApproval: (call: AgentToolCall, reason: ApprovalReason)? {
        if case .awaitingApproval(let call, let reason) = state { return (call, reason) }
        return nil
    }

    /// What a `submit` actually did with the text, so callers that must guarantee
    /// delivery (the directive channel, the relay applier) can distinguish "running
    /// now" and "will run, in order, when the current turn finishes" — both of
    /// which count as delivered — from "nothing happened".
    enum SubmitOutcome {
        /// The turn started immediately.
        case started
        /// The prompt joined `queuedPrompts`; it runs FIFO ahead of any heartbeat
        /// once the in-flight turn completes.
        case queued
        /// Nothing was accepted: empty text, or a configuration blocker stopped
        /// the turn from starting.
        case rejected
    }

    /// User prompts submitted while a turn was in flight, waiting to run FIFO.
    /// In-memory per-runtime by design: the queue does not survive relaunch or
    /// runtime replacement — a prompt nobody has answered is visible in the console
    /// until it runs, and a killed process drops it rather than replaying it into
    /// a conversation whose terminal has moved on.
    @Published private(set) var queuedPrompts: [String] = []

    /// Rough budget headroom for the tool schemas and the model's own reply, which are
    /// part of the window but never part of the transcript we measure.
    private var contextBudget: Int {
        max(512, agent.contextWindowTokens - agent.maxOutputTokens - 512)
    }

    // MARK: - Conversation

    /// Accepts a user prompt whenever it arrives. Idle: the turn starts immediately.
    /// Busy (thinking, awaiting approval, or consolidating): the prompt is QUEUED —
    /// it runs FIFO, through this same path, ahead of any heartbeat, when the
    /// in-flight turn completes. Enqueueing is deliberately side-effect free: the
    /// suppression-lift and recovery-reset a submit implies happen when the queued
    /// prompt actually runs (`startSubmittedTurn`), not at enqueue.
    @discardableResult
    func submit(_ text: String) -> SubmitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }
        if isBusy || isConsolidating || !queuedPrompts.isEmpty {
            queuedPrompts.append(trimmed)
            record(.notice, "[queue] prompt queued (\(queuedPrompts.count) waiting)")
            // Almost always a no-op (a turn is in flight and its completion
            // drains); covers the stranded case where the queue's head couldn't
            // start earlier (configuration blocker) and the runtime sits idle.
            drainQueuedPrompts()
            return .queued
        }
        return startSubmittedTurn(trimmed) ? .started : .rejected
    }

    /// Starts one submitted turn — the direct submit case and the queue's drain
    /// case share it byte for byte, so a queued prompt gets exactly the turn a
    /// typed one does (approval parking included). Returns false when a
    /// configuration blocker stopped the turn before it began.
    private func startSubmittedTurn(_ trimmed: String) -> Bool {
        resetRecoveryBackoff()
        liftMonitoringSuppression()
        if let blocker = configurationBlocker {
            state = .failed(blocker)
            return false
        }

        transcript.append(AgentMessage(role: .user, text: trimmed))
        currentRunID = UUID()
        runSequence = 0
        record(.userMessage, trimmed)
        state = .thinking
        AgentNotificationService.shared.requestAuthorizationIfNeeded()

        // A locked screen suspends the app and kills a turn mid-flight; the background
        // task buys the system's grace window (~30s) to finish and post the notification.
        // A turn longer than that still dies suspended — the OS offers no more without a
        // continuous background mode this app has no honest claim to.
        #if os(iOS) || os(visionOS)
        let backgroundTask = BackgroundGraceWindow.begin("agent-turn")
        #endif
        runTask = Task {
            let answer = await runLoop()
            notifyTurnFinished()
            onTurnFinished()
            if !Task.isCancelled {
                recordTurnInEpisodicMemory(userMessage: trimmed, answer: answer)
                await consolidateMemoriesIfDue()
            }
            #if os(iOS) || os(visionOS)
            BackgroundGraceWindow.end(backgroundTask)
            #endif
            // Every turn-completion path drains: prompts queued mid-turn run now,
            // in order, before any heartbeat gets a look-in.
            drainQueuedPrompts()
        }
        return true
    }

    // MARK: - Prompt queue

    /// Starts the queue's head as a normal submitted turn, whose own completion
    /// drains the next — FIFO chaining until the queue is empty. Called from every
    /// turn-completion path (submitted, heartbeat, watchdog-dispatched,
    /// consolidation); the guards make a redundant call free.
    private func drainQueuedPrompts() {
        // A cancelled task's tail must not resurrect the queue on a suspended or
        // stopped runtime — suspend()/cancel() discard first, and this guard closes
        // the race where the tail resumes between cancellation and the discard.
        guard !Task.isCancelled else { return }
        guard !isBusy, !isConsolidating, !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        if !startSubmittedTurn(next) {
            // Configuration blocker: nothing reached the transcript, so the prompt
            // goes back to the head — the `.failed` state shows the user what's
            // wrong, and the queue resumes once a turn can run again.
            queuedPrompts.insert(next, at: 0)
        }
    }

    /// Empties the queue with one audit line — Stop and Clear both discard what
    /// hasn't run yet, visibly.
    private func discardQueuedPrompts() {
        guard !queuedPrompts.isEmpty else { return }
        // Name what died: channel messages were marked applied/sent at enqueue, so
        // without these lines the audit trail's last word would claim they ran.
        // Previews pass the mirror's redaction like every other record.
        for prompt in queuedPrompts {
            record(.notice, "[queue] discarded unrun prompt: \(String(prompt.prefix(80)))")
        }
        record(.notice, "[queue] \(queuedPrompts.count) queued prompts discarded")
        queuedPrompts.removeAll()
    }

    #if DEBUG
    /// Test seam: lets suites exercise the queue-yield guards (heartbeat beat gate,
    /// watchdog dispatch sites) without racing a live turn.
    func enqueuePromptForTesting(_ text: String) {
        queuedPrompts.append(text)
    }
    #endif

    /// The reply the notification previews: the final assistant text, or the failure.
    private func notifyTurnFinished() {
        guard agent.notifyOnResponse else { return }
        let reply: String
        switch state {
        case .failed(let message):
            reply = "Failed: \(message)"
        default:
            guard let last = transcript.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) else { return }
            reply = last.text
        }
        AgentNotificationService.shared.notifyTurnFinished(
            agentName: agent.name,
            reply: reply,
            agentID: agent.id
        )
    }

    func cancel() {
        stopHeartbeat()
        // Stop is the strongest disarm in the UI — for a never-configured agent the
        // only reachable one — so it must hold against the watchdog exactly like
        // the console toggle: suppressed until the user's next action.
        suppressMonitoring()
        // Stop means stop: prompts waiting behind the cancelled turn are discarded,
        // not silently run the moment the cancel lands.
        discardQueuedPrompts()
        runTask?.cancel()
        runTask = nil
        resolveApproval(false)
        if isBusy { state = .idle }
        transcript.appendLocalNotice("Stopped.")
    }

    /// `cancel()` minus the persisted disarm and the transcript notice: teardown for a
    /// runtime being replaced (agent switch), where durably disarming would let a mere
    /// sync-driven `agents.first` change silently kill a monitor the user left running.
    func suspend() {
        // A replaced runtime must never run its backlog: the cancelled task's tail
        // still resumes and drains, and without this discard those prompts would
        // start fresh turns against the terminal the REPLACEMENT runtime now owns
        // (zombie turns invisible to the UI). Belt and braces with the
        // cancellation guard inside drainQueuedPrompts.
        discardQueuedPrompts()
        suspendHeartbeat()
        runTask?.cancel()
        runTask = nil
        resolveApproval(false)
        if isBusy { state = .idle }
    }

    func clearConversation() {
        guard !isBusy else { return }
        // A fresh conversation owes nothing to the old one's backlog.
        discardQueuedPrompts()
        stopHeartbeat()
        memory.markConversationStopped(conversationID)
        conversationID = UUID()
        conversationTitle = ""
        conversationDigest = ""
        conversationTags = []
        activeSystemPrompt = Self.composeSystemPrompt(
            base: agent.systemPrompt,
            profile: memory.readCumulative(),
            provider: agent.provider,
            routing: memory.readRoutingRegistry?() ?? nil
        )
        transcript.reset(systemPrompt: activeSystemPrompt)
        state = .idle
    }

    /// Called when the runtime is being discarded (session teardown), so the episodic
    /// record shows the conversation ended rather than dangling open forever.
    func endConversation() {
        memory.markConversationStopped(conversationID)
    }

    func approvePendingCall() {
        resetRecoveryBackoff()
        liftMonitoringSuppression()
        resolveApproval(true)
    }

    func rejectPendingCall() {
        resetRecoveryBackoff()
        liftMonitoringSuppression()
        resolveApproval(false)
    }

    /// The console button's entry point, distinct from the tool path and auto-resume
    /// so the audit trail shows *who* armed or disarmed the monitor. Also user
    /// attention, so a paused auto-recovery gets a fresh budget.
    func toggleMonitoringFromConsole() {
        resetRecoveryBackoff()
        if isMonitoring {
            // An explicit disarm must hold against the watchdog's idle-unfinished
            // re-arm check until the user acts again.
            suppressMonitoring()
        } else {
            // Re-arming is itself user intent and lifts any earlier suppression.
            liftMonitoringSuppression()
            monitoringArmSource = .console
        }
        record(.notice, isMonitoring
            ? "[monitor] disarmed by console toggle"
            : "[monitor] armed by console toggle")
        isMonitoring.toggle()
    }

    private func resolveApproval(_ approved: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        continuation.resume(returning: approved)
    }

    // MARK: - Monitoring suppression

    /// The store's suppression key, re-exported under the runtime's historical name.
    static func monitoringSuppressionKey(for agentID: UUID) -> String {
        MonitorSuppressionStore.suppressionKey(for: agentID)
    }

    /// Stamps a disarm. Called on every disarm path; only user intent lifts it.
    /// Routed through the shared per-agent store so every runtime for this agent —
    /// the same agent can be open against two servers at once — sees it instantly.
    private func suppressMonitoring() {
        MonitorSuppressionStore.shared.suppress(agent.id)
    }

    /// Lifts suppression. Called only on genuine user intent — submit, approve,
    /// reject, console toggle on, mode change — never on foregrounding or
    /// runtime creation.
    private func liftMonitoringSuppression() {
        MonitorSuppressionStore.shared.liftSuppression(agent.id)
    }

    // MARK: - Heartbeat

    /// Rides in every heartbeat turn: a short reflection first, then the action loop.
    static let heartbeatPrompt = "[heartbeat] Ask yourself: what is the user trying to do? "
        + "why? how can I help? how will I know it is done? do I need to ask the user for "
        + "any input? Then act: call read_terminal to check the task; send input if it "
        + "needs a push; call request_input if you need the user; if fully complete and "
        + "verified, end with TASK COMPLETE."

    /// Forward to the shared implementation in FinAgentCore, so the daemon's completion
    /// detection can never drift from the app's.
    nonisolated static func containsTaskComplete(_ text: String) -> Bool {
        AgentTurnLogic.containsTaskComplete(text)
    }

    /// The active-supervision default a watchdog-armed episode runs at when the
    /// agent has no configured heartbeat (the user explicitly chose Off) — the
    /// same fallback the monitor tool's start path picks, but held runtime-locally:
    /// a watchdog arm must never write `agent.heartbeatSeconds` (synced config
    /// belongs to the user's stepper and the monitor tool alone). An agent with a
    /// configured interval never reaches this — `effectiveHeartbeatSeconds` reads
    /// the agent's own setting first.
    static let watchdogEpisodeHeartbeatSeconds = Agent.defaultHeartbeatSeconds

    /// The interval monitoring actually runs at: the agent's configured heartbeat,
    /// or the runtime-local episode default when a watchdog arm is carrying an
    /// unconfigured agent. Zero still means "monitoring off" for sanctioned arms.
    var effectiveHeartbeatSeconds: Int {
        if agent.heartbeatSeconds > 0 { return agent.heartbeatSeconds }
        return monitoringArmSource == .watchdog ? Self.watchdogEpisodeHeartbeatSeconds : 0
    }

    /// The heartbeat loop's cadence right now: the effective interval, floored at
    /// `AgentWatchdog.failedBeatBackoffSeconds` while a console/tool-armed episode
    /// rides out consecutive failed beats.
    var currentHeartbeatInterval: Int {
        monitorBackoffActive
            ? max(effectiveHeartbeatSeconds, AgentWatchdog.failedBeatBackoffSeconds)
            : effectiveHeartbeatSeconds
    }

    /// On iOS the loop only runs while the app is awake — suspension pauses it and the
    /// missed beats fire as one check on foregrounding. Living with that is deliberate:
    /// a continuous background mode is a claim this app can't honestly make.
    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        autoResumeTask?.cancel()
        autoResumeTask = nil
        isAutoResumePending = false
        // A fresh episode gets a fresh failed-beat streak and normal cadence.
        consecutiveFailedBeats = 0
        monitorBackoffActive = false
        // Provenance persists device-locally alongside the armed flag, so a
        // relaunch resumes the episode as what it actually was — a watchdog arm
        // keeps its no-progress budget instead of becoming an unbudgeted console
        // arm.
        MonitorSuppressionStore.shared.setArmSource(monitoringArmSource, for: agent.id)
        // The armed flag persists through the agent (SwiftData autosave), so a killed
        // process re-arms this loop on the next runtime creation. Written only on
        // change to keep CloudKit from syncing a no-op every toggle. Bound to this
        // device and server because the flag syncs: any device may show it armed, but
        // only this device against this server may resume it.
        if !agent.monitoringArmed { agent.monitoringArmed = true }
        if agent.monitoringDeviceID != DeviceIdentity.id {
            agent.monitoringDeviceID = DeviceIdentity.id
        }
        if agent.monitoringServerID != session.id { agent.monitoringServerID = session.id }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                // No strong self may be held across the sleep: a replaced runtime's
                // only remaining reference would then be its own loop, keeping an
                // orphan monitor alive forever. Weak across the sleep, re-acquired
                // after, the loop dies naturally when the runtime deallocates.
                guard let interval = self?.heartbeatIntervalOrDisarm() else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                guard let self else { return }
                // A turn (or an approval wait) already in flight is its own progress
                // report; skipping keeps the loop from queueing checks behind it.
                // `.failed` is NOT busy and is retried on the next beat — one transient
                // endpoint blip must not silently end unattended monitoring. A running
                // consolidation is left to finish so its log entries stay attributed
                // to the run that produced them. Queued user prompts outrank beats
                // absolutely: the loop yields until the queue has drained.
                if !self.isBusy, !self.isConsolidating, self.queuedPrompts.isEmpty {
                    await self.runHeartbeatTurn()
                    // Prompts queued while the beat ran go next, before the loop
                    // ever sleeps toward another beat.
                    self.drainQueuedPrompts()
                }
            }
        }
    }

    /// The heartbeat loop's per-iteration gate: the interval to sleep, or nil after
    /// disarming — editing the interval to Off mid-monitoring must not leave an
    /// armed-looking dead monitor.
    private func heartbeatIntervalOrDisarm() -> Int? {
        guard mode == .auto, effectiveHeartbeatSeconds > 0, isMonitoring else {
            // Editing the interval to Off mid-monitoring is a user disarm like any
            // other: without a suppression stamp the idle-unfinished check would
            // re-arm a 60s watchdog episode over the cadence the user just refused.
            if mode == .auto, isMonitoring, effectiveHeartbeatSeconds <= 0 {
                suppressMonitoring()
            }
            stopHeartbeat()
            return nil
        }
        return currentHeartbeatInterval
    }

    /// User-intent stop: kills the loop AND clears the persisted armed state and
    /// provenance, so the monitor stays stopped across relaunches and devices.
    func stopHeartbeat() {
        suspendHeartbeat()
        agent.disarmMonitoring()
        MonitorSuppressionStore.shared.clearArmSource(for: agent.id)
    }

    /// Cancels the loop and any pending resume WITHOUT touching the persisted armed
    /// state — for tearing down a runtime being replaced or discarded, where the user
    /// never asked the monitor to stop and a later runtime should still auto-resume it.
    func suspendHeartbeat() {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        isAutoResumePending = false
        isSuspendingHeartbeat = true
        isMonitoring = false
        isSuspendingHeartbeat = false
    }

    /// One monitoring check, through the same runLoop as a typed message — tools, audit
    /// logging, and destructive-command gating all apply identically. Internal (not
    /// private) so `watchdogTick` can reuse it for recovery and overdue beats.
    func runHeartbeatTurn() async {
        // Dispatch-to-execution race guard: a user submit already queued on the
        // MainActor can claim the runtime (state → .thinking, runTask overwritten)
        // between this beat being scheduled and its body running. A claimed
        // runtime's beat must vanish without touching the transcript or the stamps.
        // `.failed` deliberately passes — the loop's next-beat retry and watchdog
        // recovery both legitimately beat from it. A non-empty prompt queue also
        // vetoes: queued user prompts run before any beat, without exception.
        guard !isBusy, !isConsolidating, queuedPrompts.isEmpty else { return }
        // Stamped before the configuration guard, so a blocked agent doesn't read as
        // eternally overdue and get re-poked by every watchdog tick.
        lastHeartbeatFiredAt = Date()
        guard configurationBlocker == nil else { return }
        beatUsedSendInput = false
        transcript.append(AgentMessage(role: .user, text: Self.heartbeatPrompt, isHeartbeat: true))
        currentRunID = UUID()
        runSequence = 0
        record(.userMessage, Self.heartbeatPrompt)
        state = .thinking
        // Same grace window a submitted turn gets — a locked screen otherwise kills
        // the check mid-flight and the loop wakes to a transport failure.
        #if os(iOS) || os(visionOS)
        let backgroundTask = BackgroundGraceWindow.begin("agent-heartbeat")
        defer { BackgroundGraceWindow.end(backgroundTask) }
        #endif
        // The just-finished turn's own answer, never scraped from the transcript — a
        // failed turn must not read a stale earlier reply as this check's status.
        let finalText = await runLoop() ?? ""

        if Task.isCancelled {
            // stopHeartbeat cancels mid-turn and runLoop's cancellation exits leave
            // state untouched; nothing else would ever clear a heartbeat's .thinking.
            if state == .thinking { state = .idle }
            return
        }
        if Self.containsTaskComplete(finalText) {
            concludeMonitoredTaskComplete()
            onTurnFinished()
            return
        }
        var failed = false
        if case .failed = state { failed = true }
        registerHeartbeatBeatOutcome(failed: failed, usedSendInput: beatUsedSendInput)
        onTurnFinished()
    }

    /// The heartbeat turn's TASK COMPLETE exit: disarm — and suppress, so the
    /// completion holds. Without suppression a transcript whose last assistant
    /// row diverges from the turn's final text (a tool-call-only cap exit while
    /// TASK COMPLETE appeared mid-loop) would re-arm the monitor the completion
    /// just said was done. Console/tool episodes notify: the user asked for that
    /// supervision and gets told it finished. A watchdog-armed episode converges
    /// silently — the user never asked for it, so its happy ending is an audit
    /// line, not a banner. Internal so the exit is testable without a live
    /// endpoint producing the token.
    func concludeMonitoredTaskComplete() {
        let quietly = monitoringArmSource == .watchdog
        stopHeartbeat()
        suppressMonitoring()
        if quietly {
            record(.notice, "[watchdog] auto-monitor concluded TASK COMPLETE — disarming quietly")
        } else {
            notifyTurnFinished()
        }
    }

    /// Books one heartbeat beat's outcome against the caps that bound an armed
    /// loop. Failed beats count toward `AgentWatchdog.maxRecoveryFailures`
    /// straight, so an endpoint that is down isn't retried every interval forever
    /// (up to three HTTP attempts per beat, transcript regrowing each time) — but
    /// what the cap does is provenance-aware: a watchdog-armed episode pauses
    /// durably (nobody asked for it), while a console/tool-armed one only backs
    /// off to a 5-minute cadence and keeps retrying — a transient endpoint blip
    /// must never permanently stop an overnight monitor the user sanctioned.
    /// Successful beats reset the streak (and end any backoff), then charge the
    /// watchdog-armed no-progress budget: a delivered `send_input` is real work
    /// and refreshes it; a read-or-reply-only beat consumes one, and exhaustion
    /// pauses the loop the same durable way. Console- and tool-armed episodes are
    /// unbudgeted. Internal so the cap tables are testable without a live
    /// endpoint driving real beats.
    func registerHeartbeatBeatOutcome(failed: Bool, usedSendInput: Bool) {
        if failed {
            consecutiveFailedBeats += 1
            guard consecutiveFailedBeats >= AgentWatchdog.maxRecoveryFailures,
                  isMonitoring else { return }
            if monitoringArmSource == .watchdog {
                stopHeartbeat()
                suppressMonitoring()
                record(.notice, "[watchdog] monitor paused after \(AgentWatchdog.maxRecoveryFailures) consecutive failed beats")
                AgentNotificationService.shared.notifyAttention(
                    agentName: agent.name,
                    message: "Monitoring paused after \(AgentWatchdog.maxRecoveryFailures) consecutive failed beats. Open the conversation to retry.",
                    agentID: agent.id,
                    signalKind: .monitoringPaused
                )
            } else if !monitorBackoffActive {
                // Entered once per outage; further failures ride the backed-off
                // cadence silently until a beat succeeds.
                monitorBackoffActive = true
                record(.notice, "[watchdog] monitor backing off after \(AgentWatchdog.maxRecoveryFailures) consecutive failed beats")
                AgentNotificationService.shared.notifyAttention(
                    agentName: agent.name,
                    message: "Monitoring is retrying every 5 minutes — the model endpoint has been failing.",
                    agentID: agent.id
                )
            }
            return
        }
        if monitorBackoffActive {
            monitorBackoffActive = false
            record(.notice, "[watchdog] monitor recovered — resuming normal cadence")
        }
        consecutiveFailedBeats = 0
        guard isMonitoring, monitoringArmSource == .watchdog else { return }
        if usedSendInput {
            watchdogBeatsRemaining = AgentWatchdog.watchdogArmBeatBudget
        } else {
            watchdogBeatsRemaining -= 1
            if watchdogBeatsRemaining <= 0 {
                stopHeartbeat()
                suppressMonitoring()
                record(.notice, "[watchdog] auto-monitor made no progress after \(AgentWatchdog.watchdogArmBeatBudget) beats — pausing")
                AgentNotificationService.shared.notifyAttention(
                    agentName: agent.name,
                    message: "Auto-monitor made no progress after \(AgentWatchdog.watchdogArmBeatBudget) beats. Open the conversation to continue.",
                    agentID: agent.id,
                    signalKind: .monitoringPaused
                )
            }
        }
    }

    // MARK: - Watchdog

    /// One cheap correction pass, driven externally every few seconds while the app is
    /// open (and immediately on foregrounding). Never makes a model call by itself —
    /// `AgentWatchdog.evaluate` only escalates to a heartbeat turn when a correction
    /// is actually needed, and an all-quiet tick is a pure read. Synchronous by
    /// contract: escalated turns are dispatched into `runTask` — the same task
    /// `submit` uses — so `cancel()`, `suspend()`, and the `isBusy` guard reach a
    /// watchdog-initiated turn exactly as they reach a user turn, and one slow
    /// runtime can never park the whole watchdog pass. Returns whether a turn was
    /// dispatched, so the caller knows `runTask` is claimed this pass and must not
    /// overwrite it (the daily consolidation floor uses the same handle).
    /// `isExplicit` marks the launch/foreground tick, which additionally audits one
    /// foreground-check line per non-empty conversation — the quiet 5s loop never
    /// writes when nothing needs doing.
    @discardableResult
    func watchdogTick(now: Date = Date(), isExplicit: Bool = false) -> Bool {
        let kind: AgentWatchdog.StateKind
        switch state {
        case .idle: kind = .idle
        case .thinking: kind = .thinking
        case .awaitingApproval: kind = .awaitingApproval
        case .failed: kind = .failed
        }
        let stale = conversationIsStale(now: now)
        let actions = AgentWatchdog.evaluate(
            armed: agent.monitoringArmed,
            deviceMatches: agent.monitoringDeviceID == DeviceIdentity.id,
            serverMatches: agent.monitoringServerID == session.id,
            mode: mode,
            // The loop's actual cadence — episode default and backoff included —
            // so overdue detection and recovery pacing track what the loop is
            // really doing, not just the synced config.
            heartbeatSeconds: currentHeartbeatInterval,
            heartbeatRunning: heartbeatTask != nil,
            autoResumePending: isAutoResumePending,
            // May read a stale `.connected` after system wake (no SSH keepalive);
            // an arm into a dead socket is bounded by the failed-beat cap (the
            // undelivered sends never refresh the beat budget) plus
            // `forceReconnectActiveSessionAfterWake`.
            sessionConnected: session.state == .connected,
            conversationUnfinished: conversationUnfinished,
            conversationStale: stale,
            idleSince: idleSince,
            suppressed: monitoringSuppressed,
            state: kind,
            failedSince: failedSince,
            thinkingSince: thinkingSince,
            wedgeNoticePosted: thinkingWedgeNotified,
            lastHeartbeatAt: lastHeartbeatFiredAt,
            lastRecoveryAt: lastRecoveryAt,
            recoveryFailures: consecutiveRecoveryFailures,
            now: now,
            // Lazy: for on-device agents this queries FoundationModels
            // availability, which the quiet tick must never do — evaluate
            // consults it only after every other arm gate has passed.
            configurationBlocked: { [self] in configurationBlocker != nil }
        )
        var dispatchedTurn = false
        // What this tick actually did, for the explicit tick's foreground-check line —
        // guarded-out actions are not taken and must not be claimed.
        var taken: [String] = []
        for action in actions {
            switch action {
            case .resumeMonitoring:
                record(.notice, "[watchdog] resumed a dead monitor loop")
                resumeMonitoringIfArmed()
                taken.append("resuming monitor")

            case .armIdleUnfinished:
                // `queuedPrompts.isEmpty` at every dispatch site: queued user
                // prompts outrank watchdog turns, so a tick landing while the
                // queue drains yields rather than interleaving a beat.
                guard !isBusy, !isConsolidating, queuedPrompts.isEmpty,
                      !dispatchedTurn else { continue }
                dispatchedTurn = true
                record(.notice, "[watchdog] agent idle with unfinished work — arming monitor loop")
                // Watchdog provenance carries the no-progress beat budget and — via
                // `effectiveHeartbeatSeconds` — the runtime-local 60s episode
                // interval for an unconfigured agent. The arm never writes
                // `agent.heartbeatSeconds`: synced config is the user's stepper
                // and the monitor tool's alone. Console and tool arm paths reset
                // provenance themselves.
                monitoringArmSource = .watchdog
                watchdogBeatsRemaining = AgentWatchdog.watchdogArmBeatBudget
                // Arms exactly as the monitor tool does: startHeartbeat persists the
                // armed flag and the device/server binding.
                isMonitoring = true
                // Stamped at arm time, before the first beat runs, so a back-to-back
                // explicit tick can't read a stale stamp from an earlier episode and
                // dispatch `.overdueHeartbeat` over the pending beat.
                lastHeartbeatFiredAt = now
                // First beat immediately — the arm exists to unwedge now, not one
                // interval from now. Through runTask so Stop and isBusy reach it.
                runTask = Task {
                    await runHeartbeatTurn()
                    drainQueuedPrompts()
                }
                taken.append("arming monitor loop")

            case .recoveryHeartbeat:
                guard !isBusy, !isConsolidating, queuedPrompts.isEmpty,
                      !dispatchedTurn else { continue }
                dispatchedTurn = true
                lastRecoveryAt = now
                record(.notice, "[watchdog] recovery heartbeat after failure (attempt \(consecutiveRecoveryFailures + 1))")
                runTask = Task {
                    await runHeartbeatTurn()
                    guard !Task.isCancelled else { return }
                    registerRecoveryOutcome()
                    drainQueuedPrompts()
                }
                taken.append("recovery heartbeat")

            case .overdueHeartbeat:
                guard !isBusy, !isConsolidating, queuedPrompts.isEmpty,
                      !dispatchedTurn else { continue }
                dispatchedTurn = true
                let overdueBy = lastHeartbeatFiredAt.map { Int(now.timeIntervalSince($0)) } ?? 0
                record(.notice, "[watchdog] fired overdue heartbeat (last beat \(overdueBy)s ago)")
                runTask = Task {
                    await runHeartbeatTurn()
                    drainQueuedPrompts()
                }
                taken.append("overdue heartbeat")

            case .thinkingWedgeNotice:
                thinkingWedgeNotified = true
                record(.notice, "[watchdog] turn running for over 10 minutes")
                transcript.appendLocalNotice(
                    "Still working for over 10 minutes — the current step may just be slow. Stop it if it looks stuck."
                )
                AgentNotificationService.shared.notifyAttention(
                    agentName: agent.name,
                    message: "Still working for over 10 minutes on the current step.",
                    agentID: agent.id
                )
                taken.append("thinking-wedge notice")
            }
        }

        // A stale conversation is deliberately not armed; say so once per runtime
        // where the user just looked, never on the quiet 5s loop.
        if isExplicit, !staleArmNoticeRecorded, conversationUnfinished, stale {
            staleArmNoticeRecorded = true
            record(.notice, "[watchdog] conversation stale — not arming")
        }

        // Proof of life, but only where the user just looked (launch/foreground) and
        // only for conversations that exist — the quiet 5s loop stays silent and the
        // audit trail isn't flooded with per-agent no-op lines every few seconds.
        if isExplicit, hasConversationContent {
            let summary: String
            if !taken.isEmpty {
                summary = taken.joined(separator: ", ")
            } else if conversationUnfinished, session.state != .connected {
                summary = "unfinished conversation, but no connected session"
            } else {
                summary = "all quiet"
            }
            record(.notice, "[watchdog] foreground check — \(summary)")
        }
        return dispatchedTurn
    }

    /// Any real conversation content — user or assistant turns, as opposed to the
    /// system prompt and local notices.
    private var hasConversationContent: Bool {
        transcript.messages.contains { $0.role == .user || $0.role == .assistant }
    }

    /// Whether the transcript describes work still in flight: a real conversation
    /// exists and its last assistant reply did not declare TASK COMPLETE. Local
    /// notices and heartbeat status rows carry system/user roles, so the last
    /// `.assistant` message is always the last real reply. Computed purely from the
    /// in-memory transcript — the quiet 5s tick must stay free of SwiftData fetches.
    var conversationUnfinished: Bool {
        guard hasConversationContent else { return false }
        guard let lastAssistant = transcript.messages.last(where: { $0.role == .assistant }) else {
            return true
        }
        return !Self.containsTaskComplete(lastAssistant.text)
    }

    /// Whether the newest real (user/assistant) message is older than the staleness
    /// window — a week-old restored conversation is history, not work in flight, and
    /// must not arm a monitor at launch. Restored messages carry their recorded
    /// timestamps (see `loadAgentHistory`); live ones are stamped on append. Pure
    /// in-memory transcript scan, so the quiet 5s tick stays free of I/O.
    func conversationIsStale(now: Date = Date()) -> Bool {
        guard let newest = transcript.messages.last(where: {
            $0.role == .user || $0.role == .assistant
        })?.timestamp else { return false }
        return now.timeIntervalSince(newest) > AgentWatchdog.conversationStaleAfter
    }

    /// Books a watchdog recovery turn's result: a turn that ended `.failed` again
    /// counts against the pause cap; anything else clears the streak.
    private func registerRecoveryOutcome() {
        if case .failed = state {
            consecutiveRecoveryFailures += 1
            if consecutiveRecoveryFailures >= AgentWatchdog.maxRecoveryFailures {
                record(.notice, "[watchdog] auto-recovery paused after \(consecutiveRecoveryFailures) failed attempts")
                AgentNotificationService.shared.notifyAttention(
                    agentName: agent.name,
                    message: "Auto-recovery paused after \(consecutiveRecoveryFailures) failed attempts. Open the conversation to retry.",
                    agentID: agent.id,
                    signalKind: .monitoringPaused
                )
            }
        } else {
            consecutiveRecoveryFailures = 0
        }
    }

    /// User attention resets the recovery pause — called on submit, approval, the
    /// console monitor toggle, and app foregrounding.
    func resetRecoveryBackoff() {
        consecutiveRecoveryFailures = 0
    }

    /// The watchdog's daily floor on consolidation: at least one successful
    /// distillation per 24h whenever unconsolidated memories exist, even if no turn
    /// ever triggers the post-turn path. Runs through the existing machinery, so its
    /// 30-minute pacing stamp still rate-limits a persistently failing backend.
    /// The candidates fetch is passed lazily — it hits SwiftData, and the 24h stamp
    /// must rule the tick out before any I/O runs. The consolidation itself (a model
    /// call) is dispatched into `runTask`, never awaited inline, so the watchdog pass
    /// stays cheap and `cancel()` reaches it.
    func consolidateIfDailyFloorDue() {
        let defaults = UserDefaults.standard
        guard AgentWatchdog.consolidationFloorDue(
            lastSuccessAt: defaults.object(forKey: Self.lastConsolidationSuccessKey) as? Date,
            lastAttemptAt: defaults.object(forKey: Self.lastConsolidationKey) as? Date,
            // A non-empty prompt queue counts as busy: queued user prompts run
            // before the floor's model call, which retries on a later tick.
            isBusy: isBusy || isConsolidating || !queuedPrompts.isEmpty,
            now: Date(),
            hasUnconsolidatedMemories: { !memory.consolidationCandidates(1).isEmpty }
        ) else { return }
        record(.notice, "[consolidation] daily floor triggered")
        runTask = Task {
            await consolidateMemoriesIfDue()
            drainQueuedPrompts()
        }
    }

    // MARK: - Run loop

    /// Non-nil when the agent can't run as configured, phrased for the console.
    var configurationBlocker: String? {
        switch agent.provider {
        case .appleOnDevice:
            return AppleOnDeviceBackend.availability.message
        case .openAICompatible:
            return agent.isRunnable
                ? nil
                : "This agent needs an endpoint URL and model name before it can run."
        }
    }

    /// Returns the turn's final assistant answer, or nil when the turn failed — the
    /// caller must never scrape the transcript for it, which on a failed turn silently
    /// resolves to a stale earlier reply.
    @discardableResult
    private func runLoop() async -> String? {
        let latestUserMessage = transcript.messages.last(where: { $0.role == .user })?.text ?? ""
        let intent = AgentIntentClassifier.classify(latestUserMessage)
        // Cap injected terminal text for the fragile on-device model only; the endpoint
        // path can afford the agent's full configured window.
        let maxReadLines = agent.provider == .appleOnDevice
            ? min(agent.terminalContextLines, 60)
            : nil
        let forced = await forceToolCallIfNeeded(intent, maxReadLines: maxReadLines)
        if Task.isCancelled { return nil }

        if let forced {
            transcript.append(AgentMessage(role: .assistant, text: "", toolCalls: [forced.call]))
            record(
                .assistantMessage,
                "(deterministic pre-classification forced \(forced.call.name) before the model was asked)",
                toolName: forced.call.name,
                toolArguments: forced.call.arguments
            )
            transcript.append(AgentMessage(role: .tool, text: forced.result, toolCallID: forced.call.id))
            record(.toolResult, forced.result, toolName: forced.call.name)
        }

        switch agent.provider {
        case .appleOnDevice:
            return await runOnDeviceTurn(forcedResult: forced?.result)
        case .openAICompatible:
            return await runEndpointLoop()
        }
    }

    /// Deterministically executes `read_terminal`/`send_input` before the model is ever
    /// invoked, for the two unambiguous intents `AgentIntentClassifier` can confidently
    /// recognize. `.ambiguous` returns `nil` immediately with no side effects, which
    /// preserves the plain-question path byte-for-byte — every other case in this function
    /// routes through the same `executeReadTerminal`/`executeSendInput` the model-initiated
    /// path uses, so logging, gating, and result framing are identical either way.
    private func forceToolCallIfNeeded(
        _ intent: AgentIntentClassifier.Intent,
        maxReadLines: Int?
    ) async -> (call: AgentToolCall, result: String)? {
        switch intent {
        case .ambiguous:
            return nil

        case .readTerminal:
            let startedAt = Date()
            let result = await executeReadTerminal(lines: maxReadLines, rawArguments: "{}")
            let call = AgentToolCall(
                id: "forced_\(UUID().uuidString.prefix(8))",
                name: AgentToolSpec.readTerminal.name,
                arguments: "{}",
                durationMS: Self.elapsedMS(since: startedAt)
            )
            return (call, result)

        case .sendInput(let command):
            let input = command.hasSuffix("\n") ? command : command + "\n"
            let encoded = (try? JSONSerialization.data(withJSONObject: ["input": input]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let startedAt = Date()
            let result = await executeSendInput(
                input: input,
                awaitOutputSeconds: Self.defaultAwaitOutputSeconds,
                rawArguments: encoded
            )
            let call = AgentToolCall(
                id: "forced_\(UUID().uuidString.prefix(8))",
                name: AgentToolSpec.sendInput.name,
                arguments: encoded,
                durationMS: Self.elapsedMS(since: startedAt)
            )
            return (call, result)
        }
    }

    // MARK: On-device

    private func runOnDeviceTurn(forcedResult: String?) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            failRun(AppleOnDeviceAvailability.osTooOld.message ?? "Unavailable.")
            return nil
        }

        // Injection is conditional now, not never: plain questions still get just the
        // question, because prepending raw terminal text to every prompt backfires on a
        // small model — shell output is itself highly patterned text, and a model handed a
        // screenful of prompt lines tends to *continue* the pattern rather than reason
        // about it, answering "what is 2+2" with more invented `ls` output. But when
        // `forceToolCallIfNeeded` has already deterministically run the matching tool
        // (`forcedResult` non-nil), its real, verbatim result is spliced in here so the
        // model composes its answer from that instead of guessing or re-deciding to call
        // the tool itself.
        let baseQuestion = transcript.messages.last(where: { $0.role == .user })?.text ?? ""
        let prompt: String
        if let forcedResult {
            prompt = baseQuestion + "\n\n---\nThe relevant tool has already been called on your behalf; this is its real, verbatim result. Base your answer only on this -- do not guess, and do not call the tool again this turn:\n" + forcedResult
        } else {
            prompt = baseQuestion
        }
        let startedAt = Date()

        // Foundation Models drives the tool loop itself, so the tools are the only place
        // this runtime gets to participate — they log, gate, and execute exactly as the
        // endpoint path does.
        let readTool = ReadTerminalTool { [weak self] lines in
            guard let self else { return "unavailable" }
            return await self.executeReadTerminal(
                lines: lines,
                rawArguments: lines.map { "{\"lines\":\($0)}" } ?? "{}"
            )
        }
        let sendTool = SendInputTool { [weak self] input, awaitSeconds in
            guard let self else { return "unavailable" }
            // The audit trail's rawArguments must reflect the full call as the model made
            // it — the chosen wait included — or the exported trajectories lose it.
            var arguments: [String: Any] = ["input": input]
            if let awaitSeconds { arguments["await_output_seconds"] = awaitSeconds }
            let encoded = (try? JSONSerialization.data(withJSONObject: arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await self.executeSendInput(
                input: input,
                awaitOutputSeconds: awaitSeconds ?? Self.defaultAwaitOutputSeconds,
                rawArguments: encoded
            )
        }

        let rememberTool = RememberTool { [weak self] title, content, tags in
            guard let self else { return "unavailable" }
            var arguments: [String: Any] = ["title": title, "content": content]
            if !tags.isEmpty { arguments["tags"] = tags }
            let encoded = (try? JSONSerialization.data(withJSONObject: arguments))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await self.executeRemember(title: title, content: content, tags: tags, rawArguments: encoded)
        }
        let recallTool = RecallTool { [weak self] query in
            guard let self else { return "unavailable" }
            let encoded = (try? JSONSerialization.data(withJSONObject: ["query": query]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await self.executeRecall(query: query, rawArguments: encoded)
        }
        let requestInputTool = RequestInputTool { [weak self] question in
            guard let self else { return "unavailable" }
            let encoded = (try? JSONSerialization.data(withJSONObject: ["question": question]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await self.executeRequestInput(question: question, rawArguments: encoded)
        }
        let monitorTool = MonitorTool { [weak self] action, intervalSeconds in
            guard let self else { return "unavailable" }
            let encoded = (try? JSONSerialization.data(
                withJSONObject: ["action": action, "interval_seconds": intervalSeconds]
            )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return await MainActor.run {
                self.executeMonitor(
                    action: action,
                    intervalSeconds: intervalSeconds,
                    rawArguments: encoded
                )
            }
        }

        let modelSession = LanguageModelSession(
            tools: [readTool, sendTool, rememberTool, recallTool, requestInputTool, monitorTool],
            instructions: activeSystemPrompt
        )

        do {
            let options = GenerationOptions(
                temperature: agent.temperature,
                maximumResponseTokens: agent.maxOutputTokens
            )
            let response = try await modelSession.respond(to: prompt, options: options)
            if Task.isCancelled { return nil }

            var metrics = AgentTurnMetrics()
            metrics.totalMS = Int(Date().timeIntervalSince(startedAt) * 1000)

            guard !AppleOnDeviceBackend.looksDegenerate(response.content) else {
                let message = "The on-device model returned a repeating, unusable response. "
                    + "Try rephrasing, or switch this agent to a custom endpoint."
                record(.error, message, metrics: metrics, isFailure: true)
                failRun(message)
                return nil
            }

            transcript.append(AgentMessage(
                role: .assistant,
                text: response.content,
                turnDurationMS: metrics.totalMS
            ))
            record(.assistantMessage, response.content, metrics: metrics)
            state = .idle
            return response.content
        } catch {
            if Task.isCancelled { return nil }
            let message = error.localizedDescription
            record(.error, message, isFailure: true)
            failRun(message)
            return nil
        }
        #else
        failRun(AppleOnDeviceAvailability.osTooOld.message ?? "Unavailable.")
        return nil
        #endif
    }

    private func failRun(_ message: String) {
        transcript.appendLocalNotice(message)
        state = .failed(message)
    }

    // MARK: Endpoint

    private func runEndpointLoop() async -> String? {
        var client = makeClient()
        var consecutiveEmptyReplies = 0
        var lastAnswerText: String?

        // A forced tool round from `forceToolCallIfNeeded` may already sit in the
        // transcript before this loop starts — `wireMessages` picks it up like any other
        // history, so the first request already carries a completed call/result pair.
        for _ in 0..<Self.maxToolRoundTrips {
            if Task.isCancelled { return nil }

            state = .thinking
            if transcript.compactIfNeeded(budget: contextBudget) {
                transcript.appendLocalNotice("Trimmed older turns to fit the context window.")
            }

            let outcome = await completeWithRetries(client: client)
            guard let completion = outcome.completion else {
                if Task.isCancelled { return nil }
                let message = outcome.errorMessage ?? "The model call failed."
                transcript.appendLocalNotice(message)
                state = .failed(message)
                return nil
            }

            if Task.isCancelled { return nil }

            transcript.append(AgentMessage(
                role: .assistant,
                text: completion.text,
                toolCalls: completion.toolCalls,
                turnDurationMS: completion.metrics.totalMS
            ))
            // Logged even when the model answered with tool calls and no prose, so the
            // trajectory records a turn happened and what it cost.
            record(
                .assistantMessage,
                completion.text.isEmpty ? "(tool call only)" : completion.text,
                usage: completion.usage,
                metrics: completion.metrics,
                attempt: outcome.attempts,
                retryCount: outcome.attempts - 1
            )
            if let reasoning = completion.reasoning, !reasoning.isEmpty {
                transcript.appendLocalNotice("Thought: \(reasoning)")
                record(.reasoning, reasoning, metrics: completion.metrics)
            }

            // No tools requested — normally the model is answering and the turn is over,
            // but a blank non-tool "final answer" is never a valid answer. Give the model
            // one nudge before giving up, so a single dropped-token blank reply doesn't
            // fail the whole run.
            if !completion.text.isEmpty { lastAnswerText = completion.text }

            if completion.toolCalls.isEmpty {
                let trimmedText = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedText.isEmpty else {
                    consecutiveEmptyReplies = 0
                    state = .idle
                    return trimmedText
                }

                consecutiveEmptyReplies += 1
                guard consecutiveEmptyReplies < 2 else {
                    let message = "The model stopped without producing an answer."
                    transcript.appendLocalNotice(message)
                    state = .failed(message)
                    return nil
                }
                transcript.append(AgentMessage(
                    role: .system,
                    text: "Your last reply was empty. Answer the user's question now: call a tool first if you need real data, then give a complete final answer."
                ))
                client = makeClient()
                continue
            }
            consecutiveEmptyReplies = 0

            for call in completion.toolCalls {
                if Task.isCancelled { return nil }
                let startedAt = Date()
                let result = await execute(call)
                transcript.recordToolCallDuration(Self.elapsedMS(since: startedAt), forCallID: call.id)
                transcript.append(AgentMessage(
                    role: .tool,
                    text: result,
                    toolCallID: call.id
                ))
                record(.toolResult, result, toolName: call.name)
            }

            // Re-read config each round so an edit to the agent mid-conversation applies.
            client = makeClient()
        }

        transcript.appendLocalNotice(
            "Stopped after \(Self.maxToolRoundTrips) tool calls without finishing. Send another message to continue."
        )
        state = .idle
        return lastAnswerText
    }

    /// How many times a single model turn may be attempted before the run gives up.
    private static let maxModelAttempts = 3

    /// Calls the endpoint, retrying transient failures with backoff. Every failed attempt
    /// is logged in its own right — a run that succeeded on the third try is materially
    /// different from one that succeeded immediately, and averaging them away would hide
    /// exactly the flakiness worth knowing about.
    private func completeWithRetries(
        client: AgentEndpointClient
    ) async -> (completion: AgentCompletion?, attempts: Int, errorMessage: String?) {
        var lastMessage: String?

        for attempt in 1...Self.maxModelAttempts {
            if Task.isCancelled { return (nil, attempt, nil) }
            do {
                let completion = try await client.complete(
                    messages: transcript.wireMessages,
                    tools: AgentToolSpec.all
                )
                return (completion, attempt, nil)
            } catch {
                if Task.isCancelled { return (nil, attempt, nil) }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastMessage = message

                let retryable = Self.isRetryable(error) && attempt < Self.maxModelAttempts
                record(
                    .error,
                    retryable ? "\(message) (attempt \(attempt), retrying)" : message,
                    attempt: attempt,
                    retryCount: attempt - 1,
                    isFailure: true
                )
                guard retryable else { break }
                // Plain exponential backoff: 400ms, then 800ms.
                try? await Task.sleep(for: .milliseconds(400 * (1 << (attempt - 1))))
            }
        }
        return (nil, Self.maxModelAttempts, lastMessage)
    }

    /// A dropped connection or an overloaded server is worth another try; a 4xx means the
    /// request itself is wrong and will fail identically forever.
    private static func isRetryable(_ error: Error) -> Bool {
        AgentTurnLogic.isRetryableEndpointError(error)
    }

    private func makeClient() -> AgentEndpointClient {
        AgentEndpointClient(
            baseURL: agent.endpointURL,
            model: agent.modelIdentifier,
            apiKey: KeychainStore.loadAgentAPIKey(for: agent.id),
            temperature: agent.temperature,
            maxOutputTokens: agent.maxOutputTokens
        )
    }

    // MARK: - Tools

    private func execute(_ call: AgentToolCall) async -> String {
        switch call.name {
        case AgentToolSpec.readTerminal.name:
            return await executeReadTerminal(
                lines: call.argument("lines").flatMap(Int.init),
                rawArguments: call.arguments
            )

        case AgentToolSpec.sendInput.name:
            guard let input = call.argument("input"), !input.isEmpty else {
                let message = "Error: send_input requires a non-empty \"input\" argument."
                record(.error, message, toolName: call.name,
                       toolArguments: call.arguments, isFailure: true)
                return message
            }
            return await executeSendInput(
                input: input,
                awaitOutputSeconds: call.argument("await_output_seconds").flatMap(Int.init)
                    ?? Self.defaultAwaitOutputSeconds,
                rawArguments: call.arguments
            )

        case AgentToolSpec.remember.name:
            return executeRemember(
                title: call.argument("title") ?? "",
                content: call.argument("content") ?? "",
                tags: call.argument("tags") ?? "",
                rawArguments: call.arguments
            )

        case AgentToolSpec.recall.name:
            return await executeRecall(query: call.argument("query") ?? "", rawArguments: call.arguments)

        case AgentToolSpec.requestInput.name:
            return executeRequestInput(
                question: call.argument("question") ?? "",
                rawArguments: call.arguments
            )

        case AgentToolSpec.monitor.name:
            return executeMonitor(
                action: call.argument("action") ?? "",
                intervalSeconds: call.argument("interval_seconds").flatMap(Int.init) ?? 0,
                rawArguments: call.arguments
            )

        default:
            let message = "Error: unknown tool \"\(call.name)\". Available tools: "
                + AgentToolSpec.all.map(\.name).joined(separator: ", ") + "."
            record(.error, message, toolName: call.name, isFailure: true)
            return message
        }
    }

    // MARK: - Memory

    /// Explicit memories fold into the conversation's single episodic record alongside
    /// the automatic digest, so a later auto-save can't clobber what the user asked to keep.
    /// Validation lives here — not in the endpoint dispatch — so the on-device tool loop
    /// gets the same correctable error instead of a false "Saved" for empty arguments.
    private func executeRemember(title: String, content: String, tags: String, rawArguments: String) -> String {
        guard !title.isEmpty, !content.isEmpty else {
            let message = "Error: remember requires non-empty \"title\" and \"content\" arguments."
            record(.error, message, toolName: AgentToolSpec.remember.name,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        let startedAt = Date()
        appendToDigest("Noted — \(title): \(content)")
        if conversationTitle.isEmpty { conversationTitle = Self.truncated(title, to: 80) }
        mergeTags(tags)
        let saved = persistEpisodicMemory()
        record(
            .toolCall,
            "remember: \(title)",
            toolName: AgentToolSpec.remember.name,
            toolArguments: rawArguments,
            disposition: .unguarded,
            toolDurationMS: Self.elapsedMS(since: startedAt),
            isFailure: !saved
        )
        guard saved else {
            return "Error: the memory store rejected the save; nothing was persisted."
        }
        return "Saved to memory — \(title): \(content)"
    }

    /// Once-per-session vector-lane audit guards. The silent keyword fallback hid a
    /// broken index in the field for hours; one notice per outcome per session makes
    /// the lane's health visible in the trail (and, mirror-gated, in iCloud) without
    /// flooding it.
    private var auditedVectorLaneServed = false
    private var auditedVectorLaneUnavailable = false

    /// Vector-first with keyword fallback; internal so the lane selection is testable
    /// directly (like `executeRequestInput`). The tool's result format is identical
    /// on both lanes, so the model-facing contract is unchanged.
    func executeRecall(query: String, rawArguments: String) async -> String {
        let startedAt = Date()
        // Semantic lane only for a real query — an empty query keeps the keyword
        // lane's "most recent memories" behavior. nil (gate off / index error) and
        // empty results both fall back, so recall never regresses below today's.
        var hits: [AgentMemoryHit] = []
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            if let semanticSearch = memory.semanticSearch {
                let vectorHits = await semanticSearch(agent.id, query, 5)
                hits = vectorHits ?? []
                if let vectorHits, !vectorHits.isEmpty {
                    if !auditedVectorLaneServed {
                        auditedVectorLaneServed = true
                        record(.notice, "[recall] vector lane served \(vectorHits.count) hits")
                    }
                } else if vectorHits == nil, !auditedVectorLaneUnavailable {
                    auditedVectorLaneUnavailable = true
                    let reason = memory.vectorLaneDiagnostic?() ?? "error unspecified"
                    record(.notice, "[recall] vector lane unavailable — \(reason)")
                }
            } else if !auditedVectorLaneUnavailable {
                auditedVectorLaneUnavailable = true
                record(.notice, "[recall] vector lane unavailable — platform gate")
            }
        }
        if hits.isEmpty {
            hits = memory.searchMemories(query, 5)
        }
        record(
            .toolCall,
            "recall: \(query.isEmpty ? "(most recent)" : query)",
            toolName: AgentToolSpec.recall.name,
            toolArguments: rawArguments,
            disposition: .unguarded,
            toolDurationMS: Self.elapsedMS(since: startedAt)
        )
        guard !hits.isEmpty else { return "no memories found" }
        // Each hit is a whole rolling digest (up to ~4000 chars); capped per hit —
        // hardest on the ~4096-token on-device session — so one recall can't blow the
        // window mid-tool-loop. Suffix, because the digest appends newest lines last.
        let cap = agent.provider == .appleOnDevice ? 400 : 1200
        return hits
            .map { hit in
                let content = hit.content.count > cap
                    ? "…" + String(hit.content.suffix(cap))
                    : hit.content
                return "[updated \(Self.relativeTime(hit.updatedAt))] \(hit.title): \(content)"
            }
            .joined(separator: "\n")
    }

    /// Notifies the user that the agent is blocked on them; the reply arrives as
    /// whatever they type next, so the tool itself resolves immediately.
    /// Internal so the blocked-on-the-user suppression is testable directly.
    func executeRequestInput(question: String, rawArguments: String) -> String {
        guard !question.isEmpty else {
            let message = "Error: request_input requires a non-empty \"question\" argument."
            record(.error, message, toolName: AgentToolSpec.requestInput.name,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
        // Blocked on the user: suppress the watchdog's re-arm so an unanswered
        // question can't become a notification per 5s-tick-armed beat — their
        // answering submit lifts it. Deliberately does NOT disarm an armed loop:
        // the console/tool chose that cadence, and a watchdog-armed one is already
        // bounded by the beat budget.
        suppressMonitoring()
        let startedAt = Date()
        record(
            .toolCall,
            "request_input: \(question)",
            toolName: AgentToolSpec.requestInput.name,
            toolArguments: rawArguments,
            disposition: .unguarded,
            toolDurationMS: Self.elapsedMS(since: startedAt)
        )
        AgentNotificationService.shared.notifyInputRequested(
            agentName: agent.name,
            question: question,
            agentID: agent.id
        )
        transcript.appendLocalNotice("Waiting for your input: \(question)")
        return "The user has been notified. Their next message will answer your question."
    }

    /// Lets the agent arm its own monitoring loop when it recognizes a supervision task,
    /// instead of sitting idle until a human toggles the console. A live wrapper test
    /// exposed exactly that gap: told to supervise an inner agent, the model finished its
    /// turn and had no mechanism to continue. Auto-mode only — an agent in manual mode
    /// self-escalating to unattended operation would defeat the point of approval mode,
    /// so there it asks the user instead. Internal so the interval clamp and the
    /// stop path's suppression are testable directly.
    func executeMonitor(action: String, intervalSeconds: Int, rawArguments: String) -> String {
        let toolName = AgentToolSpec.monitor.name
        switch action.lowercased() {
        case "start":
            guard mode == .auto else {
                let message = "Cannot start monitoring in manual mode. Ask the user to "
                    + "switch this conversation to auto mode first."
                record(.error, message, toolName: toolName,
                       toolArguments: rawArguments, isFailure: true)
                return message
            }
            // Floor 15: a model-chosen 1s cadence is a turn storm, not supervision;
            // 0 means "unset" and defers to the AGENT's configured heartbeat — the
            // user's stepper is the authoritative knob when the model doesn't choose.
            if intervalSeconds > 0 {
                agent.heartbeatSeconds = min(max(intervalSeconds, 15), 600)
            }
            if agent.heartbeatSeconds <= 0 {
                // No interval configured anywhere — pick the stock default rather
                // than failing; a monitor that never fires is the bug this fixes.
                agent.heartbeatSeconds = Agent.defaultHeartbeatSeconds
            }
            record(.toolCall, "monitor start (every \(agent.heartbeatSeconds)s)",
                   toolName: toolName, toolArguments: rawArguments, disposition: .unguarded)
            monitoringArmSource = .tool
            // Persist provenance even when a watchdog episode is already live —
            // the didSet guard will skip startHeartbeat, and a relaunch must not
            // resume this model-sanctioned monitor with a watchdog beat budget.
            MonitorSuppressionStore.shared.setArmSource(.tool, for: agent.id)
            isMonitoring = true
            return "Monitoring armed: you will be woken every \(agent.heartbeatSeconds)s to "
                + "check the task and act. End a reply with TASK COMPLETE (or call monitor "
                + "with \"stop\") when the task is verified done."

        case "stop":
            record(.toolCall, "monitor stop",
                   toolName: toolName, toolArguments: rawArguments, disposition: .unguarded)
            isMonitoring = false
            // The model's own sanctioned stop is a disarm the watchdog must not
            // fight — without suppression the idle-unfinished check would falsify
            // "Monitoring disarmed." seconds later and the loop would oscillate.
            suppressMonitoring()
            return "Monitoring disarmed."

        default:
            let message = "Error: monitor requires action \"start\" or \"stop\"."
            record(.error, message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }
    }

    /// Auto-saves this conversation's episodic memory after each completed turn. The
    /// answer comes from the turn that just ran — nil means it failed, and recording
    /// that beats misattributing a stale earlier reply to the new question.
    private func recordTurnInEpisodicMemory(userMessage: String, answer: String?) {
        let resolved = answer.flatMap { $0.isEmpty ? nil : $0 } ?? "(turn failed)"
        appendToDigest("Q: \(Self.truncated(userMessage, to: 200)) / A: \(Self.truncated(resolved, to: 300))")
        if conversationTitle.isEmpty { conversationTitle = Self.truncated(userMessage, to: 80) }
        mergeTags("auto,conversation")
        if !persistEpisodicMemory() {
            record(.notice, "(memory) episodic save failed; will retry next turn")
        }
    }

    @discardableResult
    private func persistEpisodicMemory() -> Bool {
        memory.saveEpisodic(
            conversationID,
            agent.id,
            conversationTitle,
            conversationDigest,
            conversationTags.joined(separator: ",")
        )
    }

    /// Keeps the digest under ~4000 chars by dropping whole oldest lines first.
    private func appendToDigest(_ line: String) {
        conversationDigest = conversationDigest.isEmpty ? line : conversationDigest + "\n" + line
        while conversationDigest.count > 4000 {
            guard let newline = conversationDigest.firstIndex(of: "\n") else {
                conversationDigest = String(conversationDigest.suffix(4000))
                break
            }
            conversationDigest = String(conversationDigest[conversationDigest.index(after: newline)...])
        }
    }

    private func mergeTags(_ csv: String) {
        for raw in csv.split(separator: ",") {
            let tag = raw.trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, !conversationTags.contains(tag) {
                conversationTags.append(tag)
            }
        }
    }

    private static func composeSystemPrompt(
        base: String,
        profile: String,
        provider: AgentProvider,
        routing: RegistryDocument? = nil
    ) -> String {
        var prompt = base
        var trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // The profile syncs from devices with roomier models, so it must be capped at
            // injection: the on-device window is fixed at ~4096 tokens and an oversized
            // synced profile once blew it outright. Suffix keeps the newest content.
            let cap = provider == .appleOnDevice ? 600 : 1200
            if trimmed.count > cap {
                trimmed = "…" + String(trimmed.suffix(cap))
            }
            prompt += "\n\nUser profile (from accumulated memory):\n\(trimmed)\nUse remember to save important new facts; use recall to look up past context."
        }
        // `promptSection` is nil for a nil/empty registry, so agents without any
        // registered sessions keep a byte-identical system prompt — routing is
        // strictly additive until someone registers a session.
        if let routing, let section = SessionRouter.promptSection(registry: routing) {
            prompt += "\n\n" + section
        }
        return prompt
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relativeTime(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count <= limit ? flattened : String(flattened.prefix(limit)) + "…"
    }

    // MARK: - Consolidation

    static let lastConsolidationKey = "fin.memory.lastConsolidation"
    /// Stamped only when a consolidation actually lands (profile written, records
    /// marked) — the watchdog's daily floor keys off success, while the pacing stamp
    /// above is written before every attempt, failed ones included.
    static let lastConsolidationSuccessKey = "fin.memory.lastConsolidationSuccess"
    // Shared with the watchdog's daily-floor guard, which must agree on pacing or
    // it would dispatch attempts this guard immediately no-ops.
    private static let consolidationInterval = AgentWatchdog.consolidationPacing
    /// Hard bound on the stored profile. The prompt asks for under 1500 chars; nothing
    /// a model outputs is allowed to ratchet the profile — which is re-fed as the next
    /// consolidation's input and injected into every request — past this.
    private static let maxStoredProfileCharacters = 2000

    /// True while the post-turn consolidation model call is in flight, so the heartbeat
    /// won't start a turn that resets run attribution underneath it.
    private var isConsolidating = false

    /// Guards the wholesale profile replacement: a refusal, an echo of the "(none)"
    /// placeholder the prompt itself injects, or a drastic shrink keeps the old profile.
    nonisolated static func acceptableConsolidatedProfile(_ candidate: String, replacing existing: String) -> Bool {
        guard candidate.count >= 40,
              !candidate.contains("(none)"),
              !AppleOnDeviceBackend.looksDegenerate(candidate) else { return false }
        // A shrink past 70% of a substantial profile is a bad reply, not a distillation.
        if existing.count > 200, candidate.count < existing.count * 3 / 10 { return false }
        return true
    }

    /// Distills recent episodic memories into the single cumulative user profile, at most
    /// once per interval. Failures are logged and skipped, never fatal — and candidates
    /// carry per-record markers (`consolidatedAt`), so a failed attempt loses nothing.
    func consolidateMemoriesIfDue() async {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastConsolidationKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.consolidationInterval else { return }
        // The on-device model's ~4096-token window bounds both the candidate count and
        // the per-digest excerpt; the endpoint path gets more, but not unbounded.
        let onDevice = agent.provider == .appleOnDevice
        let recent = memory.consolidationCandidates(onDevice ? 5 : 10)
        guard !recent.isEmpty else { return }

        let profile = memory.readCumulative()
        let perHitCap = onDevice ? 400 : 1500
        var input = "Current profile:\n" + (profile.isEmpty ? "(none)" : profile) + "\n\nRecent conversations:"
        for hit in recent {
            let content = hit.content.count > perHitCap
                ? "…" + String(hit.content.suffix(perHitCap))
                : hit.content
            input += "\n\n\(hit.title)\n\(content)"
        }
        let instruction = "Merge into a concise user profile: their ongoing tasks, goals, "
            + "preferences, styles, tastes. Keep under 1500 characters. Output only the "
            + "updated profile text."

        // Pacing only, stamped before the attempt so a persistently failing backend
        // can't retry every turn; the per-record markers carry the actual progress.
        defaults.set(Date(), forKey: Self.lastConsolidationKey)
        isConsolidating = true
        defer { isConsolidating = false }
        do {
            let updated: String
            switch agent.provider {
            case .openAICompatible:
                let completion = try await makeClient().complete(
                    messages: [
                        AgentMessage(role: .system, text: instruction),
                        AgentMessage(role: .user, text: input),
                    ],
                    tools: []
                )
                updated = completion.text
            case .appleOnDevice:
                updated = try await Self.consolidateOnDevice(instruction: instruction, input: input)
            }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.acceptableConsolidatedProfile(trimmed, replacing: profile) else {
                record(.notice, "(memory consolidation) skipped: model returned unusable profile text; kept the existing profile")
                return
            }
            let bounded = String(trimmed.prefix(Self.maxStoredProfileCharacters))
            guard memory.writeCumulative(bounded) else {
                record(.notice, "(memory consolidation) failed: the store rejected the profile write")
                return
            }
            memory.markConsolidated(recent.map(\.id))
            defaults.set(Date(), forKey: Self.lastConsolidationSuccessKey)
            record(.notice, "(memory consolidation) user profile updated (\(bounded.count) chars)")
        } catch {
            record(.notice, "(memory consolidation) failed: \(error.localizedDescription)")
        }
    }

    private struct ConsolidationUnavailable: LocalizedError {
        var errorDescription: String? { "the on-device model is unavailable" }
    }

    private static func consolidateOnDevice(instruction: String, input: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *), AppleOnDeviceBackend.isAvailable else {
            throw ConsolidationUnavailable()
        }
        let session = LanguageModelSession(instructions: instruction)
        let response = try await session.respond(
            to: input,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 600)
        )
        return response.content
        #else
        throw ConsolidationUnavailable()
        #endif
    }

    /// Shared by both providers. Foundation Models calls this through its own tool loop;
    /// the endpoint path calls it from `execute(_:)`.
    private func executeReadTerminal(lines requested: Int?, rawArguments: String) async -> String {
        let startedAt = Date()
        let lines = min(max(requested ?? agent.terminalContextLines, 1), 400)
        let snapshot = session.eventLog.recentText(maxLines: lines)
        record(
            .toolCall,
            "read_terminal (\(lines) lines)",
            toolName: AgentToolSpec.readTerminal.name,
            toolArguments: rawArguments,
            disposition: .unguarded,
            toolDurationMS: Self.elapsedMS(since: startedAt)
        )
        return AgentTurnLogic.frameTerminalResult(snapshot)
    }

    // The framing, echo-detection, and settle-window logic below lives in FinAgentCore's
    // `AgentTurnLogic` (shared with the headless daemon); these are thin forwards kept so
    // existing call sites and tests read the same as before the extraction.
    static let defaultAwaitOutputSeconds = AgentTurnLogic.defaultAwaitOutputSeconds

    /// Internal so the beat-budget refresh signal — stamped only when bytes are
    /// actually delivered, never on a denied or disconnected attempt — is testable
    /// without a model in the loop.
    func executeSendInput(
        input: String,
        awaitOutputSeconds: Int,
        rawArguments: String
    ) async -> String {
        let toolName = AgentToolSpec.sendInput.name
        let askedAt = Date()
        let decision = await authorize(input: input, rawArguments: rawArguments)
        // Only counts when a human was actually asked; auto-executed calls wait on no one.
        let approvalWaitMS = decision.disposition == .autoExecuted
            ? nil
            : Self.elapsedMS(since: askedAt)

        if let denial = decision.denial {
            record(
                .toolCall, input,
                toolName: toolName, toolArguments: rawArguments,
                disposition: decision.disposition,
                approvalWaitMS: approvalWaitMS,
                isFailure: true
            )
            record(.approval, "Declined: \(Self.summarize(input))",
                   toolName: toolName, disposition: decision.disposition,
                   approvalWaitMS: approvalWaitMS)
            return denial
        }

        if Task.isCancelled { return "Cancelled before sending." }

        // A disconnected session's write path silently drops bytes (its stdin writer is
        // gone), so sending would confirm delivery of something that never arrived —
        // and then wait the full timeout for output that provably cannot come.
        guard session.state == .connected else {
            let message = "Error: the terminal session is not connected (\(String(describing: session.state))). "
                + "Nothing was sent. Tell the user the session needs to reconnect before commands can run."
            record(.error, message, toolName: toolName,
                   toolArguments: rawArguments, isFailure: true)
            return message
        }

        let baselineEventID = session.eventLog.events.last?.id
        let executedAt = Date()
        // The "real work" signal that refreshes a watchdog-armed episode's beat
        // budget — stamped here, past the authorization, cancellation, and
        // connected-session guards, at the point where bytes are actually written
        // to a live channel. An attempted-but-undelivered send (denied, cancelled,
        // or into a disconnected session that silently drops stdin) must not count
        // as progress, or a dead session's loop would refresh its own budget
        // forever.
        beatUsedSendInput = true
        // The Return is sent as its own write, a beat after the text: a \r riding in the
        // same stdin burst as a multi-character chunk is treated by TUI input libraries
        // (Claude Code's included) as part of a paste — inserted, not submitted. A live
        // wrapper test showed exactly that: two commands merged un-submitted in the inner
        // agent's input box. The pause makes the \r arrive as a lone keypress event.
        session.sendAgentInput(Self.typedBody(input))
        try? await Task.sleep(for: .milliseconds(250))
        session.sendAgentInput("\r")
        let outcome = await awaitOutput(
            seconds: awaitOutputSeconds,
            after: baselineEventID,
            sentAt: executedAt,
            input: input
        )

        record(
            .toolCall, input,
            toolName: toolName, toolArguments: rawArguments,
            disposition: decision.disposition,
            toolDurationMS: Self.elapsedMS(since: executedAt),
            approvalWaitMS: approvalWaitMS
        )
        if decision.disposition == .approved {
            record(.approval, "Approved: \(Self.summarize(input))",
                   toolName: toolName, disposition: .approved,
                   approvalWaitMS: approvalWaitMS)
        }
        return AgentTurnLogic.frameSendInputResult(
            Self.summarize(input),
            response: outcome.response,
            connectionDropped: outcome.connectionDropped
        )
    }

    /// Waits for the terminal to answer what was just sent, returning whatever it printed.
    ///
    /// This is what lets the agent converse with something slow on the other side — a
    /// shell command that takes a while, or another agent (a Claude Code session, say)
    /// that thinks for tens of seconds before replying. Returning early once output goes
    /// quiet means a generous timeout costs nothing when the response is fast; the
    /// timeout itself is chosen by the model per call, because only it knows whether it
    /// just typed `ls` or asked another agent a question.
    private func awaitOutput(
        seconds: Int,
        after baselineEventID: UUID?,
        sentAt: Date,
        input: String
    ) async -> (response: String, connectionDropped: Bool) {
        // "0 means default" on both backends; the endpoint path lands here with whatever
        // integer the model produced, so the convention has to be enforced centrally.
        let requested = seconds <= 0 ? Self.defaultAwaitOutputSeconds : seconds
        let budget = min(requested, AgentTurnLogic.maxAwaitOutputSeconds)
        let deadline = sentAt.addingTimeInterval(TimeInterval(budget))
        var connectionDropped = false

        while Date() < deadline, !Task.isCancelled {
            // A drop mid-await means anything that arrives next is reconnect noise (the
            // reattach redraw of pre-command scrollback), not the command's response —
            // and on a session that stays down, nothing arrives at all. Either way,
            // waiting longer only degrades the result.
            guard session.state == .connected else {
                connectionDropped = true
                break
            }
            if let lastActivity = session.eventLog.lastOutputActivity,
               lastActivity > sentAt {
                let quiet = Date().timeIntervalSince(lastActivity)
                if quiet >= AgentTurnLogic.echoOnlySettleWindow { break }
                if quiet >= AgentTurnLogic.outputSettleWindow,
                   Self.containsResponse(
                       session.eventLog.outputText(after: baselineEventID, orRecordedAfter: sentAt),
                       beyond: input
                   ) {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (
            session.eventLog.outputText(after: baselineEventID, orRecordedAfter: sentAt),
            connectionDropped
        )
    }

    /// Forward to the shared implementation in FinAgentCore; see `AgentTurnLogic` for the
    /// full reasoning behind the echo heuristic.
    nonisolated static func containsResponse(_ outputText: String, beyond input: String) -> Bool {
        AgentTurnLogic.containsResponse(outputText, beyond: input)
    }

    /// Forward to the shared implementation in FinAgentCore; see `AgentTurnLogic` for why
    /// the tail is normalized to a single `\r`.
    nonisolated static func submittable(_ input: String) -> String {
        AgentTurnLogic.submittable(input)
    }

    /// Forward to the shared implementation in FinAgentCore; see `AgentTurnLogic` for why
    /// the typed body is decoupled from the separately-sent Return.
    nonisolated static func typedBody(_ input: String) -> String {
        AgentTurnLogic.typedBody(input)
    }

    private static func elapsedMS(since start: Date) -> Int {
        AgentTurnLogic.elapsedMS(since: start)
    }

    private static func summarize(_ input: String) -> String {
        AgentTurnLogic.summarize(input)
    }

    /// Decides whether a `send_input` call may proceed, prompting the user when the mode
    /// or the command's shape calls for it. `denial` is non-nil exactly when it must not.
    private func authorize(
        input: String,
        rawArguments: String
    ) async -> (disposition: AgentToolDisposition, denial: String?) {
        let destructive = DestructiveCommandHeuristic.isDestructive(input)
        guard mode == .manual || destructive else {
            return (.autoExecuted, nil)
        }

        let call = AgentToolCall(
            id: "pending_\(UUID().uuidString.prefix(8))",
            name: AgentToolSpec.sendInput.name,
            arguments: rawArguments
        )
        let reason: ApprovalReason = destructive ? .destructiveCommand : .manualMode
        // Unattended monitoring has no one watching the approval bar; without a nudge
        // the heartbeat parks here silently until someone happens to look.
        if isMonitoring {
            AgentNotificationService.shared.notifyInputRequested(
                agentName: agent.name,
                question: "Approval needed: \(Self.summarize(input))",
                agentID: agent.id
            )
        }
        let approved = await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            state = .awaitingApproval(call: call, reason: reason)
        }
        state = .thinking

        if approved { return (.approved, nil) }
        let denial = destructive
            ? "The user declined to run that command because it looked destructive. Do not retry it; propose a safer approach instead."
            : "The user declined to send that input. Ask what they'd like to do instead."
        return (.denied, denial)
    }
}
