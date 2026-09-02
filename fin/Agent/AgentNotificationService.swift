import Foundation
import UserNotifications
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Local notification when an agent finishes a turn while the user isn't looking —
/// the screen locked mid-run, the app is backgrounded, or another window has focus.
///
/// Follows PocketDJ's push architecture (PushRegistrationService + NotificationRouter),
/// adapted to what Fin actually is: the agent runs on this device, so there's no server
/// and no APNs — a local notification is the whole delivery path, and the registration
/// and routing halves collapse into one small service. Authorization is asked in
/// context — the first time a prompt is submitted, never at launch.
@MainActor
final class AgentNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotificationService()

    /// The notification shows this many characters of the agent's reply.
    private nonisolated static let previewLength = 140

    private var authorizationRequested = false

    /// A tap on any agent notification routes here with the agent to open plus
    /// the `DeviceIdentity.short` of the device the signal originated on (nil
    /// when an old push didn't carry it); `FinApp` wires it to
    /// `SessionManager.pendingAgentOpen`.
    var onOpenAgent: ((_ agentID: UUID, _ originDeviceID8: String?) -> Void)?

    /// Persists a cross-device `AgentSignal` alongside every local banner; `FinApp`
    /// wires it to an insert on the synced store. Runs BEFORE the is-app-active
    /// gate below — the other devices should hear about a finished turn whether or
    /// not this one is being looked at — and its preview is redacted and capped
    /// here, in one place, because unlike the local banner it leaves the device.
    var persistSignal: ((AgentSignalKind, _ agentID: UUID, _ agentName: String, _ preview: String) -> Void)?

    /// The synced signal preview: flattened, `MemoryRedactor`-scrubbed, and
    /// hard-capped at 140 characters including the ellipsis.
    nonisolated static func signalPreview(of text: String) -> String {
        let flattened = MemoryRedactor.redact(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > previewLength else { return flattened }
        return String(flattened.prefix(previewLength - 1)) + "\u{2026}"
    }

    private func recordSignal(_ kind: AgentSignalKind, agentID: UUID, agentName: String, text: String) {
        persistSignal?(kind, agentID, agentName, Self.signalPreview(of: text))
    }

    /// Install as the notification-center delegate (finApp init).
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask once, at the moment it first matters: a prompt was just submitted, so a
    /// finished-while-away notification is now a real possibility.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Posts "the agent has a response" — but only when the user isn't actively looking
    /// at the app; a banner over the visible conversation would just be noise.
    func notifyTurnFinished(agentName: String, reply: String, agentID: UUID) {
        recordSignal(.turnFinished, agentID: agentID, agentName: agentName, text: reply)
        guard !isAppActive else { return }

        let content = UNMutableNotificationContent()
        content.title = agentName.isEmpty ? "Agent" : agentName
        content.body = Self.preview(of: reply)
        content.sound = .default
        // Mirrors PocketDJ's namespaced payload so a tap can route to the right
        // conversation once deep-linking is wired.
        content.userInfo = ["fin": ["kind": "agentReply", "agentID": agentID.uuidString]]

        let request = UNNotificationRequest(
            identifier: "agent-reply-\(agentID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Posts "the agent needs an answer from you" — the unattended counterpart of a
    /// `request_input` call or an approval the heartbeat is parked on.
    func notifyInputRequested(agentName: String, question: String, agentID: UUID) {
        recordSignal(.inputRequested, agentID: agentID, agentName: agentName, text: question)
        guard !isAppActive else { return }

        let content = UNMutableNotificationContent()
        content.title = agentName.isEmpty ? "Agent" : agentName
        content.body = Self.preview(of: question)
        content.sound = .default
        content.userInfo = ["fin": ["kind": "agentInput", "agentID": agentID.uuidString]]

        let request = UNNotificationRequest(
            identifier: "agent-input-\(agentID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Posts "the agent may need a look" — the watchdog's wedge ping, softer than a
    /// request for input: nothing is blocked on the user, but ten-plus minutes of
    /// continuous thinking is worth a glance. `signalKind` lets the monitor-pause
    /// call sites label their cross-device signal `monitoringPaused` while sharing
    /// this local banner path.
    func notifyAttention(
        agentName: String, message: String, agentID: UUID,
        signalKind: AgentSignalKind = .attention
    ) {
        recordSignal(signalKind, agentID: agentID, agentName: agentName, text: message)
        guard !isAppActive else { return }

        let content = UNMutableNotificationContent()
        content.title = agentName.isEmpty ? "Agent" : agentName
        content.body = Self.preview(of: message)
        content.sound = .default
        content.userInfo = ["fin": ["kind": "agentAttention", "agentID": agentID.uuidString]]

        let request = UNNotificationRequest(
            identifier: "agent-attention-\(agentID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func preview(of reply: String) -> String {
        let flattened = reply
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > previewLength else { return flattened }
        return String(flattened.prefix(previewLength)) + "\u{2026}"
    }

    private var isAppActive: Bool {
        #if os(iOS) || os(visionOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground banners stay visible (matches PocketDJ's router) — relevant on macOS,
    /// where "app running" and "user looking at it" are routinely different things.
    ///
    /// MainActor-isolated ON PURPOSE (both delegate methods): the async variants
    /// otherwise resume on the concurrency pool, and UIKit invokes its internal
    /// completion — which touches state-restoration/snapshot machinery — on that
    /// resume thread. Live TestFlight crash: SIGABRT in UIApplication's snapshot
    /// assertion every time a notification was tapped (symbolicated to the didReceive
    /// closure). Isolation here makes UIKit's completion run on the main thread.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap deep-links to the agent named in the payload — either a local
    /// notification's own "fin" payload, or a cross-device CloudKit push whose
    /// query-notification fields carry the agent id and its origin device (see
    /// `AgentSignalSubscriber`). A "fin" payload carries no origin field because
    /// it doesn't need one: local banners are minted by THIS device, so the
    /// origin is the local device by construction.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let fin = userInfo["fin"] as? [String: Any],
           let idString = fin["agentID"] as? String,
           let agentID = UUID(uuidString: idString) {
            onOpenAgent?(agentID, DeviceIdentity.short)
        } else if let target = AgentSignalSubscriber.openTarget(fromPushUserInfo: userInfo) {
            onOpenAgent?(target.agentID, target.originDeviceID8)
        }
    }
}
