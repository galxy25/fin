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

    var body: some View {
        List {
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
            }
        }
        .listStyle(.plain)
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
            if servers.isEmpty {
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
