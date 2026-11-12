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
        /// A Remote Browser tab (iPhone/iPad; Mac and Vision Pro use a window).
        case browser(SessionManager.BrowserTab)
        case home
    }

    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]
    @Query private var markdownDocuments: [MarkdownDocument]
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS) || os(visionOS)
    @Environment(\.openWindow) private var openWindow
    // Multi-window platforms resume straight to HOME, not straight into the
    // file — the file reopens in its own window instead (see
    // MarkdownReaderWindowView), matching how opening one from the Files tab
    // already works. Guards against re-firing `openWindow` on every re-render
    // while `route` stays `.markdown` (e.g. an unrelated `agents`/`servers`
    // change).
    @State private var hasOpenedResumedMarkdownWindow = false
    #endif

    @AppStorage("lastActiveServerTouchedAt") private var lastActiveServerTouchedAt: Double = 0
    @AppStorage("lastActiveMarkdownDocumentID") private var lastActiveMarkdownDocumentID: String = ""
    @AppStorage("lastActiveMarkdownTouchedAt") private var lastActiveMarkdownTouchedAt: Double = 0

    /// A notification tap whose conversation lives on ANOTHER device opens the
    /// read-only remote conversation instead of a local console (which would show
    /// this device's own transcript — a runtime the tap's conversation doesn't
    /// live in, empty in the worst case).
    @State private var remoteAgentTarget: Agent?
    /// The thread a notification tap named, applied to the console it opens.
    @State private var remoteAgentThreadID: String?

    var body: some View {
        VStack(spacing: 0) {
            // Above the route switch, because it must stay on screen on the
            // home and markdown routes too — tabs can be open while the user
            // is picking a server or reading a file.
            TerminalTabBarView()
            routedContent
        }
        // Tells FinCommands that THIS scene is the one holding terminal tabs, so ⌘W
        // closes a tab here while still closing the window over the Agent Hub or a
        // Markdown reader. See TerminalTabsSceneKey for why it has to be a focused
        // scene value rather than a check inside the command's action.
        .focusedSceneValue(\.hostsTerminalTabs, true)
        .onAppear { ScreenshotFixtures.sizeWindowForCapture(width: 1440, height: 900) }
        // The one server picker: ⌘T and the control strip's server button both set
        // this flag, and it lives on RootView rather than the control strip because
        // ⌘T must work on the home and markdown routes, where no strip exists.
        .sheet(isPresented: $sessionManager.isServerPickerPresented) {
            HomeView(isSheet: true)
        }
        .onChange(of: sessionManager.isServerPickerPresented) { _, isPresented in
            if !isPresented { focusActiveTerminal() }
        }
        .onChange(of: sessionManager.activeServerID) { _, _ in focusActiveTerminal() }
        .onChange(of: sessionManager.pendingAgentOpen) { _, _ in openPendingRemoteAgentIfNeeded() }
        // Opening a file is an explicit gesture away from the conversation.
        .onChange(of: lastActiveMarkdownTouchedAt) { _, _ in sessionManager.showsXanadu = false }
        // A notification / Live Activity tap, a fin:// link or Siri asked for the
        // conversation (XanaduNavigator): Xanadu comes forward even over a live
        // terminal (LaunchLanding.Context.externalOpen). `$request` replays its
        // current value on subscribe — that is what catches a cold-launch tap —
        // so a request already acted on (by another window) is not replayed.
        .onReceive(XanaduNavigator.shared.$request) { request in
            guard let request, sessionManager.handledXanaduRequestID != request.id else { return }
            sessionManager.handledXanaduRequestID = request.id
            sessionManager.showXanadu()
            sessionManager.isServerPickerPresented = false
            remoteAgentTarget = nil
        }
        .onAppear { openPendingRemoteAgentIfNeeded() }
        // A cold launch from a killed state (the common case for a notification
        // tap) can reach this view before CloudKit's initial import has delivered
        // the tapped agent's own record — the claim's `agents.first(where:)`
        // guard fails silently that first pass, and nothing retried it, so the
        // tap stranded the user on the home screen once the agent finally synced
        // in. Retrying on every `agents` change closes that race.
        .onChange(of: agents) { _, _ in openPendingRemoteAgentIfNeeded() }
        .sheet(item: $remoteAgentTarget) { agent in
            AgentRemoteConsoleView(agent: agent, initialThreadID: remoteAgentThreadID)
        }
        .onChange(of: scenePhase) { _, newPhase in
            sessionManager.isAppActive = newPhase == .active
            if newPhase == .active {
                sessionManager.recordLifecycleEvent("[app] foregrounded")
                // Restored tabs are just ids until something resolves them, and a
                // server can be deleted on another device while this one is closed —
                // so the list is reconciled against the real rows here, where the
                // query lives, before anything tries to route to one.
                sessionManager.pruneDormantTabs(existingServerIDs: Set(servers.map(\.id)))
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
                #if os(iOS)
                // The attention tile (design §3.4): sample presence while in
                // front; the Live Activity itself outlives the foreground.
                if #available(iOS 16.2, *) { FinLiveActivityController.shared.appDidBecomeActive() }
                #endif
            } else if newPhase == .background {
                sessionManager.recordLifecycleEvent("[app] backgrounded")
                #if os(iOS)
                if #available(iOS 16.2, *) { FinLiveActivityController.shared.appDidEnterBackground() }
                #endif
            }
        }
        .task {
            // The scene is usually already .active by first render, so onChange alone
            // would leave the watchdog stopped until the first background/foreground
            // round-trip.
            sessionManager.isAppActive = scenePhase == .active
            #if os(iOS)
            if scenePhase == .active, #available(iOS 16.2, *) {
                FinLiveActivityController.shared.appDidBecomeActive()
            }
            #endif
            // Feedback give-up/discard lines join the agent trail (and iCloud
            // mirror) through the same audit channel other services use.
            FeedbackService.shared.audit = { [weak sessionManager] line in
                sessionManager?.recordLifecycleEvent(line)
            }
            // CloudKit sync failures (and recoveries) join the same trail — without
            // this, a sync error was visible only on the iCloud Sync screen, in the
            // moment, and nowhere else.
            CloudSyncActivityMonitor.shared.audit = { [weak sessionManager] line in
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

    @ViewBuilder
    private var routedContent: some View {
        switch route {
        case .terminal(let server):
            TerminalScreen(server: server)
        case .markdown(let document):
            #if os(macOS) || os(visionOS)
            // The file itself opens in its own window (see
            // MarkdownReaderWindowView) rather than taking over the whole
            // app view — the root content stays HomeView.
            HomeView()
                .task(id: document.id) {
                    guard !hasOpenedResumedMarkdownWindow else { return }
                    hasOpenedResumedMarkdownWindow = true
                    openWindow(id: FinScene.markdownReader, value: document.id)
                }
            #else
            NavigationStack {
                MarkdownReaderView(document: document, isRoot: true)
            }
            #endif
        case .browser(let tab):
            RemoteBrowserView(tab: tab) { sessionManager.closeBrowserTab(tab.id) }
                // One view identity per tab, so switching between two tabs gives each
                // its own @StateObject rather than reusing the first.
                .id(tab.id)
        case .home:
            HomeView()
        }
    }

    /// Hands first responder back to the focused terminal after the picker closes or
    /// the tab changes. Deferred a turn: the newly-focused session's view is only
    /// reparented into the window once this render lands, and `makeFirstResponder`
    /// on a view with no window is a silent no-op.
    private func focusActiveTerminal() {
        guard let serverID = sessionManager.activeServerID,
              let session = sessionManager.sessions[serverID] else { return }
        Task { @MainActor in session.focusTerminalView() }
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
    private func openPendingRemoteAgentIfNeeded() {
        guard let pending = sessionManager.pendingAgentOpen,
              let agent = agents.first(where: { $0.id == pending.agentID }),
              // Cloud-hosted agents are remote UNCONDITIONALLY — the console
              // half declines them outright, so the fork's residence fallback
              // (which could briefly say local off a stranded armed flag mid
              // hosting-switch) must not strand the tap unclaimed here.
              pending.forcesRemote
                  || !agent.hostsLocally
                  || sessionManager.notificationTapRoute(
                      for: agent, originDeviceID8: pending.originDeviceID8
                  ) == .remoteConsole else { return }
        sessionManager.pendingAgentOpen = nil
        remoteAgentThreadID = pending.threadID
        remoteAgentTarget = agent
    }

    private var route: Route {
        // docs/XANADU.md decision 1: Xanadu when asked for (a tap, Siri, ⌘0,
        // the strip's agent button) and at a launch with no open tab
        // (LaunchLanding); otherwise the last open terminal. Any explicit
        // terminal / browser / file gesture clears the flag (SessionManager, and
        // the markdown observer above), handing the route to the rules below —
        // and with no tab left those land on HomeView, whose first segment is
        // Xanadu again.
        if sessionManager.showsXanadu { return .home }
        // A browser tab in front wins: it only becomes active by an explicit tap, and
        // every terminal-tab gesture clears it (SessionManager.activeBrowserTabID).
        if let tab = sessionManager.activeBrowserTab { return .browser(tab) }
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
