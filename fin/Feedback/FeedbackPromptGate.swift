import Foundation

/// Throttle for the "How's Fin doing?" card, so asking stays rare enough to keep
/// answering worthwhile. The card may appear only when ALL of these hold:
///
///   - at least `minimumConversations` agent conversations have completed on this
///     device (a brand-new user has nothing to rate yet),
///   - at least `promptInterval` since the card last appeared — shown-and-dismissed
///     counts as appeared, so dismissing buys the same quiet week answering does,
///   - the user hasn't permanently dismissed it ("Don't Ask Again").
///
/// "User is present" is the caller's half of the contract: the console checks the
/// gate only on a turn that just completed on screen.
///
/// Purely device-local UserDefaults state — this gate never syncs and sends
/// nothing anywhere; it only decides whether a card renders.
struct FeedbackPromptGate {
    static let completedConversationsKey = "fin.feedback.completedConversations"
    static let lastPromptedAtKey = "fin.feedback.lastPromptedAt"
    static let promptDismissedForeverKey = "fin.feedback.promptDismissedForever"

    static let minimumConversations = 3
    static let promptInterval: TimeInterval = 7 * 86_400

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var completedConversations: Int {
        defaults.integer(forKey: Self.completedConversationsKey)
    }

    var isPermanentlyDismissed: Bool {
        defaults.bool(forKey: Self.promptDismissedForeverKey)
    }

    func shouldPrompt(now: Date = Date()) -> Bool {
        guard !isPermanentlyDismissed else { return false }
        guard completedConversations >= Self.minimumConversations else { return false }
        if let last = defaults.object(forKey: Self.lastPromptedAtKey) as? Date,
           now.timeIntervalSince(last) < Self.promptInterval {
            return false
        }
        return true
    }

    /// One finished conversation (as detected by the trajectory sweep or an
    /// explicit clear). Counting is unconditional and local — it feeds only this
    /// gate, not the wire.
    func noteConversationCompleted() {
        defaults.set(completedConversations + 1, forKey: Self.completedConversationsKey)
    }

    /// The card was shown — whether it was answered or waved away, the 7-day
    /// clock restarts from here.
    func notePrompted(now: Date = Date()) {
        defaults.set(now, forKey: Self.lastPromptedAtKey)
    }

    /// "Don't Ask Again": the card never auto-appears again on this device. The
    /// settings row remains the always-available way to volunteer feedback.
    func dismissForever() {
        defaults.set(true, forKey: Self.promptDismissedForeverKey)
    }
}
