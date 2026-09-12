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
    var onOpenAgent: ((_ agentID: UUID, _ originDeviceID8: String?, _ threadID: String?) -> Void)?

    /// docs/THREADS.md §2: the thread of the control-plane message this device
    /// is currently answering for an agent (`AppSiteClient` sets it at claim,
    /// clears it at the answered ack). A local banner posted while it is set
    /// groups under the thread — the same `thread-id` the control plane's
    /// pushes use — so the Lock Screen shows one request as one group
    /// whichever body answered.
    private(set) var activeThreads: [UUID: String] = [:]

    func setActiveThread(_ threadID: String?, for agentID: UUID) {
        if let threadID, !threadID.isEmpty { activeThreads[agentID] = threadID } else { activeThreads.removeValue(forKey: agentID) }
    }

    /// The `thread-id` a local banner for `agentID` groups under. Pure over
    /// the table so the fallback is testable.
    nonisolated static func threadIdentifier(for agentID: UUID, activeThreads: [UUID: String]) -> String {
        activeThreads[agentID] ?? agentID.uuidString
    }

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

    /// Delivers a typed notification reply (`UNTextInputNotificationResponse`) to
    /// the agent the notification named; returns whether it was accepted. The
    /// production value is `FinVoiceIntentCore.deliver` with `source: "app"` —
    /// the same `/messages` path a Siri reply or the in-app composer takes.
    /// Injectable so the response handling is testable without a control plane.
    var replyDeliverer: (_ agentID: UUID, _ agentName: String, _ text: String, _ threadID: String?) async -> Bool = { agentID, agentName, text, threadID in
        await FinVoiceIntentCore.deliver(agentID: agentID, agentName: agentName, text: text, source: "app", threadID: threadID).delivered
    }

    /// Install as the notification-center delegate (finApp init) and register
    /// the message-style categories (`fin.reply` / `fin.input`) whose text-input
    /// actions put a Reply / Answer field on every Fin notification — remote
    /// pushes carry the category from the control plane, local banners set it
    /// here; both resolve against this one registration.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.notificationCategories)
    }

    /// The two communication categories, each with exactly one text-input
    /// action (design §3.3: "a `UNNotificationCategory("fin.reply")` with a
    /// `UNTextInputNotificationAction`"). Pure — asserted by
    /// `CommunicationNotificationTests`.
    nonisolated static var notificationCategories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: FinCommunicationNotification.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let answer = UNTextInputNotificationAction(
            identifier: FinCommunicationNotification.inputActionIdentifier,
            title: "Answer",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Your answer"
        )
        return [
            UNNotificationCategory(
                identifier: FinCommunicationNotification.replyCategory,
                actions: [reply], intentIdentifiers: ["INSendMessageIntent"], options: []
            ),
            UNNotificationCategory(
                identifier: FinCommunicationNotification.inputCategory,
                actions: [answer], intentIdentifiers: ["INSendMessageIntent"], options: []
            ),
        ]
    }

    // MARK: - Foreground dedupe of control-plane reply pushes

    /// Message ids of turns THIS device hosted and acked as answered
    /// (`AppSiteClient.beat`). The control plane pushes a `fin.reply` to every
    /// device on that ack, this one included; `willPresent` drops the echo. A
    /// small ring — the window only needs to cover the seconds between the ack
    /// and its push arriving.
    private(set) var recentlySurfacedMessageIDs: [String] = []
    static let recentlySurfacedLimit = 64

    func markSurfacedLocally(messageID: String) {
        guard !messageID.isEmpty else { return }
        recentlySurfacedMessageIDs.removeAll { $0 == messageID }
        recentlySurfacedMessageIDs.append(messageID)
        if recentlySurfacedMessageIDs.count > Self.recentlySurfacedLimit {
            recentlySurfacedMessageIDs.removeFirst(recentlySurfacedMessageIDs.count - Self.recentlySurfacedLimit)
        }
    }

    /// A foregrounded app hides a `fin.reply` push whose `messageId` names a turn
    /// it already surfaced itself; every other notification presents. Only the
    /// reply category — a `fin.input` for a question this device is parked on
    /// is still worth a banner, and attention/update pushes carry no message id.
    nonisolated static func shouldSuppressForeground(
        category: String, userInfo: [AnyHashable: Any], surfacedMessageIDs: [String]
    ) -> Bool {
        guard category == FinCommunicationNotification.replyCategory,
              let messageID = FinCommunicationNotification.Payload.parse(userInfo)?.messageID
        else { return false }
        return surfacedMessageIDs.contains(messageID)
    }

    /// Builds one message-style local banner: category set, payload carrying the
    /// agent name so a typed reply can be addressed, and the same
    /// `INSendMessageIntent` donation the extension performs on a remote push
    /// (so app-hosted and remote replies look identical). The donation degrades
    /// to the plain content when the entitlement is missing or the update throws.
    private func communicationRequest(
        identifier: String, category: String, kind: String,
        agentName: String, body: String, agentID: UUID
    ) -> UNNotificationRequest {
        let name = agentName.isEmpty ? "Agent" : agentName
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = Self.preview(of: body)
        content.sound = .default
        content.categoryIdentifier = category
        // Grouped by the thread being answered when there is one, else the
        // agent — the same rule the control plane applies to its pushes.
        let threadID = activeThreads[agentID]
        content.threadIdentifier = Self.threadIdentifier(for: agentID, activeThreads: activeThreads)
        content.userInfo = FinCommunicationNotification.Payload.userInfo(
            kind: kind, agentID: agentID, agentName: name, threadID: threadID
        )
        let decorated = (try? FinCommunicationNotification.communicationContent(
            from: content, agentName: name, agentID: agentID, threadID: threadID
        )) ?? content
        return UNNotificationRequest(identifier: identifier, content: decorated, trigger: nil)
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

        // A message from "Fin": fin.reply category (Reply field) + the same
        // INSendMessageIntent donation a control-plane push gets in fin-nse, so
        // Announce reads an app-hosted reply aloud exactly like a remote one.
        // The "fin" payload mirrors PocketDJ's namespaced shape so a tap routes
        // to the right conversation.
        let request = communicationRequest(
            identifier: "agent-reply-\(agentID.uuidString)",
            category: FinCommunicationNotification.replyCategory, kind: "agentReply",
            agentName: agentName, body: reply, agentID: agentID
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Posts "the agent needs an answer from you" — the unattended counterpart of a
    /// `request_input` call or an approval the heartbeat is parked on.
    func notifyInputRequested(agentName: String, question: String, agentID: UUID) {
        recordSignal(.inputRequested, agentID: agentID, agentName: agentName, text: question)
        guard !isAppActive else { return }

        // fin.input: an Answer field, and the same message-style donation.
        let request = communicationRequest(
            identifier: "agent-input-\(agentID.uuidString)",
            category: FinCommunicationNotification.inputCategory, kind: "agentInput",
            agentName: agentName, body: question, agentID: agentID
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

    /// Posts a proactively-social update the AGENT chose to send via its `notify` tool —
    /// the app-local half of Fin's copilot job. Unlike the harness-fired banners above,
    /// the model authored both the headline and the message, so the banner shows the
    /// model's `title` verbatim (falling back to the agent's name when it's blank) rather
    /// than always leading with the agent name. Records an `.attention` cross-device
    /// signal so the owner's other devices hear it too, then — like every banner here —
    /// only surfaces the local alert when the user isn't already looking at the app.
    ///
    /// Returns the REAL outcome — `AgentNotifyOutcome` (shared with the daemon's own
    /// `onNotify` hook, `FinAgentCore/AgentTurnEngine.swift`) — instead of assuming the
    /// banner posted. `.delivered` only when `UNUserNotificationCenter.add` actually
    /// confirms scheduling it; `.failed` when it's not authorized or the add call threw;
    /// `.queued` when the app is foregrounded, so no banner was even attempted (the owner
    /// may already be looking, but that's not a confirmed push, so callers must not call
    /// it "sent").
    func notifyAgentUpdate(
        agentName: String, title: String, body: String, agentID: UUID
    ) async -> AgentNotifyOutcome {
        recordSignal(.attention, agentID: agentID, agentName: agentName, text: body)
        guard !isAppActive else { return .queued }

        switch await currentAuthorizationStatus() {
        case .authorized, .provisional:
            break
        #if os(iOS) || os(visionOS)
        case .ephemeral:
            // App-Clip-only status; iOS/visionOS-only in the SDK (unavailable on macOS),
            // hence the platform guard rather than an unconditional case.
            break
        #endif
        case .denied, .notDetermined:
            return .failed
        @unknown default:
            return .failed
        }

        let headline = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = headline.isEmpty ? (agentName.isEmpty ? "Agent" : agentName) : headline
        content.body = Self.preview(of: body)
        content.sound = .default
        content.userInfo = ["fin": ["kind": "agentUpdate", "agentID": agentID.uuidString]]

        let request = UNNotificationRequest(
            identifier: "agent-update-\(agentID.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await post(request)
            return .delivered
        } catch {
            return .failed
        }
    }

    /// Reads the live OS authorization status, unless a test has forced one — real
    /// device/notification-center authorization is unreachable (and unstable) from an
    /// XCTest host, so `notifyAgentUpdate`'s tests never depend on it.
    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        #if DEBUG
        if let authorizationOverrideForTesting { return authorizationOverrideForTesting }
        #endif
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Schedules the banner with the OS, unless a test has substituted its own sink —
    /// same reasoning as `currentAuthorizationStatus`.
    private func post(_ request: UNNotificationRequest) async throws {
        #if DEBUG
        if let postOverrideForTesting {
            try await postOverrideForTesting(request)
            return
        }
        #endif
        try await UNUserNotificationCenter.current().add(request)
    }

    nonisolated static func preview(of reply: String) -> String {
        let flattened = reply
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > previewLength else { return flattened }
        return String(flattened.prefix(previewLength)) + "\u{2026}"
    }

    private var isAppActive: Bool {
        #if DEBUG
        if let isAppActiveOverrideForTesting { return isAppActiveOverrideForTesting }
        #endif
        #if os(iOS) || os(visionOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #else
        return true
        #endif
    }

    #if DEBUG
    /// Test seam for `notifyAgentUpdate`'s outcome: real app-active state and real OS
    /// notification authorization are both unreachable/unstable from an XCTest host (no
    /// permission is ever granted to a test runner, and "active" varies with how it was
    /// launched), so tests force them here instead of asserting against live system state.
    var isAppActiveOverrideForTesting: Bool?
    var authorizationOverrideForTesting: UNAuthorizationStatus?
    var postOverrideForTesting: ((UNNotificationRequest) async throws -> Void)?

    func resetTestOverrides() {
        isAppActiveOverrideForTesting = nil
        authorizationOverrideForTesting = nil
        postOverrideForTesting = nil
    }
    #endif

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
    ///
    /// One exception: a control-plane `fin.reply` push about a turn THIS device
    /// hosted and already showed (`markSurfacedLocally`) is dropped — the user is
    /// looking at that very reply.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if Self.shouldSuppressForeground(
            category: content.categoryIdentifier, userInfo: content.userInfo,
            surfacedMessageIDs: recentlySurfacedMessageIDs
        ) {
            return []
        }
        return [.banner, .list, .sound]
    }

    /// A parsed "fin" payload with the one field every consumer needs — the
    /// agent id — guaranteed present. `agentName` / `messageID` ride along for
    /// typed replies and reply-push dedupe; see
    /// `FinCommunicationNotification.Payload` for the wire shape.
    struct FinPayload: Equatable {
        var agentID: UUID
        var originDeviceID8: String?
        var agentName: String?
        var messageID: String?
        /// `fin.threadId` (docs/THREADS.md §2): a typed reply joins this
        /// thread; a tap opens the console on it.
        var threadID: String?
    }

    /// Parses a "fin" notification payload — `{"agentID": "<uuid>",
    /// "originDeviceID8"?: "<8 hex>", "agentName"?, "messageId"?}` — used by
    /// both a local (on-device) banner's `userInfo` and a control-plane push's
    /// APNs payload (`lambda.py`). `originDeviceID8` is absent for a local
    /// banner (minted by THIS device, so the origin is local by construction)
    /// and present for a daemon push (the daemon isn't the receiving device, so
    /// it must say so explicitly) — the caller decides what an absent origin
    /// means, this just reports what the payload said. nil without a parseable
    /// agent id.
    nonisolated static func parseFinPayload(_ userInfo: [AnyHashable: Any]) -> FinPayload? {
        guard let payload = FinCommunicationNotification.Payload.parse(userInfo),
              let agentID = payload.agentID
        else { return nil }
        return FinPayload(
            agentID: agentID, originDeviceID8: payload.originDeviceID8,
            agentName: payload.agentName, messageID: payload.messageID, threadID: payload.threadID
        )
    }

    /// Where a typed notification reply goes: the agent the payload names, by id
    /// AND name (the control plane addresses messages by name; the legacy inbox
    /// by id). nil when either is missing — a reply must never be guessed onto
    /// the wrong agent. Pure.
    nonisolated static func replyTarget(from userInfo: [AnyHashable: Any]) -> (agentID: UUID, agentName: String)? {
        guard let payload = parseFinPayload(userInfo), let name = payload.agentName else { return nil }
        return (payload.agentID, name)
    }

    /// A tap deep-links to the agent named in the payload — either a "fin"
    /// payload (a local notification, or a daemon push relayed through the
    /// control plane) or a cross-device CloudKit push whose query-notification
    /// fields carry the agent id and its origin device (see
    /// `AgentSignalSubscriber`). A "fin" payload with no origin field means a
    /// local banner: minted by THIS device, so the origin is the local device
    /// by construction.
    ///
    /// A reply typed into the notification's text field (`fin.reply` / `fin.input`
    /// actions) is delivered instead of deep-linked: it goes to the named agent
    /// through `replyDeliverer` (`/messages`, `source: "app"`), and the app is
    /// not opened — that is the point of replying from the Lock Screen, Watch,
    /// or Notification Center.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let typed = response as? UNTextInputNotificationResponse {
            await handleTypedReply(typed.userText, userInfo: userInfo)
            return
        }
        if let parsed = Self.parseFinPayload(userInfo) {
            onOpenAgent?(parsed.agentID, parsed.originDeviceID8 ?? DeviceIdentity.short, parsed.threadID)
        } else if let target = AgentSignalSubscriber.openTarget(fromPushUserInfo: userInfo) {
            onOpenAgent?(target.agentID, target.originDeviceID8, nil)
        }
    }

    /// Delivers a typed reply, or — when it can't be addressed or the send
    /// fails — says so with a plain local banner rather than silently eating
    /// the user's words. Returns whether delivery was attempted and succeeded.
    @discardableResult
    func handleTypedReply(_ text: String, userInfo: [AnyHashable: Any]) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let target = Self.replyTarget(from: userInfo) else {
            postReplyFailure(agentName: nil)
            return false
        }
        // The reply joins the thread the push named (docs/THREADS.md §2).
        let threadID = Self.parseFinPayload(userInfo)?.threadID
        let delivered = await replyDeliverer(target.agentID, target.agentName, trimmed, threadID)
        if !delivered { postReplyFailure(agentName: target.agentName) }
        return delivered
    }

    private func postReplyFailure(agentName: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.body = agentName.map { "Couldn't reach \($0) — open Fin and try again." }
            ?? "Couldn't tell which agent to reply to — open Fin and try again."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "agent-reply-failed", content: content, trigger: nil)
        )
    }
}
