// The tvOS shell: server list (CloudKit-synced rows) → full-screen terminal.
// Deliberately smaller than the iOS RootView — no markdown, no key import, no
// agents; those live on the other platforms.
import SwiftUI
import SwiftData

struct TVRootView: View {
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @EnvironmentObject private var account: TVCloudAccount
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        NavigationStack {
            TVServerListView()
        }
        .task { await account.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sessionManager.resumeActiveSessionIfNeeded(servers: servers)
                Task { await account.refresh() }
            }
        }
    }
}

struct TVServerListView: View {
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        Group {
            if servers.isEmpty {
                List {
                    Section {
                        VStack(spacing: 20) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                            Text("No Servers Yet")
                                .font(.title2)
                            Text("Servers you add in Fin on iPhone, iPad, or Mac appear here automatically through iCloud. Give sync a moment after first launch.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 700)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    TVAccountSection()
                }
            } else {
                List {
                    TVAccountSection()
                    Section {
                        ForEach(servers) { server in
                            NavigationLink {
                                TVTerminalScreen(server: server)
                            } label: {
                                serverRow(server)
                            }
                        }
                    } footer: {
                        Text(footerStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Fin")
    }

    private func serverRow(_ server: Server) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(sessionManager.sessions[server.id]?.isConnected == true ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.username)@\(server.host):\(String(server.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if server.keyID == nil || KeychainStore.loadPrivateKey(for: server.keyID ?? UUID()) == nil {
                Label("Key needed", systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var footerStatus: String {
        keyboardMonitor.keyboardAttached
            ? "Bluetooth keyboard connected."
            : "Pair a Bluetooth keyboard in Settings, or type from your iPhone with the system keyboard."
    }
}

// `TVTerminalScreen` lives in TVTerminalScreen.swift.
