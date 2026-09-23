import SwiftUI
import SwiftData

/// The open terminals, as tabs above whatever the root route is showing. Hidden
/// below two tabs, so a single-session layout — every iPhone layout, in practice —
/// looks exactly as it did before tabs existed.
///
/// It renders chips only, never terminal content: a `TerminalSession` owns one
/// persistent platform view and a view has one superview, so exactly one session
/// may be mounted at a time (the route switch below does that).
struct TerminalTabBarView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        let tabs = openTabs
        if tabs.count + sessionManager.browserTabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { server in
                        if let session = sessionManager.sessions[server.id] {
                            TerminalTabChip(
                                server: server,
                                session: session,
                                isActive: sessionManager.activeBrowserSiteID == nil
                                    && sessionManager.activeServerID == server.id,
                                // A click is the explicit gesture, so it goes through
                                // `open` — which reconnects a dropped tab — where the
                                // keyboard's cycling deliberately only shifts focus.
                                select: { sessionManager.open(server) },
                                close: { sessionManager.close(server.id) }
                            )
                        }
                    }
                    ForEach(sessionManager.browserTabs) { tab in
                        BrowserTabChip(
                            tab: tab,
                            session: tab.session,
                            isActive: sessionManager.activeBrowserSiteID == tab.siteID,
                            select: { sessionManager.selectBrowserTab(tab.siteID) },
                            close: { sessionManager.closeBrowserTab(tab.siteID) }
                        )
                    }
                    Button {
                        sessionManager.isServerPickerPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("New terminal")
                    .accessibilityIdentifier("tabBar_newTerminal")
                }
            }
            // A ScrollView fills whatever it is offered on BOTH axes, so a
            // horizontal one in a VStack would take half the window from the
            // terminal without an explicit height.
            .frame(height: 32)
            .background(Color.black)
            .accessibilityIdentifier("terminalTabBar")
        }
    }

    /// Resolved against the live `Server` rows, and an unresolvable id is skipped
    /// rather than pruned: a row that hasn't arrived from CloudKit yet shows no chip
    /// this pass and gets one when it syncs. `RootView.route` resolves the active id
    /// the same way, falling to `.home` while it can't.
    private var openTabs: [Server] {
        sessionManager.tabOrder.compactMap { id in servers.first(where: { $0.id == id }) }
    }
}

private struct TerminalTabChip: View {
    let server: Server
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 7, height: 7)
            Text(server.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .accessibilityLabel("Close \(server.name)")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 220, maxHeight: .infinity)
        .background(isActive ? Color.white.opacity(0.14) : Color.clear)
        .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.65))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityIdentifier("tabBar_\(server.name)")
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting, .waking: return .yellow
        case .disconnected: return .red
        }
    }
}

/// A Remote Browser tab's chip: a globe instead of the status dot's terminal meaning,
/// titled with the page when there is one — "GitHub · Sign in" says more than the
/// machine's name once you have two tabs on the same laptop.
private struct BrowserTabChip: View {
    let tab: SessionManager.BrowserTab
    @ObservedObject var session: RemoteBrowserSession
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(session.state == .connected ? Color.green : Color.yellow)
            Text(session.title?.isEmpty == false ? session.title! : tab.displayName)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .accessibilityLabel("Close browser")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 220, maxHeight: .infinity)
        .background(isActive ? Color.white.opacity(0.14) : Color.clear)
        .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.65))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityIdentifier("tabBar_browser_\(tab.siteID)")
    }
}
