import SwiftUI
import SwiftData
import Combine
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    private enum Route {
        case terminal(Server)
        case markdown(MarkdownDocument)
        case home
    }

    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query private var markdownDocuments: [MarkdownDocument]
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("lastActiveServerTouchedAt") private var lastActiveServerTouchedAt: Double = 0
    @AppStorage("lastActiveMarkdownDocumentID") private var lastActiveMarkdownDocumentID: String = ""
    @AppStorage("lastActiveMarkdownTouchedAt") private var lastActiveMarkdownTouchedAt: Double = 0

    /// A notification tap whose conversation lives on ANOTHER device opens the
    /// read-only remote conversation instead of a local console (which would show
    /// this device's own transcript — a runtime the tap's conversation doesn't
    /// live in, empty in the worst case).
    @State private var remoteAgentTarget: Agent?

    var body: some View {
        Group {
            if isUnlocked {
                switch route {
                case .terminal(let server):
                    TerminalScreen(server: server)
                case .markdown(let document):
                    NavigationStack {
                        MarkdownReaderView(document: document, isRoot: true)
                    }
                case .home:
                    HomeView()
                }
            } else {
                PaywallView()
            }
        }
        .onChange(of: sessionManager.pendingAgentOpen) { _, _ in openPendingRemoteAgentIfNeeded() }
        .onAppear { openPendingRemoteAgentIfNeeded() }
        // A tap queued while the paywall was up gets claimed the moment the
        // entitlement unlocks (see the isUnlocked guard in the claim itself).
        .onChange(of: isUnlocked) { _, _ in openPendingRemoteAgentIfNeeded() }
        .sheet(item: $remoteAgentTarget) { agent in
            // Same entitlement gate as the root switch: the target can only be
            // set while unlocked, but a lapse mid-presentation must not leave a
            // working remote console (compose bar included) over the paywall.
            if isUnlocked {
                AgentRemoteConsoleView(agent: agent)
            } else {
                PaywallView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            sessionManager.isAppActive = newPhase == .active
            if newPhase == .active {
                sessionManager.recordLifecycleEvent("[app] foregrounded")
                sessionManager.resumeActiveSessionIfNeeded(servers: servers)
                // An armed monitor must come back even when the user reopens to the
                // reader or home screen and never touches the terminal screen (whose
                // runtime creation would otherwise be what re-arms it).
                sessionManager.resumeArmedAgentMonitor(servers: servers, agents: agents)
                // Foregrounding is user attention: un-pause any auto-recovery that
                // gave up after repeated failures, then check the agents instantly
                // rather than waiting out the watchdog's next 5s beat.
                sessionManager.resetAgentRecoveryBackoff()
                sessionManager.watchdogTickNow()
                // Foregrounding is also when conversations that ended in the
                // background cross the quiet gap into "finished" — sweep them, and
                // nudge any queued feedback whose backoff has elapsed.
                FeedbackService.shared.sweepTrajectories(context: modelContext)
            } else if newPhase == .background {
                sessionManager.recordLifecycleEvent("[app] backgrounded")
            }
        }
        .task {
            // The scene is usually already .active by first render, so onChange alone
            // would leave the watchdog stopped until the first background/foreground
            // round-trip.
            sessionManager.isAppActive = scenePhase == .active
            // Feedback give-up/discard lines join the agent trail (and iCloud
            // mirror) through the same audit channel other services use.
            FeedbackService.shared.audit = { [weak sessionManager] line in
                sessionManager?.recordLifecycleEvent(line)
            }
            FeedbackService.shared.sweepTrajectories(context: modelContext)
            #if DEBUG
            await autoOpenSessionIfNeeded()
            #endif
        }
        #if os(macOS)
        // Unlike iOS backgrounding, macOS doesn't reliably transition scenePhase away from
        // .active when just the display sleeps — the socket can die silently underneath the
        // app with no scenePhase change to react to. Wake is the one macOS-native signal we
        // do get for "the user is back and this session might be stale."
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            sessionManager.forceReconnectActiveSessionAfterWake(servers: servers)
        }
        #endif
    }

    /// Release builds gate on entitlements alone. The Debug-only auto-session mode
    /// also bypasses the paywall — a scripted install must land in a live terminal
    /// without StoreKit — and that bypass must not exist in Release, so it is
    /// compile-time conditional, not a runtime flag.
    private var isUnlocked: Bool {
        #if DEBUG
        if Self.autoSessionEnabled { return true }
        #endif
        return entitlementStore.isUnlocked
    }

    #if DEBUG
    /// FinAutoSession == "1" (stamped from the FIN_AUTO_SESSION build setting):
    /// auto-connect at launch so a freshly-installed Debug build reaches the
    /// terminal/agent UI with zero taps.
    private static var autoSessionEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FinAutoSession") as? String == "1"
    }

    /// Connects the most recently used server — or the sole one — exactly as
    /// tapping it would (`SessionManager.open`), which also routes here to the
    /// terminal screen. Waits briefly for CloudKit to deliver servers on a fresh
    /// install — re-fetching from the ModelContext each pass, because the task
    /// closure's captured `@Query` snapshot never updates while it sleeps.
    private func autoOpenSessionIfNeeded() async {
        guard Self.autoSessionEnabled, sessionManager.sessions.isEmpty else { return }
        func liveServers() -> [Server] {
            let descriptor = FetchDescriptor<Server>(sortBy: [SortDescriptor(\.createdAt)])
            return (try? modelContext.fetch(descriptor)) ?? []
        }
        var current = liveServers()
        for _ in 0..<20 where current.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            current = liveServers()
        }
        let target = sessionManager.activeServerID.flatMap { id in
            current.first { $0.id == id }
        } ?? (current.count == 1 ? current.first : nil)
        guard let target else { return }
        sessionManager.open(target)
    }
    #endif

    /// The remote half of notification-tap routing: claims the pending open only
    /// when `SessionManager.notificationTapRoute` says the conversation is
    /// provably elsewhere (the tap's origin device isn't this one — or, for old
    /// origin-less pushes, the residence fallback says so) — the console half
    /// (`ControlStripView.openPendingAgentIfNeeded`) claims exactly the
    /// `.localConsole` case of the same fork, so the two consumers never race
    /// for the same tap, and locally-originated taps keep their
    /// pre-cross-device behavior (open or stay queued for the console).
    /// Gated on `isUnlocked` like everything else: a lapsed entitlement must not
    /// reach the mirrored transcript or its compose bar over the paywall.
    private func openPendingRemoteAgentIfNeeded() {
        guard isUnlocked,
              let pending = sessionManager.pendingAgentOpen,
              let agent = agents.first(where: { $0.id == pending.agentID }),
              // Cloud-hosted agents are remote UNCONDITIONALLY — the console
              // half declines them outright, so the fork's residence fallback
              // (which could briefly say local off a stranded armed flag mid
              // hosting-switch) must not strand the tap unclaimed here.
              !agent.hostsLocally
                  || sessionManager.notificationTapRoute(
                      for: agent, originDeviceID8: pending.originDeviceID8
                  ) == .remoteConsole else { return }
        sessionManager.pendingAgentOpen = nil
        remoteAgentTarget = agent
    }

    private var route: Route {
        let terminalTarget = sessionManager.activeServerID.flatMap { id in
            servers.first(where: { $0.id == id })
        }
        let markdownTarget = lastActiveMarkdownDocumentID.isEmpty
            ? nil
            : markdownDocuments.first(where: { $0.id.uuidString == lastActiveMarkdownDocumentID })

        switch (terminalTarget, markdownTarget) {
        case (nil, nil):
            return .home
        case (let server?, nil):
            return .terminal(server)
        case (nil, let document?):
            return .markdown(document)
        case (let server?, let document?):
            return lastActiveServerTouchedAt >= lastActiveMarkdownTouchedAt
                ? .terminal(server)
                : .markdown(document)
        }
    }
}
