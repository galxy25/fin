// The tvOS shell: server list (CloudKit-synced rows) → full-screen terminal.
// Deliberately smaller than the iOS RootView — no markdown, no key import, no
// agents; those live on the other platforms.
import SwiftUI
import SwiftData

struct TVRootView: View {
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @EnvironmentObject private var remoteInput: RemoteInputService
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        NavigationStack {
            TVServerListView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sessionManager.resumeActiveSessionIfNeeded(servers: servers)
            }
        }
    }
}

struct TVServerListView: View {
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @EnvironmentObject private var remoteInput: RemoteInputService
    @Query(sort: \Server.createdAt) private var servers: [Server]

    var body: some View {
        Group {
            if servers.isEmpty {
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
            } else {
                List {
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
        var parts: [String] = []
        parts.append(keyboardMonitor.keyboardAttached
            ? "Bluetooth keyboard connected."
            : "Pair a Bluetooth keyboard in Settings, or use the Fin iOS app as a remote keyboard.")
        switch remoteInput.state {
        case .connected(let peerName):
            parts.append("Remote keyboard: \(peerName).")
        case .advertising:
            parts.append("Discoverable to Fin on your other devices (same network and iCloud account).")
        case .failed(let message):
            parts.append("Remote keyboard unavailable: \(message)")
        case .idle:
            break
        }
        return parts.joined(separator: " ")
    }
}

struct TVTerminalScreen: View {
    let server: Server
    @EnvironmentObject private var sessionManager: TVSessionManager
    @EnvironmentObject private var keyboardMonitor: TVKeyboardMonitor
    @EnvironmentObject private var remoteInput: RemoteInputService
    @AppStorage("themeBackgroundHex") private var themeBackgroundHex: String = "#000000"
    @AppStorage("themeForegroundHex") private var themeForegroundHex: String = "#00FF00"
    @State private var fallbackCommand = ""

    var body: some View {
        Group {
            if let session = sessionManager.sessions[server.id] {
                VStack(spacing: 0) {
                    strip(session: session)
                    TerminalCanvas(
                        session: session,
                        backgroundHex: themeBackgroundHex,
                        foregroundHex: themeForegroundHex
                    )
                }
                .background(Color(uiColor: UIColor(hexString: themeBackgroundHex) ?? .black))
            } else {
                ProgressView()
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarBackButtonHidden(false)
        .task {
            sessionManager.open(server)
        }
        .onAppear {
            sessionManager.activeServerID = server.id
            keyboardMonitor.isCaptureActive = { true }
        }
        .onDisappear {
            keyboardMonitor.isCaptureActive = { false }
        }
    }

    @ViewBuilder
    private func strip(session: TVTerminalSession) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(stateColor(session.state))
                .frame(width: 12, height: 12)
            Text(session.remoteTitle.isEmpty ? server.name : session.remoteTitle)
                .font(.footnote)
                .monospaced()
                .lineLimit(1)
            if let error = session.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            if keyboardMonitor.keyboardAttached {
                Image(systemName: "keyboard.fill")
                    .foregroundStyle(.secondary)
            }
            if case .connected(let peerName) = remoteInput.state {
                Label(peerName, systemImage: "iphone.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // System text entry as the no-keyboard fallback — tvOS pops its
            // full-screen keyboard (which itself offers iPhone typing via the
            // system's "Apple TV Keyboard" feature).
            TextField("Type a command…", text: $fallbackCommand)
                .font(.footnote)
                .frame(maxWidth: 420)
                .onSubmit {
                    session.send(text: fallbackCommand + "\r")
                    fallbackCommand = ""
                }
            Button {
                sessionManager.close(server.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func stateColor(_ state: TVSessionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }
}
