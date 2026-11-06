import Foundation
import UniformTypeIdentifiers

/// A file chosen in Xanadu's composer (a photo, a file, a voice recording) or
/// handed in by Siri, staged as a local copy until it is uploaded.
struct AttachmentDraft: Identifiable, Equatable {
    enum State: Equatable {
        case staged
        case uploading
        case uploaded(MessageAttachment)
        case failed(String)
    }

    let id: UUID
    var name: String
    var mime: String
    var size: Int
    /// The staged local copy the bytes are read from at upload time.
    var fileURL: URL
    /// Audio only: the on-device transcript that travels with the file.
    var transcript: String?
    var state: State = .staged

    init(id: UUID = UUID(), name: String, mime: String, size: Int, fileURL: URL, transcript: String? = nil, state: State = .staged) {
        self.id = id; self.name = name; self.mime = mime; self.size = size
        self.fileURL = fileURL; self.transcript = transcript; self.state = state
    }

    var kind: MessageAttachment.Kind { MessageAttachment.kind(ofMIME: mime) }

    var uploaded: MessageAttachment? {
        if case .uploaded(let attachment) = state { return attachment }
        return nil
    }

    var isTooLarge: Bool { size > MessageAttachment.maxBytes }

    /// The MIME type for a file name, `application/octet-stream` when the
    /// system knows no better.
    static func mime(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "application/octet-stream" }
        return type.preferredMIMEType ?? "application/octet-stream"
    }

    /// Where staged copies live: one folder per draft, so two files with the
    /// same name never collide. Cleared by the OS with the rest of tmp.
    static func stagingURL(for name: String, id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("XanaduOutbox", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(MessageAttachment.safeName(name))
    }

    /// Copy a file the user picked (or Siri handed over) into staging.
    static func stage(copying source: URL, name: String? = nil, mime: String? = nil, transcript: String? = nil) throws -> AttachmentDraft {
        let id = UUID()
        let displayName = name ?? source.lastPathComponent
        let destination = stagingURL(for: displayName, id: id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        return AttachmentDraft(id: id, name: displayName, mime: mime ?? Self.mime(forFileName: displayName),
                               size: size, fileURL: destination, transcript: transcript)
    }

    /// Stage bytes already in memory (a Photos pick, an `IntentFile`).
    static func stage(data: Data, name: String, mime: String? = nil, transcript: String? = nil) throws -> AttachmentDraft {
        let id = UUID()
        let destination = stagingURL(for: name, id: id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return AttachmentDraft(id: id, name: name, mime: mime ?? Self.mime(forFileName: name), size: data.count,
                               fileURL: destination, transcript: transcript)
    }
}

/// docs/XANADU.md's upload-then-send flow, kept out of the view so it is
/// testable with a mocked client: every file goes `POST /attachments` → PUT to
/// the presigned URL → and only when EVERY file made it, `POST /messages` with
/// the attachment entries. A message is never sent naming a key that was not
/// uploaded (the control plane would 400 it anyway — "attachment not
/// uploaded" — but the user would lose the text with it).
enum XanaduSend {
    struct Client {
        var requestUpload: (_ agent: String, _ name: String, _ mime: String, _ size: Int) async
            -> Result<ControlPlaneClient.AttachmentUpload, ControlPlaneClient.Failure>
        var put: (_ upload: ControlPlaneClient.AttachmentUpload, _ body: Data) async -> Result<Void, ControlPlaneClient.Failure>
        var send: (_ agent: String, _ text: String, _ messageID: String, _ context: ControlPlaneClient.MessageContext,
                   _ attachments: [MessageAttachment]) async -> Result<ControlPlaneClient.Message, ControlPlaneClient.Failure>
        var readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }

        static let live = Client(
            requestUpload: { agent, name, mime, size in
                await ControlPlaneClient.requestAttachmentUpload(agent: agent, name: name, mime: mime, size: size)
            },
            put: { upload, body in await ControlPlaneClient.putAttachment(upload, body: body) },
            send: { agent, text, messageID, context, attachments in
                await ControlPlaneClient.sendMessage(
                    agent: agent, text: text, messageID: messageID, context: context, attachments: attachments
                )
            }
        )
    }

    enum Problem: Error, Equatable {
        case empty
        case textTooLong
        case tooMany
        case tooLarge(name: String)
        case unreadable(name: String)
        case upload(name: String, reason: String)
        case send(String)

        var message: String {
            switch self {
            case .empty: return "Nothing to send."
            case .textTooLong: return "That message is too long to send."
            case .tooMany: return "At most \(MessageAttachment.maxPerMessage) files per message."
            case .tooLarge(let name): return "\(name) is over the 25 MB limit."
            case .unreadable(let name): return "Couldn't read \(name)."
            case .upload(let name, let reason): return "\(name) didn't upload (\(reason))."
            case .send(let reason): return "Not sent (\(reason))."
            }
        }
    }

    /// What can be refused before touching the network. Pure.
    static func validate(text: String, drafts: [AttachmentDraft], maxTextLength: Int = CloudAgentChannel.maxTextLength) -> Problem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && drafts.isEmpty { return .empty }
        if trimmed.count > maxTextLength { return .textTooLong }
        if drafts.count > MessageAttachment.maxPerMessage { return .tooMany }
        if let big = drafts.first(where: \.isTooLarge) { return .tooLarge(name: big.name) }
        return nil
    }

    static func describe(_ failure: ControlPlaneClient.Failure) -> String {
        switch failure {
        case .notConfigured: return "the cloud isn't set up"
        case .network: return "no connection"
        case .http(let status, let message): return status == 0 ? message : "\(message)"
        }
    }

    /// One file: ask for a slot, PUT the bytes with exactly the headers named.
    static func upload(_ draft: AttachmentDraft, agent: String, client: Client) async -> Result<MessageAttachment, Problem> {
        if let done = draft.uploaded { return .success(done) }
        guard !draft.isTooLarge else { return .failure(.tooLarge(name: draft.name)) }
        guard let data = try? client.readFile(draft.fileURL) else { return .failure(.unreadable(name: draft.name)) }
        guard data.count <= MessageAttachment.maxBytes else { return .failure(.tooLarge(name: draft.name)) }
        let slot: ControlPlaneClient.AttachmentUpload
        switch await client.requestUpload(agent, draft.name, draft.mime, data.count) {
        case .success(let value): slot = value
        case .failure(let failure): return .failure(.upload(name: draft.name, reason: describe(failure)))
        }
        if case .failure(let failure) = await client.put(slot, data) {
            return .failure(.upload(name: draft.name, reason: describe(failure)))
        }
        return .success(MessageAttachment(
            key: slot.key, name: draft.name, mime: draft.mime, size: data.count,
            transcript: draft.kind == .audio ? draft.transcript : nil
        ))
    }

    /// Upload every draft not uploaded yet (reporting each state change through
    /// `update`, so chips show progress and failures), then — only if all of
    /// them made it — send the message. A retry with the same drafts skips the
    /// files already uploaded and reuses `messageID`, which the control plane
    /// treats as the same message.
    @MainActor
    static func send(
        text: String, drafts: [AttachmentDraft], agent: String, messageID: String,
        context: ControlPlaneClient.MessageContext, client: Client = .live,
        update: (UUID, AttachmentDraft.State) -> Void = { _, _ in }
    ) async -> Result<ControlPlaneClient.Message, Problem> {
        if let problem = validate(text: text, drafts: drafts) { return .failure(problem) }
        var attachments: [MessageAttachment] = []
        var firstProblem: Problem?
        for draft in drafts {
            if let done = draft.uploaded { attachments.append(done); continue }
            update(draft.id, .uploading)
            switch await upload(draft, agent: agent, client: client) {
            case .success(let attachment):
                update(draft.id, .uploaded(attachment))
                attachments.append(attachment)
            case .failure(let problem):
                update(draft.id, .failed(problem.message))
                if firstProblem == nil { firstProblem = problem }
            }
        }
        if let firstProblem { return .failure(firstProblem) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await client.send(agent, trimmed, messageID, context, attachments) {
        case .success(let row): return .success(row)
        case .failure(let failure): return .failure(.send(describe(failure)))
        }
    }
}
