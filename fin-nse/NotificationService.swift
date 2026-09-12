import UserNotifications

/// Fin's Notification Service Extension (docs/CARPLAY-IMESSAGE-DESIGN.md §3.3
/// step 3). The control plane sends every reply / needs-input push with
/// `mutable-content: 1`, a `fin.reply` or `fin.input` category, and a `fin`
/// dict carrying `agentName` (+ `agentID`, `messageId`). This process rewrites
/// that push into a communication notification — `INSendMessageIntent` with an
/// `INPerson` "Fin" sender, donated as an incoming interaction — so it shows
/// with Fin's avatar and Siri announces it in CarPlay / on AirPods.
///
/// It needs nothing from the app: no app group, no token, no network. Every
/// failure path hands back the untouched content, which is the plain alert the
/// user got before Phase 1. All of the logic lives in the shared
/// `FinCommunicationNotification` (fin/Notifications/, compiled into both the
/// app and this extension) so the app's local banners are decorated identically.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttempt = request.content
        contentHandler(FinCommunicationNotification.rewrite(request.content))
    }

    /// The system is about to kill the extension (30s budget) — deliver whatever
    /// we have rather than nothing. Rewriting is synchronous above, so this only
    /// fires if the process was starved; the original content is always a valid
    /// answer.
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }
}
