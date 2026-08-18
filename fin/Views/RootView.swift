import SwiftUI
import SwiftData

struct RootView: View {
    private enum Route {
        case terminal(Server)
        case markdown(MarkdownDocument)
        case home
    }

    @EnvironmentObject private var sessionManager: SessionManager
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @Query private var markdownDocuments: [MarkdownDocument]
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("lastActiveServerTouchedAt") private var lastActiveServerTouchedAt: Double = 0
    @AppStorage("lastActiveMarkdownDocumentID") private var lastActiveMarkdownDocumentID: String = ""
    @AppStorage("lastActiveMarkdownTouchedAt") private var lastActiveMarkdownTouchedAt: Double = 0

    var body: some View {
        Group {
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sessionManager.resumeActiveSessionIfNeeded(servers: servers)
            }
        }
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
