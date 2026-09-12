import Foundation
import Intents
import UserNotifications

/// The one piece of communication-notification logic shared VERBATIM by the app
/// and the `fin-nse` Notification Service Extension (both targets compile this
/// file — see project.yml). Design: docs/CARPLAY-IMESSAGE-DESIGN.md §3.3 and §5.1.
///
/// A "communication notification" is an ordinary notification whose content has
/// been run through `updating(from:)` with a donated `INSendMessageIntent` whose
/// sender is an `INPerson`. iOS then treats it as a direct message: avatar,
/// breaks through Focus by default, and — with Settings > Notifications >
/// Announce Notifications > CarPlay on — Siri reads it aloud in the car and
/// takes a spoken reply. The app's local banners and the extension's rewritten
/// pushes go through the same functions here so they are indistinguishable.
///
/// Deliberately pure Foundation + Intents + UserNotifications: the extension is a
/// separate process with none of the app's state, so nothing in this file may
/// reference the app module (no `DeviceIdentity`, no SwiftData, no networking).
enum FinCommunicationNotification {
    /// "Fin replied" — carries a Reply text field.
    static let replyCategory = "fin.reply"
    /// "Fin needs your input" — carries an Answer text field; the push side
    /// additionally marks these time-sensitive.
    static let inputCategory = "fin.input"
    /// The text-input action identifiers under each category.
    static let replyActionIdentifier = "fin.reply.text"
    static let inputActionIdentifier = "fin.input.text"
    /// The avatar image (asset catalog `fin/Notifications/FinAvatar.xcassets`,
    /// bundled into BOTH targets so `INImage(named:)` resolves in each process).
    static let avatarAssetName = "FinAvatar"

    /// The categories are the message-style ones; anything else (the watchdog's
    /// attention pings, model-authored updates) stays a plain alert.
    static func isCommunicationCategory(_ identifier: String) -> Bool {
        identifier == replyCategory || identifier == inputCategory
    }

    // MARK: - Payload

    /// The `fin` dict a notification carries — the SAME shape for a local
    /// (on-device) banner's `userInfo` and a control-plane push's APNs payload
    /// (`lambda.py`). Every field is optional at THIS level: what a given caller
    /// requires (the app's deep link needs `agentID`; the extension needs
    /// `agentName`; a typed reply needs both) is decided by that caller.
    struct Payload: Equatable {
        var agentID: UUID?
        var agentName: String?
        /// The control-plane message id (`m-<uuid>`) a reply push answers; the
        /// app uses it to drop a push about a turn it already showed locally.
        var messageID: String?
        var originDeviceID8: String?
        /// The thread the push belongs to (`fin.threadId`, docs/THREADS.md §2)
        /// — what a typed reply joins and what the conversation groups by.
        var threadID: String?

        /// nil only when there is no `fin` dictionary at all. Blank strings read
        /// as absent; a malformed agent id reads as absent rather than failing
        /// the whole payload.
        static func parse(_ userInfo: [AnyHashable: Any]) -> Payload? {
            guard let fin = userInfo["fin"] as? [String: Any] else { return nil }
            func string(_ key: String) -> String? {
                guard let value = fin[key] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Payload(
                agentID: string("agentID").flatMap(UUID.init(uuidString:)),
                agentName: string("agentName"),
                messageID: string("messageId"),
                originDeviceID8: string("originDeviceID8"),
                threadID: string("threadId")
            )
        }

        /// The `fin` dict to put in a local banner's `userInfo`, mirroring what
        /// the control plane sends so both parse identically.
        static func userInfo(
            kind: String, agentID: UUID, agentName: String, messageID: String? = nil, threadID: String? = nil
        ) -> [String: Any] {
            var fin: [String: Any] = ["kind": kind, "agentID": agentID.uuidString, "agentName": agentName]
            if let messageID, !messageID.isEmpty { fin["messageId"] = messageID }
            if let threadID, !threadID.isEmpty { fin["threadId"] = threadID }
            return ["fin": fin]
        }
    }

    // MARK: - Intent

    /// The sender identity every Fin message carries. `conversationIdentifier`
    /// groups the thread: the Fin thread (`fin.threadId`) when the payload has
    /// one — the same `thread-id` the control plane's pushes group by — else one
    /// conversation per agent, keyed by the agent id when the payload has one
    /// and by name otherwise (the design's "agentID or agentName").
    /// `customIdentifier` is the agent id string so a spoken reply's recipient
    /// can be matched back to the agent even if two agents share a display name.
    static func sendMessageIntent(agentName: String, agentID: UUID?, body: String, threadID: String? = nil) -> INSendMessageIntent {
        let conversationID = conversationIdentifier(agentName: agentName, agentID: agentID, threadID: threadID)
        let sender = INPerson(
            personHandle: INPersonHandle(value: agentName, type: .unknown),
            nameComponents: nil,
            displayName: agentName,
            image: INImage(named: avatarAssetName),
            contactIdentifier: nil,
            customIdentifier: agentID?.uuidString ?? agentName,
            isMe: false,
            suggestionType: .none
        )
        return INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: body,
            speakableGroupName: nil,
            conversationIdentifier: conversationID,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
    }

    /// Donates the intent as an INCOMING interaction (Fin said this, the user did
    /// not) and returns the content re-rendered as a communication notification.
    /// Throws when the running process lacks the
    /// `com.apple.developer.usernotifications.communication` entitlement —
    /// callers fall back to the untouched content, which is exactly the
    /// pre-Phase-1 plain alert.
    /// Pure: the conversation a message groups under. Blank thread ids fall back.
    static func conversationIdentifier(agentName: String, agentID: UUID?, threadID: String?) -> String {
        if let threadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty { return threadID }
        return agentID?.uuidString ?? agentName
    }

    static func communicationContent(
        from content: UNNotificationContent, agentName: String, agentID: UUID?, threadID: String? = nil
    ) throws -> UNNotificationContent {
        let intent = sendMessageIntent(agentName: agentName, agentID: agentID, body: content.body, threadID: threadID)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try content.updating(from: intent)
    }

    /// What the extension does with a push: rewrite it when it is a Fin message
    /// (a communication category AND an `agentName` to attribute it to), leave
    /// anything else untouched. Pure in the "decide" half; `communicationContent`
    /// is the only side effect and any error degrades to the original content.
    static func rewrite(_ content: UNNotificationContent) -> UNNotificationContent {
        guard isCommunicationCategory(content.categoryIdentifier),
              let payload = Payload.parse(content.userInfo),
              let agentName = payload.agentName
        else { return content }
        return (try? communicationContent(
            from: content, agentName: agentName, agentID: payload.agentID, threadID: payload.threadID
        )) ?? content
    }
}
