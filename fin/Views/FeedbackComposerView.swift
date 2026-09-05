import SwiftUI

/// The always-available way to volunteer feedback: reached from the "Help improve
/// Fin" settings section, no throttling — unlike the console card, which asks at
/// most once a week. Same consent rule though: Send requires the ratings toggle,
/// offered inline when it's off, so a volunteered comment is still an explicit
/// opt-in and never an implicit one.
struct FeedbackComposerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rating: Int?
    @State private var comment = ""
    @State private var sharingEnabled = FeedbackSettings.shareRatings()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 24) {
                        ratingButton(value: 1, systemImage: "hand.thumbsup", label: "Thumbs up")
                        ratingButton(value: -1, systemImage: "hand.thumbsdown", label: "Thumbs down")
                        Spacer()
                    }
                } header: {
                    Text("How's Fin doing?")
                }
                Section {
                    TextField("What's working? What isn't? (optional)", text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Sends your rating and comment with the app version and "
                        + "platform — nothing else. Secret-shaped text in comments is "
                        + "redacted before anything is stored.")
                }
                if !sharingEnabled {
                    Section {
                        Toggle("Share Ratings & Comments", isOn: $sharingEnabled)
                            .onChange(of: sharingEnabled) { _, newValue in
                                FeedbackSettings.setShareRatings(newValue)
                            }
                    } footer: {
                        Text("Off by default — turning this on is what allows feedback "
                            + "to leave this device.")
                    }
                }
            }
            .navigationTitle("Send Feedback")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        FeedbackService.shared.submitUserFeedback(
                            rating: rating,
                            comment: comment.isEmpty ? nil : comment
                        )
                        dismiss()
                    }
                    .disabled(!sharingEnabled || (rating == nil && comment.isEmpty))
                }
            }
        }
    }

    private func ratingButton(value: Int, systemImage: String, label: String) -> some View {
        Button {
            rating = rating == value ? nil : value
        } label: {
            Image(systemName: rating == value ? systemImage + ".fill" : systemImage)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(rating == value ? Color.accentColor : Color.secondary)
        .accessibilityLabel(label)
    }
}
