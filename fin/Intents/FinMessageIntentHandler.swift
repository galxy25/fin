import Foundation
import Intents

/// SiriKit's Messaging domain, handled IN the app (no Intents extension):
/// `FinAppDelegate.application(_:handlerFor:)` returns this for every
/// `INSendMessageIntent`. Two things arrive here (design §3.3 step 5, §5.2):
///
/// 1. Announce Notifications' spoken reply — Siri read a Fin communication
///    notification aloud in the car, the driver said "Reply: ship it", and Siri
///    hands the text to the app that donated the notification's intent. The
///    recipient Siri passes is the notification's sender `INPerson` (display
///    name = agent name, `customIdentifier` = agent id).
/// 2. "Send a message to Fin using Fin" — SiriKit's generic messaging phrasing.
///
/// Both land in the SAME `FinVoiceIntentCore.deliver` path the voice App
/// Intents use, with `source: "voice"`. The resolution rules are pure and
/// injected so they are testable without a `ModelContainer`, Siri, or the
/// network (`finTests/CommunicationNotificationTests.swift`).
final class FinMessageIntentHandler: NSObject, INSendMessageIntentHandling {
    /// The user's agents, `(id, name)` — the same candidate set
    /// `FinVoiceIntentCore.prepare` resolves against.
    typealias AgentsProvider = @MainActor () -> [(id: UUID, name: String)]
    /// Readies a message for the agent Siri named (nil → the default target).
    typealias Prepare = @MainActor (_ message: String, _ requestedAgent: String?) -> FinVoiceIntentCore.Prepared
    /// Sends it; returns whether delivery succeeded.
    typealias Deliver = (_ agentID: UUID, _ agentName: String, _ text: String) async -> Bool

    private let agents: AgentsProvider
    private let prepare: Prepare
    private let deliver: Deliver

    /// Production wiring: SwiftData through `FinSharedState`, delivery through
    /// the control plane (or the legacy inbox) as "voice".
    override convenience init() {
        self.init(
            agents: { FinVoiceIntentCore.candidateAgents(container: FinSharedState.modelContainer) },
            prepare: { message, requested in
                FinVoiceIntentCore.prepare(
                    message: message, container: FinSharedState.modelContainer,
                    preferringAgent: requested
                )
            },
            deliver: { agentID, agentName, text in
                await FinVoiceIntentCore.deliver(
                    agentID: agentID, agentName: agentName, text: text, source: "voice"
                ).delivered
            }
        )
    }

    init(agents: @escaping AgentsProvider, prepare: @escaping Prepare, deliver: @escaping Deliver) {
        self.agents = agents
        self.prepare = prepare
        self.deliver = deliver
    }

    // MARK: - Pure resolution rules

    /// The name (or agent-id string) Siri asked for, from the intent's recipient
    /// list. `customIdentifier` wins — it is the agent id the donated sender
    /// carried, unambiguous even when two agents share a display name — then
    /// the display name, then the raw handle. nil when Siri named no one.
    static func requestedAgent(from recipients: [INPerson]?) -> String? {
        guard let first = recipients?.first else { return nil }
        for candidate in [first.customIdentifier, first.displayName, first.personHandle?.value] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Which agent a message is for: an explicit match on what Siri named, else
    /// the voice intents' default (the agent called "Fin", else the first).
    /// nil only when the user has no agents at all.
    static func resolveRecipient(requested: String?, agents: [(id: UUID, name: String)]) -> (id: UUID, name: String)? {
        if let index = FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: requested) {
            return agents[index]
        }
        guard let index = FinVoiceIntentCore.preferredTargetIndex(cloudAgentNames: agents.map(\.name)) else {
            return nil
        }
        return agents[index]
    }

    /// The `INPerson` a resolved agent is reported back to Siri as — the same
    /// identity the notification donation used, so the round trip is consistent.
    static func person(for agent: (id: UUID, name: String)) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: agent.name, type: .unknown),
            nameComponents: nil,
            displayName: agent.name,
            image: INImage(named: FinCommunicationNotification.avatarAssetName),
            contactIdentifier: nil,
            customIdentifier: agent.id.uuidString,
            isMe: false,
            suggestionType: .none
        )
    }

    // MARK: - INSendMessageIntentHandling

    func resolveRecipients(
        for intent: INSendMessageIntent,
        with completion: @escaping ([INSendMessageRecipientResolutionResult]) -> Void
    ) {
        let requested = Self.requestedAgent(from: intent.recipients)
        Task { @MainActor in
            guard let agent = Self.resolveRecipient(requested: requested, agents: agents()) else {
                // No agent set up yet — the closest SiriKit reason: nothing to
                // deliver to until the app has been opened and one added.
                completion([.unsupported(forReason: .noAccount)])
                return
            }
            completion([.success(with: Self.person(for: agent))])
        }
    }

    /// The message text Siri captured, trimmed; nil when there is nothing to
    /// send yet (Siri then asks for it). Pure.
    static func content(from text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func resolveContent(
        for intent: INSendMessageIntent,
        with completion: @escaping (INStringResolutionResult) -> Void
    ) {
        if let text = Self.content(from: intent.content) {
            completion(.success(with: text))
        } else {
            completion(.needsValue())
        }
    }

    func confirm(
        intent: INSendMessageIntent,
        completion: @escaping (INSendMessageIntentResponse) -> Void
    ) {
        completion(INSendMessageIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(
        intent: INSendMessageIntent,
        completion: @escaping (INSendMessageIntentResponse) -> Void
    ) {
        let message = intent.content ?? ""
        let requested = Self.requestedAgent(from: intent.recipients)
        Task { @MainActor in
            switch prepare(message, requested) {
            case .failure:
                completion(INSendMessageIntentResponse(code: .failure, userActivity: nil))
            case .ready(let agentID, let agentName, let text):
                let delivered = await deliver(agentID, agentName, text)
                completion(INSendMessageIntentResponse(code: delivered ? .success : .failure, userActivity: nil))
            }
        }
    }
}
