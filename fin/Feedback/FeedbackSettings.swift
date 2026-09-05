import Foundation

/// Device-local opt-in state for the two "Help improve Fin" sharing channels.
///
/// UserDefaults only, never the synced store — same reasoning as
/// `CloudControlPlaneConfig`: consent to send telemetry off THIS device is a
/// per-device decision, and syncing it would silently opt in every other device
/// the user owns. Both toggles default OFF; until one is turned on, nothing the
/// feedback pipeline collects ever leaves the device.
enum FeedbackSettings {
    static let shareRatingsKey = "fin.feedback.shareRatings"
    static let shareActivityKey = "fin.feedback.shareActivity"

    /// Posted on every toggle write so the queue can react immediately —
    /// releasing held items on opt-in, discarding revoked ones on opt-out.
    static let changedNotification = Notification.Name("FeedbackSettingsChanged")

    /// Toggle (a): thumbs up/down ratings and the user's typed comments.
    static func shareRatings(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: shareRatingsKey)
    }

    /// Toggle (b): redacted activity summaries (trajectory digests) — counts and
    /// durations about finished conversations, never message text.
    static func shareActivity(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: shareActivityKey)
    }

    static func setShareRatings(_ value: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: shareRatingsKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func setShareActivity(_ value: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: shareActivityKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
