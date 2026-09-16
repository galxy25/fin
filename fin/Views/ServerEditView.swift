import SwiftUI
import SwiftData

struct ServerEditView: View {
    let server: Server?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KeyMetadata.importedAt) private var keys: [KeyMetadata]
    /// Populated by whoever is already refreshing it — `ServerListView`'s own
    /// `.task` loop, running underneath this sheet — so opening the editor
    /// doesn't need its own fetch/refresh cadence.
    @ObservedObject private var siteDirectory = SiteDirectory.shared

    @State private var transport: ServerTransport
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var relaySiteId: String?
    @State private var tmuxSessionName: String
    @State private var connectCommand: String
    @State private var keepScreenAwake: Bool
    @State private var selectedKeyID: UUID?
    @State private var isImportingKey = false
    @State private var isAdvancedExpanded = false

    /// Sites this device knows can host a relayed terminal — an older daemon
    /// (no `terminal_relay` capability) is simply absent from the picker, the
    /// same forward/back-compat rule the capability's own doc comment states.
    private var relayCapableSites: [FinSite] {
        siteDirectory.sites.filter { $0.state != "retired" && $0.capabilities.terminalRelay == true }
    }

    init(server: Server?) {
        self.server = server
        _transport = State(initialValue: server?.transport ?? .direct)
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 22))
        _username = State(initialValue: server?.username ?? "")
        _relaySiteId = State(initialValue: server?.relaySiteId)
        _tmuxSessionName = State(initialValue: server?.tmuxSessionName ?? "main")
        _connectCommand = State(initialValue: server?.connectCommand ?? "")
        _keepScreenAwake = State(initialValue: server?.keepScreenAwake ?? false)
        _selectedKeyID = State(initialValue: server?.keyID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Connect via", selection: $transport) {
                        Text("Direct SSH").tag(ServerTransport.direct)
                        Text("Fin site relay").tag(ServerTransport.siteRelay)
                    }
                } footer: {
                    if transport == .siteRelay {
                        Text("Attaches to a tmux session on one of Fin\u{2019}s sites through the control plane — for a computer (like a work laptop) that can only make outbound connections, so it can\u{2019}t be dialed directly.")
                    }
                }
                if transport == .direct {
                    Section("Server") {
                        TextField("Name", text: $name)
                        TextField("Host", text: $host)
                            .autocapitalizationNeverIfAvailable()
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .numberPadIfAvailable()
                        TextField("Username", text: $username)
                            .autocapitalizationNeverIfAvailable()
                            .autocorrectionDisabled()
                    }
                    Section("Private Key") {
                        Picker("Key", selection: $selectedKeyID) {
                            Text("None").tag(UUID?.none)
                            ForEach(keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                        Button("Import Key from Files…") {
                            isImportingKey = true
                        }
                    }
                } else {
                    Section("Server") {
                        TextField("Name", text: $name)
                        Picker("Site", selection: $relaySiteId) {
                            Text("Choose a site").tag(String?.none)
                            ForEach(relayCapableSites) { site in
                                Text(site.displayName).tag(Optional(site.siteId))
                            }
                        }
                        if relayCapableSites.isEmpty {
                            Text("No sites currently support a relayed terminal. Make sure the target Mac is running an up-to-date fin-agentd.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(iOS)
                Section {
                    Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                } footer: {
                    Text("Prevents the display from auto-locking while this session is on screen. Uses more battery.")
                }
                #endif
                if transport == .siteRelay {
                    Section {
                        TextField("tmux session name", text: $tmuxSessionName)
                            .autocapitalizationNeverIfAvailable()
                            .autocorrectionDisabled()
                    } header: {
                        Text("tmux session")
                    } footer: {
                        Text("The site's daemon attaches to this tmux session (creating it if it doesn't exist yet) and relays it here.")
                    }
                } else {
                    Section {
                        DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                            TextField("tmux session name", text: $tmuxSessionName)
                                .autocapitalizationNeverIfAvailable()
                                .autocorrectionDisabled()

                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Connect command", text: $connectCommand, axis: .vertical)
                                    .autocapitalizationNeverIfAvailable()
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                Text("Sent as if typed, right after connecting. Leave blank to just open a plain shell — e.g. if the server already auto-attaches tmux/mosh on login.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Button("Use \u{201c}exec tmux new-session -A -s \(tmuxSessionName)\u{201d}") {
                                connectCommand = "exec tmux new-session -A -s \(tmuxSessionName)"
                            }
                            .font(.footnote)
                            .disabled(tmuxSessionName.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle(server == nil ? "New Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .sheet(isPresented: $isImportingKey) {
            KeyImportView { imported in
                selectedKeyID = imported.id
            }
        }
    }

    private var canSave: Bool {
        guard !name.isEmpty else { return false }
        switch transport {
        case .direct: return !host.isEmpty && !username.isEmpty
        case .siteRelay: return relaySiteId != nil
        }
    }

    private func save() {
        let resolvedPort = Int(port) ?? 22
        if let server {
            server.transport = transport
            server.name = name
            server.host = host
            server.port = resolvedPort
            server.username = username
            server.relaySiteId = relaySiteId
            server.tmuxSessionName = tmuxSessionName
            server.connectCommand = connectCommand
            server.keepScreenAwake = keepScreenAwake
            server.keyID = selectedKeyID
        } else {
            let newServer = Server(
                name: name,
                host: host,
                port: resolvedPort,
                username: username,
                keyID: selectedKeyID,
                transport: transport,
                relaySiteId: relaySiteId,
                tmuxSessionName: tmuxSessionName,
                connectCommand: connectCommand,
                keepScreenAwake: keepScreenAwake
            )
            modelContext.insert(newServer)
        }
        dismiss()
    }
}
