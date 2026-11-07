import SwiftUI

/// The share sheet: what is being shared, an optional note, where it goes, Send.
struct ShareSheetView: View {
    @ObservedObject var model: ShareModel
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to Fin")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .sending {
                            ProgressView()
                        } else {
                            Button("Send") { model.send() }
                                .disabled(!model.canSend)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            ContentUnavailableView("Can't send to Fin", systemImage: "exclamationmark.bubble", description: Text(reason))
        default:
            form
        }
    }

    private var form: some View {
        Form {
            if !model.drafts.isEmpty || !model.links.isEmpty || !model.texts.isEmpty {
                Section("Sharing") {
                    ForEach(model.drafts) { draft in itemRow(draft) }
                    ForEach(model.links, id: \.self) { link in
                        Label(link, systemImage: "link").lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(Array(model.texts.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "text.alignleft").lineLimit(2)
                    }
                }
            }
            Section("Note") {
                TextField("Optional — e.g. give me a breakdown of cost by quarter", text: $model.note, axis: .vertical)
                    .lineLimit(2...6)
            }
            Section {
                if model.currentThreadID != nil {
                    Toggle("New thread", isOn: $model.startNewThread)
                }
                Label(model.targetLabel, systemImage: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("To \(model.agentName)").font(.caption).foregroundStyle(.secondary)
            }
            if let message = statusMessage {
                Section { Text(message).foregroundStyle(.red).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .disabled(model.phase == .sending)
    }

    private var statusMessage: String? {
        if case .failed(let message) = model.phase { return message }
        if let notice = model.notice { return notice }
        if let problem = model.problem, problem != .empty { return problem.message }
        return nil
    }

    private func itemRow(_ draft: AttachmentDraft) -> some View {
        HStack(spacing: 10) {
            Group {
                if let image = model.thumbnails[draft.id] {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: MessageAttachment(key: "", name: draft.name, mime: draft.mime, size: draft.size).systemImage)
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.name).lineLimit(1).truncationMode(.middle)
                Text(detail(draft)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase != .sending {
                Button { model.remove(draft.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(draft.name)")
            }
        }
    }

    private func detail(_ draft: AttachmentDraft) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(draft.size), countStyle: .file)
        switch draft.state {
        case .staged: return size
        case .uploading: return "Uploading…"
        case .uploaded: return "Uploaded"
        case .failed(let reason): return reason
        }
    }
}
