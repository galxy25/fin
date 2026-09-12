import SwiftUI
import SwiftData

struct ServerListView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.createdAt) private var servers: [Server]

    @State private var editingServer: Server?
    @State private var isAddingServer = false
    @State private var showingCloudStatus = false
    /// "Fin's computers": every body Fin can run in, by display name, with the
    /// lifecycle actions the control plane offers. Granting Fin's Key makes a
    /// machine a server Fin can REACH; enrolling a daemon makes it a site Fin
    /// can RUN ON — two different lists, one pane.
    @ObservedObject private var sites = SiteDirectory.shared
    @State private var siteActionError: String?
    @State private var expandedSiteID: String?

    private var visibleSites: [FinSite] { sites.sites.filter { $0.state != "retired" } }

    struct SiteGroup { let agent: String; let sites: [FinSite] }

    /// Grouped by agent, agents in first-seen order (the directory is already
    /// sorted by priority, so "Fin" — the resident — leads).
    private var siteGroups: [SiteGroup] { Self.grouped(visibleSites) }

    static func grouped(_ sites: [FinSite]) -> [SiteGroup] {
        var order: [String] = []
        var byAgent: [String: [FinSite]] = [:]
        for site in sites {
            if byAgent[site.agent] == nil { order.append(site.agent) }
            byAgent[site.agent, default: []].append(site)
        }
        return order.map { SiteGroup(agent: $0, sites: byAgent[$0] ?? []) }
    }

    var body: some View {
        List {
            if CloudControlPlaneConfig.isConfigured, !visibleSites.isEmpty {
                // One group per agent: `agent` is a column on every site row, so a
                // second agent is simply another group in the same pane — this is
                // the remote control for all agents and all their bodies.
                ForEach(siteGroups, id: \.agent) { group in
                    Section {
                        ForEach(group.sites) { site in
                            siteRow(site)
                        }
                        if group.agent == siteGroups.last?.agent, let siteActionError {
                            Label(siteActionError, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text(siteGroups.count > 1 ? "\(group.agent)\u{2019}s Computers" : "Fin\u{2019}s Computers")
                    }
                    .accessibilityIdentifier("finComputersSection_\(group.agent)")
                }
            }
            Section {
                serverRows
            } header: {
                if CloudControlPlaneConfig.isConfigured, !visibleSites.isEmpty {
                    Text("Servers")
                }
            }
        }
        .listStyle(.plain)
        .task {
            guard CloudControlPlaneConfig.isConfigured else { return }
            await sites.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await sites.refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCloudStatus = true
                } label: {
                    Image(systemName: "icloud")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingServer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if servers.isEmpty, visibleSites.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Tap + to add one.")
                )
            }
        }
        .sheet(isPresented: $isAddingServer) {
            ServerEditView(server: nil)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(server: server)
        }
        .sheet(isPresented: $showingCloudStatus) {
            CloudSyncStatusView()
        }
    }

    private var serverRows: some View {
            ForEach(servers) { server in
                HStack(spacing: 12) {
                    Button {
                        connect(to: server)
                    } label: {
                        row(for: server)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingServer = server
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { delete(server) }
                }
                .accessibilityIdentifier("serverRow_\(server.id.uuidString)")
            }
    }

    // MARK: - Fin's computers

    private func siteRow(_ site: FinSite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(site.live ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Image(systemName: site.kindGlyph)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(site.displayName).font(.headline)
                    Text("\(site.roleLabel) · \(site.statusLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(ControlPlaneClient.SiteCommand.allCases, id: \.rawValue) { command in
                        Button(command.rawValue.capitalized) { run(command, on: site) }
                    }
                    Divider()
                    Button("Forget this computer", role: .destructive) { retire(site) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("siteMenu_\(site.siteId8)")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedSiteID = expandedSiteID == site.siteId ? nil : site.siteId
            }
            if expandedSiteID == site.siteId {
                siteDetails(site)
            }
        }
        .accessibilityIdentifier("siteRow_\(site.siteId8)")
    }

    /// Ids and versions live here, behind a tap — never in the row itself.
    private func siteDetails(_ site: FinSite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            detailLine("Site", site.siteId8)
            detailLine("Kind", site.kind)
            if let version = site.capabilities.daemonVersion { detailLine("Daemon", version) }
            if let brain = site.capabilities.brain, let model = brain.model { detailLine("Brain", model) }
            if let workerId = site.workerId { detailLine("Worker", workerId) }
            if let at = site.lastHeartbeatAt {
                detailLine("Last heartbeat", at.formatted(.relative(presentation: .named)))
            }
            let sessions = site.capabilities.tmuxSessions ?? []
            if !sessions.isEmpty {
                detailLine("tmux", sessions.map(\.session).joined(separator: ", "))
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.leading, 26)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label + ":").foregroundStyle(.tertiary)
            Text(value).textSelection(.enabled)
        }
    }

    private func run(_ command: ControlPlaneClient.SiteCommand, on site: FinSite) {
        siteActionError = nil
        Task {
            if case .failure(let failure) = await ControlPlaneClient.siteCommand(site.siteId, command) {
                siteActionError = "\(command.rawValue) failed: \(SiteDirectory.describe(failure))"
            }
            await sites.refresh(force: true)
        }
    }

    private func retire(_ site: FinSite) {
        siteActionError = nil
        Task {
            if case .failure(let failure) = await ControlPlaneClient.deleteSite(site.siteId) {
                siteActionError = "couldn't forget \(site.displayName): \(SiteDirectory.describe(failure))"
            }
            await sites.refresh(force: true)
        }
    }

    private func row(for server: Server) -> some View {
        HStack {
            statusDot(for: server)
            VStack(alignment: .leading) {
                Text(server.name).font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusDot(for server: Server) -> some View {
        let connected = sessionManager.sessions[server.id]?.isConnected ?? false
        return Circle()
            .fill(connected ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
    }

    private func connect(to server: Server) {
        sessionManager.open(server)
        dismiss()
    }

    private func delete(_ server: Server) {
        sessionManager.close(server.id)
        modelContext.delete(server)
    }
}
