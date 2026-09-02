import SwiftUI
import SwiftData

struct TerminalScreen: View {
    let server: Server
    @EnvironmentObject private var sessionManager: SessionManager
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @AppStorage("themeBackgroundHex") private var backgroundHex = AppTheme.default.backgroundHex
    @AppStorage("themeForegroundHex") private var foregroundHex = AppTheme.default.foregroundHex
    /// Persisted so the panel is still open next launch if that's how it was left.
    @AppStorage("agentPanelVisible") private var isAgentPanelVisible = false

    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var theme: AppTheme {
        AppTheme(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
    }

    /// Wide layouts get the console beside the terminal; compact ones get a sheet, since
    /// splitting an iPhone width would leave neither pane usable.
    private var prefersSidePanel: Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        // Read-only lookup: an existing session renders instantly on this very first
        // evaluation with no side effect. Only the "never connected this launch" case
        // (cold launch, or a brand-new server) falls to the placeholder branch, whose
        // `.task` — not `body` itself — is what's allowed to mutate `sessionManager`.
        Group {
            if let session = sessionManager.sessions[server.id] {
                content(for: session)
            } else {
                theme.backgroundColor
                    .ignoresSafeArea()
                    .task { sessionManager.open(server) }
            }
        }
        #if os(iOS)
        // Scoped to this screen being visible, not to connection state: what the setting
        // promises is "the display won't lock while I'm looking at this session".
        .onAppear { UIApplication.shared.isIdleTimerDisabled = server.keepScreenAwake }
        .onChange(of: server.keepScreenAwake) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    @ViewBuilder
    private func content(for session: TerminalSession) -> some View {
        // flatMap: the factory returns nil for a cloud-hosted agent, whose
        // console is the remote view (opened from the control strip), not a
        // local runtime panel.
        let runtime = agents.first.flatMap {
            sessionManager.agentRuntime(for: session, agent: $0, serverName: server.name)
        }

        VStack(spacing: 0) {
            ControlStripView(
                server: server,
                session: session,
                isAgentPanelVisible: $isAgentPanelVisible,
                prefersSidePanel: prefersSidePanel
            )
            HStack(spacing: 0) {
                TerminalViewRepresentable(session: session, theme: theme)
                if prefersSidePanel, isAgentPanelVisible, let runtime {
                    Divider()
                    AgentConsoleView(runtime: runtime) {
                        isAgentPanelVisible = false
                    }
                    .frame(width: 360)
                    .background(.background)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .background(theme.backgroundColor)
        .animation(.easeInOut(duration: 0.2), value: isAgentPanelVisible)
    }
}
