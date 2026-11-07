import Foundation
import FinAgentCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One file a message carries (docs/XANADU.md, "Wire contract"): the heartbeat
/// offer's `attachments[]` entry. `url` is a presigned GET that lapses — it is kept
/// in the held ledger anyway, so a message held across a quick restart can still be
/// fetched; a lapsed one becomes a "(download failed: …)" line, never a lost message.
struct MessageAttachment: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var mime: String
    var size: Int?
    /// Audio only: the on-device transcript that travelled with the file.
    var transcript: String?
    var url: String?

    init(key: String, name: String, mime: String, size: Int? = nil, transcript: String? = nil, url: String? = nil) {
        self.key = key
        self.name = name
        self.mime = mime
        self.size = size
        self.transcript = transcript
        self.url = url
    }

    /// Tolerant decode of an offer's `attachments` value: anything that is not an
    /// array of objects is "none", an entry with neither a key nor a name is skipped,
    /// and every other field defaults — a newer control plane never breaks this daemon.
    static func decodeList(_ value: Any?) -> [MessageAttachment] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            let key = entry["key"] as? String ?? ""
            var name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = (key as NSString).lastPathComponent }
            guard !name.isEmpty else { return nil }
            let mime = (entry["mime"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
            let size = (entry["size"] as? NSNumber)?.intValue
            let transcript = (entry["transcript"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let url = (entry["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return MessageAttachment(key: key, name: name, mime: mime, size: size, transcript: transcript, url: url)
        }
    }
}

/// A file Fin queued with `attach_file` to go back with its reply (docs/XANADU.md
/// "Fin replies with files"): validated at queue time, uploaded at the answered ack.
struct QueuedReplyFile: Equatable, Sendable {
    /// Absolute, tilde-expanded, symlinks resolved.
    var path: String
    /// What the user sees — the tool's `name`, else the file's own name.
    var name: String
    var mime: String
    var size: Int
}

/// What became of one attachment on this machine: saved at `path`, or `failure`.
struct FetchedAttachment: Equatable, Sendable {
    var attachment: MessageAttachment
    var path: String?
    /// Bytes actually written; nil when the download failed.
    var bytes: Int?
    var failure: String?
}

/// The site half of Xanadu attachments (docs/XANADU.md, "Site (fin-agentd)"): download
/// each file into `<root>/<threadId-or-messageId>/<safeName>`, name it in the turn
/// prompt so Fin works it with its terminal tools, and — for a brain that can see —
/// hand images to the model as `image_url` parts. Everything but `download` is pure.
enum DaemonAttachments {
    static let defaultDirectory = "~/Fin/Attachments"
    static let maxSafeNameLength = 96
    static let maxTranscriptCharacters = 8_000
    /// The image types every vision-capable chat-completions server takes. A HEIC or
    /// TIFF is saved and named like any other file but never sent as pixels: one
    /// unsupported part fails the whole request, and the user's message with it.
    static let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"]

    static let promptHeader = "Attached files (saved on this machine — work with them using your terminal tools):"

    // MARK: Paths

    static func resolvedRoot(_ configured: String?) -> String {
        let raw = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ((raw.isEmpty ? defaultDirectory : raw) as NSString).expandingTildeInPath
    }

    /// The contract's `safeName`: `[A-Za-z0-9._-]` only (anything else becomes `_`),
    /// at most 96 characters with the extension kept, never empty (`file`). Leading
    /// dots are dropped too, so a name can never be `..` or a hidden file.
    static func safeName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var safe = String(name.map { allowed.contains($0) ? $0 : "_" })
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.isEmpty || safe.allSatisfy({ $0 == "_" || $0 == "." }) { return "file" }
        guard safe.count > maxSafeNameLength else { return safe }
        let ext = (safe as NSString).pathExtension
        if !ext.isEmpty, ext.count < 16 {
            let base = (safe as NSString).deletingPathExtension
            return String(base.prefix(maxSafeNameLength - ext.count - 1)) + "." + ext
        }
        return String(safe.prefix(maxSafeNameLength))
    }

    /// The file name for an attachment: the control plane's own `safeName` (the key's
    /// last component) when the key has one, re-sanitized; else `safeName(name)`.
    static func fileName(for attachment: MessageAttachment) -> String {
        let fromKey = (attachment.key as NSString).lastPathComponent
        return safeName(fromKey.isEmpty ? attachment.name : fromKey)
    }

    /// `name`, or `name (2)`, `name (3)`… (before the extension) — the first that
    /// `exists` says is free.
    static func uniqueFileName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    static func folderPath(root: String, threadOrMessageID: String) -> String {
        (root as NSString).appendingPathComponent(safeName(threadOrMessageID))
    }

    // MARK: Describing

    /// A human word for the file, for the prompt and the transcript line.
    static func kind(mime: String, name: String) -> String {
        let mime = mime.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime.hasPrefix("video/") { return "video" }
        if mime == "application/pdf" || ext == "pdf" { return "PDF" }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv"
            || ["xlsx", "xls", "csv", "tsv", "numbers"].contains(ext) { return "spreadsheet" }
        if mime.contains("presentation") || mime.contains("powerpoint")
            || ["pptx", "ppt", "key"].contains(ext) { return "presentation" }
        if mime.contains("wordprocessing") || mime.contains("msword") || mime == "application/rtf"
            || ["docx", "doc", "pages", "rtf"].contains(ext) { return "document" }
        if mime.contains("zip") || mime.contains("tar") || mime.contains("gzip")
            || ["zip", "tar", "gz", "tgz"].contains(ext) { return "archive" }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") { return "text" }
        return "file"
    }

    /// "812 bytes", "47 KB", "1.2 MB" (binary units, the way Finder's neighbours count).
    static func formattedSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        if bytes < 1024 * 1024 { return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func describe(_ attachment: MessageAttachment, bytes: Int? = nil) -> String {
        let kind = kind(mime: attachment.mime, name: attachment.name)
        guard let size = bytes ?? attachment.size else { return kind }
        return "\(kind), \(formattedSize(size))"
    }

    /// The block appended to the user turn prompt, or nil when there are no files.
    static func promptBlock(_ fetched: [FetchedAttachment]) -> String? {
        guard !fetched.isEmpty else { return nil }
        let lines = fetched.map { item -> String in
            let attachment = item.attachment
            var line = "- "
            if let path = item.path {
                line += "\(path) (\(describe(attachment, bytes: item.bytes)))"
            } else {
                line += "\(attachment.name) (\(describe(attachment))) (download failed: \(item.failure ?? "unknown error"))"
            }
            if let transcript = attachment.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                line += " — transcript: \"\(transcript.prefix(maxTranscriptCharacters))\""
            }
            return line
        }
        return ([promptHeader] + lines).joined(separator: "\n")
    }

    /// The compact line the transcript, the audit trail and episodic memory record in
    /// place of the long prompt: `[Attached: Q3 costs.xlsx (spreadsheet, 47 KB), …]`.
    static func displayLine(_ attachments: [MessageAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        return "[Attached: " + attachments.map { "\($0.name) (\(describe($0)))" }.joined(separator: ", ") + "]"
    }

    /// The user's own words plus the compact attachment line (or just the line, for a
    /// message that was only files).
    static func displayText(_ text: String, attachments: [MessageAttachment]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = displayLine(attachments) else { return trimmed }
        return trimmed.isEmpty ? line : trimmed + "\n" + line
    }

    /// The images a seeing brain gets as pixels: saved, a widely supported type, and
    /// no larger than `AgentImageReference.maxBytes`.
    static func imageReferences(_ fetched: [FetchedAttachment]) -> [AgentImageReference] {
        fetched.compactMap { item in
            let mime = item.attachment.mime.lowercased()
            guard let path = item.path, inlineImageTypes.contains(mime),
                  let bytes = item.bytes, bytes > 0, bytes <= AgentImageReference.maxBytes
            else { return nil }
            return AgentImageReference(path: path, mimeType: mime == "image/jpg" ? "image/jpeg" : mime)
        }
    }

    // MARK: Reply files (attach_file)

    /// The contract's caps: the same 25 MiB as a user upload, at most 8 per reply.
    static let maxReplyFileBytes = 25 * 1024 * 1024
    static let maxReplyFilesPerTurn = 8

    /// The checks `attach_file` makes before queueing: a regular, readable file (a
    /// symlink is followed to one) of at most 25 MiB, not already queued, within the
    /// per-turn cap. `.failure` carries the refusal the model reads. Touches only the
    /// file system's metadata — the bytes are read at upload time.
    static func validateReplyFile(
        path rawPath: String, name rawName: String?, queued: [QueuedReplyFile],
        fileManager: FileManager = .default
    ) -> Result<QueuedReplyFile, ReplyFileRefusal> {
        guard queued.count < maxReplyFilesPerTurn else {
            return .failure(.init("at most \(maxReplyFilesPerTurn) files go back with one reply"))
        }
        let expanded = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure(.init("give the file's full path (absolute or ~/…)"))
        }
        let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return .failure(.init("no such file"))
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return .failure(.init("not a regular file (a folder? zip it first)"))
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxReplyFileBytes else {
            return .failure(.init("\(formattedSize(size)) is over the 25 MB limit"))
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return .failure(.init("not readable"))
        }
        guard !queued.contains(where: { $0.path == path }) else {
            return .failure(.init("already attached to this reply"))
        }
        var name = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }
        if name.isEmpty { name = (path as NSString).lastPathComponent }
        name = String(name.prefix(255))
        // The mime follows the FILE (its real extension), not a display name the model made up.
        let mime = mimeType(forFileName: (path as NSString).lastPathComponent)
        return .success(QueuedReplyFile(path: path, name: name, mime: mime, size: size))
    }

    struct ReplyFileRefusal: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// A media type from the extension — portable (no UniformTypeIdentifiers, which a
    /// Linux cloud worker does not have); anything unknown is application/octet-stream.
    static func mimeType(forFileName name: String) -> String {
        let types: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
            "webp": "image/webp", "heic": "image/heic", "tif": "image/tiff", "tiff": "image/tiff",
            "svg": "image/svg+xml", "bmp": "image/bmp",
            "pdf": "application/pdf", "json": "application/json", "xml": "application/xml",
            "csv": "text/csv", "tsv": "text/tab-separated-values", "txt": "text/plain", "log": "text/plain",
            "md": "text/markdown", "html": "text/html", "htm": "text/html",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "xls": "application/vnd.ms-excel",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "doc": "application/msword",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "ppt": "application/vnd.ms-powerpoint", "rtf": "application/rtf",
            "zip": "application/zip", "gz": "application/gzip", "tgz": "application/gzip", "tar": "application/x-tar",
            "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "aac": "audio/aac",
            "mp4": "video/mp4", "mov": "video/quicktime",
        ]
        return types[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// The reply-text note for a file that could not go up (the contract's wording).
    static func replyFailureNote(name: String, reason: String) -> String {
        "(couldn't attach \(name): \(reason))"
    }

    // MARK: Downloading

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 60s without a byte, five minutes overall: a 25 MiB file over a slow uplink fits,
    /// a hung connection does not hold the user's turn hostage.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static let defaultTransport: Transport = { try await session.data(for: $0) }

    /// Downloads every attachment into `folder`, in order. Never throws: each failure
    /// is that entry's `failure`, so the turn always runs and Fin can tell the user.
    static func download(
        _ attachments: [MessageAttachment], into folder: String, transport: Transport = defaultTransport
    ) async -> [FetchedAttachment] {
        var results: [FetchedAttachment] = []
        let fileManager = FileManager.default
        for attachment in attachments {
            guard let raw = attachment.url, let url = URL(string: raw) else {
                results.append(.init(attachment: attachment, failure: "no download link"))
                continue
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    results.append(.init(attachment: attachment, failure: "HTTP \(status)"))
                    continue
                }
                try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let name = uniqueFileName(fileName(for: attachment)) {
                    fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent($0))
                }
                let path = (folder as NSString).appendingPathComponent(name)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                results.append(.init(attachment: attachment, path: path, bytes: data.count))
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                results.append(.init(attachment: attachment, failure: String(text.prefix(160))))
            }
        }
        return results
    }
}
