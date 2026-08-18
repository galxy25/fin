import SwiftUI

struct TerminalScreen: View {
    let server: Server
    @EnvironmentObject private var sessionManager: SessionManager

    @AppStorage("themeBackgroundHex") private var backgroundHex = AppTheme.default.backgroundHex
    @AppStorage("themeForegroundHex") private var foregroundHex = AppTheme.default.foregroundHex

    private var theme: AppTheme {
        AppTheme(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
    }

    var body: some View {
        // Read-only lookup: an existing session renders instantly on this very first
        // evaluation with no side effect. Only the "never connected this launch" case
        // (cold launch, or a brand-new server) falls to the placeholder branch, whose
        // `.task` — not `body` itself — is what's allowed to mutate `sessionManager`.
        if let session = sessionManager.sessions[server.id] {
            VStack(spacing: 0) {
                ControlStripView(server: server, session: session)
                TerminalViewRepresentable(session: session, theme: theme)
            }
            .background(theme.backgroundColor)
        } else {
            theme.backgroundColor
                .ignoresSafeArea()
                .task { sessionManager.open(server) }
        }
    }
}
