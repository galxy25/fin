import SwiftUI
import SwiftData

struct ServerEditView: View {
    let server: Server?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KeyMetadata.importedAt) private var keys: [KeyMetadata]

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var tmuxSessionName: String
    @State private var connectCommand: String
    @State private var selectedKeyID: UUID?
    @State private var isImportingKey = false
    @State private var isAdvancedExpanded = false

    init(server: Server?) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 22))
        _username = State(initialValue: server?.username ?? "")
        _tmuxSessionName = State(initialValue: server?.tmuxSessionName ?? "main")
        _connectCommand = State(initialValue: server?.connectCommand ?? "")
        _selectedKeyID = State(initialValue: server?.keyID)
    }

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle(server == nil ? "New Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
                }
            }
        }
        .sheet(isPresented: $isImportingKey) {
            KeyImportView { imported in
                selectedKeyID = imported.id
            }
        }
    }

    private func save() {
        let resolvedPort = Int(port) ?? 22
        if let server {
            server.name = name
            server.host = host
            server.port = resolvedPort
            server.username = username
            server.tmuxSessionName = tmuxSessionName
            server.connectCommand = connectCommand
            server.keyID = selectedKeyID
        } else {
            let newServer = Server(
                name: name,
                host: host,
                port: resolvedPort,
                username: username,
                keyID: selectedKeyID,
                tmuxSessionName: tmuxSessionName,
                connectCommand: connectCommand
            )
            modelContext.insert(newServer)
        }
        dismiss()
    }
}
