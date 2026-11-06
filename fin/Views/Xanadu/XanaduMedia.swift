import AVFoundation
import Foundation
import ImageIO
import Speech
import UniformTypeIdentifiers

/// Voice notes for Xanadu's composer: AVAudioRecorder → AAC `.m4a`, then an
/// ON-DEVICE transcript (Speech, `requiresOnDeviceRecognition` whenever the
/// recognizer supports it) that travels with the file (docs/XANADU.md
/// decision 2: "Audio is transcribed on the device").
@MainActor
final class XanaduVoiceRecorder: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording(started: Date), transcribing, denied(String) }

    @Published private(set) var phase: Phase = .idle
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    var isRecording: Bool { if case .recording = phase { return true } else { return false } }

    func start() async {
        if case .denied = phase { phase = .idle }
        guard phase == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .denied("Fin needs microphone access to record a voice note — allow it in Settings.")
            return
        }
        #if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            phase = .denied("The microphone is busy.")
            return
        }
        #endif
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = AttachmentDraft.stagingURL(for: "voice-note-\(stamp).m4a", id: UUID())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard recorder.record() else { phase = .denied("Recording didn't start."); return }
            self.recorder = recorder
            fileURL = url
            phase = .recording(started: Date())
        } catch {
            phase = .denied("Recording didn't start.")
        }
    }

    /// Stops, transcribes, and hands back the staged voice note.
    func stop() async -> AttachmentDraft? {
        guard isRecording, let recorder, let url = fileURL else { return nil }
        recorder.stop()
        self.recorder = nil
        fileURL = nil
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        phase = .transcribing
        let transcript = await Self.transcribe(url)
        phase = .idle
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return nil }
        return AttachmentDraft(name: url.lastPathComponent, mime: "audio/mp4", size: size, fileURL: url,
                               transcript: transcript.map { String($0.prefix(MessageAttachment.maxTranscriptCharacters)) })
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        fileURL = nil
        phase = .idle
    }

    func clearDenial() { if case .denied = phase { phase = .idle } }

    /// nil when speech recognition is refused or unavailable — the note still sends.
    static func transcribe(_ url: URL) async -> String? {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if error != nil {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Photos for a model: vision brains take png / jpeg / gif / webp only (≤5 MiB
/// for the image part), so anything else — HEIC above all, the iPhone's
/// default — is re-encoded as JPEG, and big photos are scaled down.
enum XanaduImageNormalizer {
    static let modelReadableMIMEs: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    static let maxPixelSide = 2048
    static let targetBytes = 5 * 1024 * 1024

    /// (data, name, mime) ready to stage. Non-images pass through unchanged.
    static func normalize(data: Data, name: String, type: UTType?) -> (data: Data, name: String, mime: String) {
        let mime = type?.preferredMIMEType ?? AttachmentDraft.mime(forFileName: name)
        guard mime.hasPrefix("image/") else { return (data, name, mime) }
        if modelReadableMIMEs.contains(mime), data.count <= targetBytes { return (data, name, mime) }
        guard let jpeg = jpegData(from: data) else { return (data, name, mime) }
        let base = (name as NSString).deletingPathExtension
        return (jpeg, (base.isEmpty ? "photo" : base) + ".jpg", "image/jpeg")
    }

    static func jpegData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        for quality in [0.85, 0.7, 0.5] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if out.length <= targetBytes || quality == 0.5 { return out as Data }
        }
        return nil
    }
}

/// Local copies of attachments for QuickLook / share / open: the presigned
/// GET is downloaded once per key into Caches.
enum XanaduAttachmentCache {
    static func localURL(for attachment: MessageAttachment) -> URL {
        // The key's per-upload uuid segment (`…/<agentSlug>/<uuid>/<safeName>`):
        // stable across launches, unique per upload.
        let parts = attachment.key.split(separator: "/")
        let folder = MessageAttachment.safeName(parts.count >= 2 ? String(parts[parts.count - 2]) : attachment.key)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XanaduAttachments", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(MessageAttachment.safeName(attachment.name))
    }

    enum Failure: Error { case noURL, expired, network }

    static func download(_ attachment: MessageAttachment) async -> Result<URL, Failure> {
        let destination = localURL(for: attachment)
        if FileManager.default.fileExists(atPath: destination.path) { return .success(destination) }
        guard let url = attachment.url else { return .failure(.noURL) }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
                return .failure(status == 403 ? .expired : .network)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temp, to: destination)
            return .success(destination)
        } catch {
            return .failure(.network)
        }
    }
}
