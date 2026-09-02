import Foundation

@MainActor
final class SessionManager: ObservableObject {
    private static let lastActiveKey = "lastActiveServerID"
    private static let lastActiveTouchedAtKey = "lastActiveServerTouchedAt"

    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    @Published var activeServerID: UUID? {
        didSet {
            // Restoring the persisted value at launch must not stamp "now" as the
            // touched-at time — that would always beat a markdown file's real
            // last-opened time and defeat RootView's actual-recency comparison.
            guard !isRestoringFromStorage else { return }
            if let activeServerID {
                UserDefaults.standard.set(activeServerID.uuidString, forKey: Self.lastActiveKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastActiveTouchedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastActiveKey)
                UserDefaults.standard.removeObject(forKey: Self.lastActiveTouchedAtKey)
            }
        }
    }

    /// One queued notification tap: which agent to open, and — when the payload
    /// carried it — which device the signal originated on. Origin is what the
    /// routing fork trusts first: every device keeps its OWN transcript for the
    /// same synced Agent, so "the conversation" a tap must reach is the one on
    /// the signal's origin device, not wherever a runtime happens to live.
    struct PendingAgentOpen: Equatable {
        let agentID: UUID
        /// `DeviceIdentity.short` of the originating device: the local device for
        /// local banners, the push's `CD_sourceDeviceID8` for cross-device
        /// pushes, nil for pushes minted by pre-v2 subscriptions.
        let originDeviceID8: String?
    }

    /// Set when a notification tap asks for an agent's console; the terminal screen's
    /// control strip consumes the local case, RootView the remote case.
    @Published var pendingAgentOpen: PendingAgentOpen?

    /// Set from RootView's scenePhase observer. Gates the watchdog and the remote
    /// directive channel: both loops run only while the app is active, so no timer
    /// burns in the background — missed ticks coalesce into the immediate
    /// `watchdogTickNow` (and the channel's launch/foreground poll) on foregrounding.
    var isAppActive = false {
        didSet {
            guard oldValue != isAppActive else { return }
            if isAppActive {
                startWatchdog()
                directiveChannel.appDidBecomeActive()
            } else {
                stopWatchdog()
                directiveChannel.appDidResignActive()
            }
        }
    }

    private var isRestoringFromStorage = false
    private var watchdogTask: Task<Void, Never>?
    private var watchdogTickNowTask: Task<Void, Never>?
    /// One agent runtime per server, so a conversation survives closing and reopening the
    /// console. Owned here rather than by `TerminalSession` to keep the session focused on
    /// SSH transport, and to keep the runtime's strong reference to its session
    /// unidirectional (no ownership cycle).
    private var agentRuntimes: [UUID: AgentRuntime] = [:]

    var resolveCredentials: (Server) -> ServerCredentials? = { _ in nil }
    var onCapturedClipping: (String) -> Void = { _ in }
    var onAgentLog: (AgentLogRecord) -> Void = { _ in }
    /// Supplies a restored conversation for a freshly-created runtime.
    var loadAgentHistory: (UUID) -> [AgentMessage] = { _ in [] }
    /// Long-term memory closures, injected like `onAgentLog` to keep runtimes SwiftData-free.
    var memoryAccess: AgentMemoryAccess = .noop
    /// Agents whose trails carry app-lifecycle audit lines — those with the iCloud
    /// mirror enabled, fetched per event so the toggle applies immediately.
    /// Injected like `onAgentLog` to keep this class SwiftData-free.
    var lifecycleAuditAgents: () -> [(id: UUID, name: String)] = { [] }

    /// The remote-supervision poller. Cheap when disabled: creation starts no
    /// timers, and activation is a bool check away from a no-op.
    let directiveChannel = AgentDirectiveChannel()

    /// Applies synced cross-device relay messages to runtimes hosted here.
    /// Created by `FinApp` (it owns the ModelContext this class stays free of) and
    /// poked from the same moments the directive channel is: turn finish and the
    /// explicit watchdog tick — its own CloudKit-import observation covers the rest.
    var relayApplier: AgentRelayApplier?

    /// Whether an agent's live runtime is hosted on this device right now — the
    /// notification-tap router's fork between the normal console and the
    /// read-only remote conversation view.
    func hasLiveRuntime(agentID: UUID) -> Bool {
        agentRuntimes.values.contains { $0.agent.id == agentID }
    }

    /// Where a notification tap (or queued `pendingAgentOpen`) routes.
    enum AgentNotificationRoute {
        /// Open — or keep queued until it can open — the local console; the
        /// pre-cross-device behavior, and the default for every ambiguous case.
        case localConsole
        /// Present the read-only remote conversation view.
        case remoteConsole
    }

    /// The single routing fork shared by `RootView` (which claims the remote
    /// case) and `ControlStripView` (which claims the local case) — one pure
    /// function so the two consumers can never both claim a tap.
    ///
    /// The signal's ORIGIN device is authoritative when the payload carried it:
    /// each device keeps its own transcript for the same synced Agent, so a
    /// known origin != this device routes remote UNCONDITIONALLY — a live local
    /// runtime for the same agent is a DIFFERENT conversation. (Residence
    /// routing was the live UX failure: the receiving iPhone auto-resumes its
    /// terminal session at launch, so it always had a live runtime and the tap
    /// opened its own empty local conversation instead of the origin device's
    /// conversation where the question actually lives.) A known origin == this
    /// device routes local unconditionally, by the same reasoning.
    ///
    /// Origin unknown (a pre-v2 push without `CD_sourceDeviceID8`): fall back
    /// to the residence rule. A live local runtime wins the tap; without one,
    /// the only local case left is a monitor armed on THIS device whose runtime
    /// a cold launch hasn't recreated yet — the tap stays queued for the
    /// console rather than misrouting to an empty remote view of this same
    /// device. Everything else routes remote: the mirror view plus the relay
    /// compose work whether or not the hosting device has a monitor armed.
    nonisolated static func notificationTapRoute(
        originDeviceID8: String?,
        localDeviceID8: String,
        monitoringArmed: Bool,
        monitoringDeviceID: String,
        localDeviceID: String,
        hasLiveRuntimeLocally: Bool
    ) -> AgentNotificationRoute {
        if let originDeviceID8 {
            return originDeviceID8 == localDeviceID8 ? .localConsole : .remoteConsole
        }
        if hasLiveRuntimeLocally { return .localConsole }
        if monitoringArmed, monitoringDeviceID == localDeviceID { return .localConsole }
        return .remoteConsole
    }

    /// `notificationTapRoute` against the live state for one agent and the
    /// pending tap's origin.
    func notificationTapRoute(for agent: Agent, originDeviceID8: String?) -> AgentNotificationRoute {
        Self.notificationTapRoute(
            originDeviceID8: originDeviceID8,
            localDeviceID8: DeviceIdentity.short,
            monitoringArmed: agent.monitoringArmed,
            monitoringDeviceID: agent.monitoringDeviceID,
            localDeviceID: DeviceIdentity.id,
            hasLiveRuntimeLocally: hasLiveRuntime(agentID: agent.id)
        )
    }

    /// The relay applier's view of the live runtimes, same construction as the
    /// directive channel's targets (active server first is irrelevant here — relay
    /// messages address an agent by id, not a wildcard).
    func relayTargets() -> [AgentRelayApplier.Target] {
        agentRuntimes.map { serverID, runtime in
            AgentRelayApplier.Target(
                runtime: runtime,
                sessionConnected: sessions[serverID]?.state == .connected
            )
        }
    }

    /// One run groups this launch's lifecycle lines, ordered by a shared sequence.
    private let lifecycleRunID = UUID()
    private var lifecycleSequence = 0

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.lastActiveKey),
           let uuid = UUID(uuidString: stored) {
            isRestoringFromStorage = true
            activeServerID = uuid
            isRestoringFromStorage = false
        }
        directiveChannel.liveTargets = { [weak self] in
            guard let self else { return [] }
            // Active server's runtime first, so a "*" directive lands where the
            // user is looking; then stable order by server name, then server id —
            // fully deterministic, never dictionary order, so a named-agent
            // directive against two servers always picks the same session.
            return self.agentRuntimes
                .sorted { lhs, rhs in
                    let lhsActive = lhs.key == self.activeServerID
                    let rhsActive = rhs.key == self.activeServerID
                    if lhsActive != rhsActive { return lhsActive }
                    if lhs.value.serverName != rhs.value.serverName {
                        return lhs.value.serverName < rhs.value.serverName
                    }
                    return lhs.key.uuidString < rhs.key.uuidString
                }
                .map { serverID, runtime in
                    AgentDirectiveChannel.Target(
                        runtime: runtime,
                        sessionConnected: self.sessions[serverID]?.state == .connected
                    )
                }
        }
        directiveChannel.audit = { [weak self] text in
            self?.recordLifecycleEvent(text)
        }
    }

    /// Lifecycle lines repeat under churn — scenePhase flapping through
    /// inactive→active (control center, permission alerts), reconnect storms —
    /// and each line is a SwiftData insert per mirror-enabled agent. An identical
    /// line inside the window is dropped; [app] and [session] alike.
    static let lifecycleDedupeWindow: TimeInterval = 30
    private var lastLifecycleEventAt: [String: Date] = [:]

    /// Broadcasts one audit line to every mirror-enabled agent's trail, so app and
    /// session state transitions are remotely debuggable through the existing
    /// iCloud log mirror. All builds, not just Debug.
    func recordLifecycleEvent(_ text: String, now: Date = Date()) {
        if let last = lastLifecycleEventAt[text],
           now.timeIntervalSince(last) < Self.lifecycleDedupeWindow {
            return
        }
        lastLifecycleEventAt[text] = now
        for agent in lifecycleAuditAgents() {
            lifecycleSequence += 1
            onAgentLog(AgentLogRecord(
                agentID: agent.id,
                agentName: agent.name,
                serverName: "",
                runID: lifecycleRunID,
                sequence: lifecycleSequence,
                kind: .notice,
                text: text
            ))
        }
    }

    func session(for server: Server) -> TerminalSession {
        if let existing = sessions[server.id] {
            return existing
        }
        let session = TerminalSession(serverID: server.id)
        session.onCapturedClipping = { [weak self] text in
            self?.onCapturedClipping(text)
        }
        session.onConnectionAudit = { [weak self] text in
            self?.recordLifecycleEvent(text)
        }
        sessions[server.id] = session
        return session
    }

    @discardableResult
    func open(_ server: Server) -> TerminalSession {
        activeServerID = server.id
        let session = session(for: server)
        guard session.state == .disconnected else { return session }
        guard let credentials = resolveCredentials(server) else {
            session.reportMissingCredentials()
            return session
        }
        session.connect(server: server, credentials: credentials)
        return session
    }

    func resumeActiveSessionIfNeeded(servers: [Server]) {
        reconnectActiveSessionIfNeeded(servers: servers, trustCachedConnectionState: true)
    }

    /// Called after a macOS display/system wake. Citadel has no SSH-level keepalive, so a
    /// session's cached `isConnected` flag can still read true long after the underlying
    /// socket silently died while the Mac was asleep — this bypasses that stale flag and
    /// forces a fresh reconnect for any session the UI still believes is `.connected`.
    func forceReconnectActiveSessionAfterWake(servers: [Server]) {
        reconnectActiveSessionIfNeeded(servers: servers, trustCachedConnectionState: false)
    }

    private func reconnectActiveSessionIfNeeded(servers: [Server], trustCachedConnectionState: Bool) {
        guard let activeServerID, let session = sessions[activeServerID] else { return }
        guard session.state == .connected || session.state == .disconnected else { return }
        if trustCachedConnectionState {
            guard !session.isConnected else { return }
        }
        guard let server = servers.first(where: { $0.id == activeServerID }) else { return }
        guard let credentials = resolveCredentials(server) else { return }
        session.markNeedsReconnect()
        session.connect(server: server, credentials: credentials)
    }

    /// Re-arms a persisted monitor on foregrounding without requiring the user to
    /// navigate into the terminal screen: creating the runtime is enough, because its
    /// init auto-resumes an armed heartbeat once the session connects. Scoped to the
    /// active server only — an armed monitor must never spin up SSH to a server the
    /// user isn't using — and to the first agent, mirroring the console's own binding
    /// in `TerminalScreen`.
    func resumeArmedAgentMonitor(servers: [Server], agents: [Agent]) {
        guard let activeServerID,
              let server = servers.first(where: { $0.id == activeServerID }),
              let agent = agents.first,
              // A cloud-hosted agent never resumes here even if an armed flag
              // strands from before the hosting switch — the harness owns it.
              agent.hostsLocally
        else { return }
        // A watchdog-armed episode runs on the runtime-local 60s episode interval
        // rather than the synced config (which the arm never writes); the pre-gate
        // must resolve the same effective interval or an unconfigured agent's
        // armed episode could never resume.
        let effectiveHeartbeat = agent.heartbeatSeconds > 0
            ? agent.heartbeatSeconds
            : (MonitorSuppressionStore.shared.armSource(for: agent.id) == .watchdog
                ? AgentRuntime.watchdogEpisodeHeartbeatSeconds : 0)
        // The armed flag syncs across devices, but resumption is exclusive to
        // the device that armed it and the server it was watching — a foreign
        // or mistargeted resume would type into the wrong terminal.
        guard AgentRuntime.shouldAutoResume(
            monitoringArmed: agent.monitoringArmed,
            mode: agent.defaultMode,
            heartbeatSeconds: effectiveHeartbeat,
            deviceMatches: agent.monitoringDeviceID == DeviceIdentity.id,
            serverMatches: agent.monitoringServerID == activeServerID
        ) else { return }
        let session = session(for: server)
        // A relaunch that lands on the reader or home screen never opens the terminal,
        // so the active session may not exist yet; connect it here the same way
        // `open` would, minus re-stamping the active route.
        if session.state == .disconnected, let credentials = resolveCredentials(server) {
            session.connect(server: server, credentials: credentials)
        }
        // An existing runtime whose earlier resume poll expired while the app was
        // suspended gets a fresh one; a freshly-created runtime starts its own.
        agentRuntime(for: session, agent: agent, serverName: server.name)?
            .resumeMonitoringIfArmed()
    }

    /// The runtime for this session, rebuilt if the caller picked a different agent.
    /// Nil for a cloud-hosted agent — refusing HERE is what makes the hosting
    /// switch airtight: with no local runtime, the watchdog pass, relay targets,
    /// and directive targets (all built from `agentRuntimes`) exclude the agent
    /// by construction, and flipping back to local restores everything unchanged.
    func agentRuntime(for session: TerminalSession, agent: Agent, serverName: String) -> AgentRuntime? {
        guard agent.hostsLocally else {
            // A hosting switch while a runtime is live must also retire it, or
            // the pre-switch runtime would keep heartbeating alongside the cloud
            // harness until the next app restart.
            if let replaced = agentRuntimes[session.id], replaced.agent.id == agent.id {
                replaced.suspend()
                replaced.endConversation()
                agentRuntimes[session.id] = nil
            }
            return nil
        }
        if let existing = agentRuntimes[session.id], existing.agent.id == agent.id {
            return existing
        }
        // A replaced runtime must stop acting on this terminal, but via suspend, not
        // cancel: replacement can be triggered by a mere sync-driven change of
        // `agents.first`, and durably disarming there would silently kill a monitor
        // the user left running.
        if let replaced = agentRuntimes[session.id] {
            replaced.suspend()
            replaced.endConversation()
        }
        let runtime = AgentRuntime(
            agent: agent,
            session: session,
            serverName: serverName,
            log: { [weak self] record in self?.onAgentLog(record) },
            memory: memoryAccess,
            history: loadAgentHistory(agent.id)
        )
        runtime.onTurnFinished = { [weak self] in
            self?.directiveChannel.agentTurnFinished()
            // A finished turn is the moment a relay message deferred behind a busy
            // runtime becomes applicable.
            self?.relayApplier?.applyPending()
        }
        agentRuntimes[session.id] = runtime
        return runtime
    }

    // MARK: - Watchdog

    /// The always-on default the agent's own opt-in monitoring loop isn't: a cheap
    /// state check across every live runtime, every 5 seconds while the app is open.
    /// It never makes a model call itself — each runtime's `watchdogTick` only
    /// escalates when a correction is actually needed.
    func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.isAppActive else { return }
                self.runWatchdogPass()
            }
        }
    }

    func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogTickNowTask?.cancel()
        watchdogTickNowTask = nil
    }

    /// An immediate out-of-band pass — foregrounding calls this so a reopened app
    /// checks its agents instantly instead of up to 5 seconds later. Tracked so
    /// backgrounding cancels it exactly like the loop's ticks. Explicit: this is the
    /// one pass that also audits a per-conversation foreground-check line, so the
    /// user can see the watchdog is alive without the 5s loop ever writing.
    func watchdogTickNow() {
        watchdogTickNowTask?.cancel()
        watchdogTickNowTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.runWatchdogPass(isExplicit: true)
            // Foregrounding is also the catch-up moment for relay messages whose
            // import event fired while the app was suspended.
            self.relayApplier?.applyPending()
        }
    }

    /// Foregrounding is user attention: any runtime whose auto-recovery paused after
    /// repeated failures gets a fresh budget before the foreground tick runs.
    func resetAgentRecoveryBackoff() {
        for runtime in agentRuntimes.values {
            runtime.resetRecoveryBackoff()
        }
    }

    private func runWatchdogPass(isExplicit: Bool = false) {
        // The pass is synchronous end to end — ticks only evaluate and dispatch
        // work into each runtime's own tasks, never await it — so one runtime can't
        // starve the rest. The snapshot plus identity check is belt and braces: a
        // runtime replaced since the snapshot must not be resurrected by its tick.
        for (serverID, runtime) in Array(agentRuntimes) {
            guard agentRuntimes[serverID] === runtime else { continue }
            // A tick that escalated a turn owns the runtime's task handle this
            // pass — running the floor too would overwrite it and orphan the turn
            // from cancel(). The floor retries on a later tick.
            if !runtime.watchdogTick(isExplicit: isExplicit) {
                runtime.consolidateIfDailyFloorDue()
            }
        }
    }

    func close(_ serverID: UUID) {
        agentRuntimes[serverID]?.cancel()
        agentRuntimes[serverID]?.endConversation()
        agentRuntimes.removeValue(forKey: serverID)
        sessions[serverID]?.disconnect()
        sessions.removeValue(forKey: serverID)
        if activeServerID == serverID {
            activeServerID = nil
        }
    }
}
