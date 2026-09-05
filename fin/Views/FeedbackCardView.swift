import SwiftUI

/// The dismissible "How's Fin doing?" card. Rendered by the agent console in the
/// transient-bar slot above the composer (where approvals and queued prompts
/// already appear) after a turn completes — `FeedbackPromptGate` decides how
/// rarely, the console decides when.
///
/// Nothing here sends by surprise: a rating only leaves the device on an explicit
/// Send, and when the sharing toggle is off the Send button is replaced by the
/// toggle itself, so consent is granted in-context or not at all.
struct FeedbackCardView: View {
    /// Invoked on any terminal interaction — sent, waved away, or silenced forever.
    let onDone: () -> Void

    @State private var rating: Int?
    @State private var comment = ""
    @State private var sharingEnabled = FeedbackSettings.shareRatings()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("How's Fin doing?")
                    .font(.caption.weight(.medium))
                ratingButton(value: 1, systemImage: "hand.thumbsup")
                ratingButton(value: -1, systemImage: "hand.thumbsdown")
                Spacer()
                Button("Don't Ask Again") {
                    FeedbackService.shared.gate.dismissForever()
                    onDone()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                Button {
                    onDone()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss feedback card")
            }

            if rating != nil {
                TextField("Anything to add? (optional)", text: $comment, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.caption)

                if sharingEnabled {
                    HStack {
                        Text("Sends your rating, comment, app version, and platform — nothing else.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Send") { send() }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                } else {
                    // Default-off consent, granted right here or not at all.
                    Toggle(isOn: $sharingEnabled) {
                        Text("Allow sharing ratings & comments to send this")
                            .font(.caption2)
                    }
                    .onChange(of: sharingEnabled) { _, newValue in
                        FeedbackSettings.setShareRatings(newValue)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func ratingButton(value: Int, systemImage: String) -> some View {
        Button {
            rating = value
        } label: {
            Image(systemName: rating == value ? systemImage + ".fill" : systemImage)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(rating == value ? Color.accentColor : Color.secondary)
        .accessibilityLabel(value > 0 ? "Thumbs up" : "Thumbs down")
    }

    private func send() {
        FeedbackService.shared.submitUserFeedback(
            rating: rating,
            comment: comment.isEmpty ? nil : comment
        )
        onDone()
    }
}
