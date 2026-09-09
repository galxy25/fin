import SwiftUI

/// A second filesystem apart from the iOS native one: every plain-text file an agent
/// (or the owner, from here) has written to the shared control-plane artifacts store —
/// one flat space per Fin account, not per agent, since any agent's `write_artifact`
/// tool call lands in the same place. "other artifacts are arbitrary text files" is the
/// whole v1 scope — no binary or MIME handling, just a list and a text editor.
struct ArtifactsView: View {
    enum LoadState: Equatable {
        case loading
        case loaded([ArtifactsClient.Entry])
        case notConfigured
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var isShowingNewFilePrompt = false
    @State private var newFilePath = ""

    var body: some View {
        content
            .navigationTitle("Artifacts")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFilePath = ""
                        isShowingNewFilePrompt = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await load() }
            .alert("New File", isPresented: $isShowingNewFilePrompt) {
                TextField("path/to/file.txt", text: $newFilePath)
                    #if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create") { createFile() }
                    .disabled(!Self.isValidNewPath(newFilePath))
            } message: {
                Text("A relative path — letters, digits, \".\", \"_\", \"-\", and \"/\" for folders.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading artifacts…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured:
            VStack(alignment: .leading, spacing: 6) {
                Label("Control plane not configured", systemImage: "externaldrive.badge.xmark")
                    .font(.headline)
                Text("Set the control plane in an agent's Hosting settings to browse artifacts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Button("Retry") { Task { await load() } }
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
        case .loaded(let entries):
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("No artifacts yet")
                        .font(.headline)
                    Text("Files an agent writes with write_artifact — or that you create here — show up in this list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding()
            } else {
                List {
                    ForEach(entries) { entry in
                        NavigationLink {
                            ArtifactDetailView(path: entry.path, onDeleted: { removed(entry) })
                        } label: {
                            row(entry)
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
    }

    private func row(_ entry: ArtifactsClient.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.path)
                .font(.callout)
                .lineLimit(1)
            Text(Self.formattedSize(entry.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        state = .loading
        switch await ArtifactsClient.list() {
        case .found(let entries): state = .loaded(entries)
        case .notConfigured: state = .notConfigured
        case .failed(let message): state = .failed(message)
        }
    }

    private func removed(_ entry: ArtifactsClient.Entry) {
        guard case .loaded(let entries) = state else { return }
        state = .loaded(entries.filter { $0.path != entry.path })
    }

    private func createFile() {
        let path = newFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidNewPath(path) else { return }
        guard case .loaded(let entries) = state else { return }
        // A brand-new, empty entry — saving in the detail view is what actually
        // creates it on the control plane; navigating there first (rather than
        // writing an empty file up front) means backing out without saving leaves
        // nothing behind.
        state = .loaded((entries + [ArtifactsClient.Entry(path: path, size: 0)])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    /// Same shape the control plane's own `ARTIFACT_PATH` regex requires
    /// (`^[A-Za-z0-9][A-Za-z0-9._/-]{0,300}$`), checked client-side so a bad path
    /// fails obviously in the prompt instead of as a server error after "Create".
    static func isValidNewPath(_ path: String) -> Bool {
        guard let first = path.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              path.count <= 301
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-"))
        return path.unicodeScalars.allSatisfy(allowed.contains) && !path.contains("..")
    }

    static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// One artifact's content: loaded on appear, edited in place, saved explicitly (never
/// autosaved — a plain text editor over a network call should never surprise-write).
struct ArtifactDetailView: View {
    let path: String
    var onDeleted: () -> Void = {}

    enum LoadState: Equatable {
        case loading
        case loaded
        case notFound
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var content = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var saveError: String?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notFound:
                VStack(spacing: 6) {
                    Text("This file doesn't exist yet")
                        .font(.headline)
                    Text("Start typing and save to create it at \"\(path)\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                editor
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding()
            case .loaded:
                editor
            }
        }
        .navigationTitle(path)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }
                        .disabled(state == .loading)
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(state == .loading || isDeleting)
            }
        }
        .confirmationDialog(
            "Delete \"\(path)\"? This can't be undone.",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
        .task { await load() }
    }

    private var editor: some View {
        TextEditor(text: $content)
            .font(.system(.body, design: .monospaced))
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }

    private func load() async {
        state = .loading
        switch await ArtifactsClient.read(path: path) {
        case .found(let text):
            content = text
            state = .loaded
        case .notFound:
            content = ""
            state = .notFound
        case .notConfigured:
            state = .failed("Control plane not configured")
        case .failed(let message):
            state = .failed(message)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            switch await ArtifactsClient.write(path: path, content: content) {
            case .saved:
                state = .loaded
            case .notConfigured:
                saveError = "Control plane not configured"
            case .failed(let message):
                saveError = message
            }
        }
    }

    private func delete() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            switch await ArtifactsClient.delete(path: path) {
            case .deleted:
                onDeleted()
                dismiss()
            case .notConfigured:
                saveError = "Control plane not configured"
            case .failed(let message):
                saveError = message
            }
        }
    }
}
