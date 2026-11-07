import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One share: read what the sheet was handed, show it, send it into the
/// current Xanadu thread through `XanaduSend` (docs/XANADU.md "Share
/// extension (v1.1)").
@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        /// Nothing the extension can do: open Fin first.
        case unavailable(String)
        case sending
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var drafts: [AttachmentDraft] = []
    @Published var links: [String] = []
    @Published var texts: [String] = []
    @Published var note = ""
    @Published var startNewThread = false
    @Published var notice: String?
    @Published private(set) var currentThreadID: String?
    @Published private(set) var currentThreadTitle: String?
    @Published private(set) var thumbnails: [UUID: CGImage] = [:]

    let agentName: String
    /// Same id on every retry, so the control plane treats a retry as the
    /// same message and already-uploaded files are not uploaded again.
    private let messageID = ControlPlaneClient.newMessageID()
    private let complete: () -> Void

    init(complete: @escaping () -> Void) {
        self.complete = complete
        agentName = ShareCredentials.snapshot?.agentName ?? ""
    }

    var canSend: Bool {
        guard phase == .ready || isFailed else { return false }
        return problem == nil
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// What would refuse this send before the network.
    var problem: XanaduSend.Problem? {
        let composed = composed()
        return XanaduSend.validate(text: composed.text, drafts: drafts + (composed.overflowDraft.map { [$0] } ?? []))
    }

    var targetLabel: String {
        if startNewThread || currentThreadID == nil { return "New thread" }
        return "Current thread: " + (currentThreadTitle ?? "…")
    }

    // MARK: - Loading

    func load(_ providers: [NSItemProvider]) async {
        guard let snapshot = ShareCredentials.snapshot, snapshot.isUsable else {
            phase = .unavailable("Open Fin and sign in once, then share again.")
            return
        }
        currentThreadID = XanaduCurrentThread.get(agent: agentName)
        if currentThreadID == nil { startNewThread = true }
        var staged: [AttachmentDraft] = []
        for (index, provider) in providers.enumerated() {
            guard let route = ShareIntake.route(for: provider.registeredTypeIdentifiers) else { continue }
            switch route {
            case .file(let typeID):
                if let draft = await Self.stageFile(provider, typeID: typeID, index: index) { staged.append(draft) }
                else { notice = "Couldn't read one of the items." }
            case .fileURL:
                if let url = await Self.loadURL(provider, type: .fileURL), let draft = Self.stage(fileURL: url) {
                    staged.append(draft)
                } else { notice = "Couldn't read one of the items." }
            case .webURL:
                if let url = await Self.loadURL(provider, type: .url) { links.append(url.absoluteString) }
            case .text:
                if let text = await Self.loadText(provider) { texts.append(text) }
            }
        }
        if staged.count > MessageAttachment.maxPerMessage {
            notice = "At most \(MessageAttachment.maxPerMessage) files per message — the rest were left out."
            staged = Array(staged.prefix(MessageAttachment.maxPerMessage))
        }
        if let big = staged.first(where: \.isTooLarge) { notice = "\(big.name) is over the 25 MB limit." }
        drafts = staged
        thumbnails = Dictionary(uniqueKeysWithValues: staged.compactMap { draft in
            draft.kind == .image ? Self.thumbnail(draft.fileURL).map { (draft.id, $0) } : nil
        })
        phase = staged.isEmpty && links.isEmpty && texts.isEmpty ? .unavailable("Nothing Fin can take here.") : .ready
        if let thread = currentThreadID, case .success(let detail) = await ControlPlaneClient.thread(id: thread) {
            currentThreadTitle = detail.thread.displayTitle
        }
    }

    private static func stageFile(_ provider: NSItemProvider, typeID: String, index: Int) async -> AttachmentDraft? {
        guard let type = UTType(typeID) else { return nil }
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            // The URL is only valid inside this handler: copy before returning.
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = ShareIntake.fileName(suggested: suggested, loadedName: url.lastPathComponent,
                                                typeIdentifier: typeID, index: index)
                let draft = try? AttachmentDraft.stage(copying: url, name: name)
                continuation.resume(returning: draft.map(normalized))
            }
        }
    }

    private static func stage(fileURL url: URL) -> AttachmentDraft? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? AttachmentDraft.stage(copying: url)).map(normalized)
    }

    /// Photos are photos for a model: HEIC → JPEG, big ones scaled — the same
    /// rule Xanadu's composer applies.
    nonisolated private static func normalized(_ draft: AttachmentDraft) -> AttachmentDraft {
        guard draft.kind == .image, let data = try? Data(contentsOf: draft.fileURL) else { return draft }
        let normal = XanaduImageNormalizer.normalize(data: data, name: draft.name, type: UTType(mimeType: draft.mime))
        guard normal.mime != draft.mime || normal.data.count != data.count,
              let converted = try? AttachmentDraft.stage(data: normal.data, name: normal.name, mime: normal.mime)
        else { return draft }
        return converted
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { return nil }
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let text = item as? String { return URL(string: text) }
        return nil
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) else { return nil }
        if let text = item as? String { return text }
        if let attributed = item as? NSAttributedString { return attributed.string }
        if let data = item as? Data { return String(data: data, encoding: .utf8) }
        if let url = item as? URL, url.isFileURL { return try? String(contentsOf: url, encoding: .utf8) }
        return nil
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        thumbnails[id] = nil
    }

    // MARK: - Sending

    private struct Composed {
        let text: String
        let overflowDraft: AttachmentDraft?
    }

    private var overflowCache: (text: String, draft: AttachmentDraft)?

    private func composed() -> Composed {
        let parts = ShareIntake.messageText(note: note, urls: links, texts: texts)
        guard let overflow = parts.overflow else { return Composed(text: parts.text, overflowDraft: nil) }
        if let cached = overflowCache, cached.text == overflow { return Composed(text: parts.text, overflowDraft: cached.draft) }
        let draft = try? AttachmentDraft.stage(data: Data(overflow.utf8), name: ShareIntake.overflowFileName, mime: "text/plain")
        if let draft { overflowCache = (overflow, draft) }
        return Composed(text: parts.text, overflowDraft: draft)
    }

    func send() {
        guard canSend else { return }
        phase = .sending
        notice = nil
        let parts = composed()
        let files = drafts + (parts.overflowDraft.map { [$0] } ?? [])
        let target = XanaduCurrentThread.target(explicit: nil, startNewThread: startNewThread, current: currentThreadID)
        var context = ControlPlaneClient.MessageContext(source: "app")
        context.threadID = target
        let agent = agentName, messageID = messageID
        Task {
            let result = await XanaduSend.send(
                text: parts.text, drafts: files, agent: agent, messageID: messageID, context: context
            ) { [weak self] draftID, state in
                guard let self, let slot = self.drafts.firstIndex(where: { $0.id == draftID }) else {
                    if let self, var cached = self.overflowCache, cached.draft.id == draftID {
                        cached.draft.state = state
                        self.overflowCache = cached
                    }
                    return
                }
                self.drafts[slot].state = state
            }
            switch result {
            case .success(let row):
                XanaduCurrentThread.adoptSend(messageID: messageID, sentThreadID: target, row: row, agent: agent)
                Self.cleanUp(files)
                complete()
            case .failure(let problem):
                phase = .failed(problem.message)
            }
        }
    }

    /// Staged copies live in the extension's tmp; drop them once sent.
    private static func cleanUp(_ drafts: [AttachmentDraft]) {
        for draft in drafts { try? FileManager.default.removeItem(at: draft.fileURL.deletingLastPathComponent()) }
    }
}
