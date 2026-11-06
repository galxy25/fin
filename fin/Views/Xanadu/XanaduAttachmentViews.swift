import AVFoundation
import QuickLook
import SwiftUI
#if os(macOS)
import AppKit
import WebKit
#else
import SafariServices
#endif

/// The files on one transcript item: image thumbnails (from the presigned
/// `url`), an audio player with its transcript, file rows that open in
/// QuickLook — every attachment a link forward to its content.
struct XanaduAttachmentList: View {
    let attachments: [MessageAttachment]
    /// A presigned GET lives ≤ 1 h: a 403 means "refetch the thread detail".
    var onExpired: () -> Void = {}

    @State private var previewURL: URL?
    @State private var loadingKey: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                switch attachment.kind {
                case .image:
                    XanaduImageAttachment(attachment: attachment, onExpired: onExpired) { open(attachment) }
                case .audio:
                    XanaduAudioAttachment(attachment: attachment)
                case .video, .pdf, .file:
                    fileRow(attachment)
                }
            }
            if let problem {
                Text(problem).font(.caption2).foregroundStyle(.orange)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func fileRow(_ attachment: MessageAttachment) -> some View {
        Button { open(attachment) } label: {
            HStack(spacing: 8) {
                Image(systemName: attachment.systemImage)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).font(.callout).lineLimit(1)
                    Text(attachment.sizeLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if loadingKey == attachment.key {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu(attachment) }
        .accessibilityIdentifier("xanaduAttachmentFile")
    }

    @ViewBuilder
    private func menu(_ attachment: MessageAttachment) -> some View {
        Button { open(attachment) } label: { Label("Preview", systemImage: "eye") }
        if let url = attachment.url {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        #if os(macOS)
        Button {
            Task {
                if case .success(let local) = await XanaduAttachmentCache.download(attachment) {
                    NSWorkspace.shared.open(local)
                }
            }
        } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        #endif
    }

    private func open(_ attachment: MessageAttachment) {
        guard loadingKey == nil else { return }
        loadingKey = attachment.key
        problem = nil
        Task {
            defer { loadingKey = nil }
            switch await XanaduAttachmentCache.download(attachment) {
            case .success(let local): previewURL = local
            case .failure(.expired):
                problem = "That link expired — refreshing."
                onExpired()
            case .failure: problem = "Couldn't download \(attachment.name)."
            }
        }
    }
}

private struct XanaduImageAttachment: View {
    let attachment: MessageAttachment
    let onExpired: () -> Void
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            AsyncImage(url: attachment.url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label(attachment.name, systemImage: "photo")
                        .font(.caption)
                        .padding(10)
                        .task { onExpired() }
                default:
                    ProgressView().frame(width: 120, height: 90)
                }
            }
            .frame(maxWidth: 280, maxHeight: 240, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = attachment.url {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityIdentifier("xanaduAttachmentImage")
    }
}

/// Play/pause over the presigned URL, the on-device transcript beneath.
private struct XanaduAudioAttachment: View {
    let attachment: MessageAttachment
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(attachment.url == nil)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).font(.callout).lineLimit(1)
                    Text(attachment.sizeLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let transcript = attachment.transcript {
                Text("\u{201C}\(transcript)\u{201D}")
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item == player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
        }
        .onDisappear { player?.pause(); isPlaying = false }
        .accessibilityIdentifier("xanaduAttachmentAudio")
    }

    private func toggle() {
        if player == nil, let url = attachment.url { player = AVPlayer(url: url) }
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
}

// MARK: - The in-app browser for links in a message

/// A link tapped in Xanadu opens here, inside the app — Safari's view
/// controller on iPhone / iPad / Vision Pro, a web view sheet on the Mac.
struct XanaduWebLink: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

#if os(macOS)
struct XanaduLinkBrowser: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.host ?? url.absoluteString).font(.callout).lineLimit(1)
                Spacer()
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            XanaduWebView(url: url)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct XanaduWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct XanaduLinkBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
