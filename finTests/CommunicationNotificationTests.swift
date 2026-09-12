import Intents
import UserNotifications
import XCTest
@testable import fin

/// Phase 1 of docs/CARPLAY-IMESSAGE-DESIGN.md, the pure halves: the `fin.reply`
/// / `fin.input` category registration, the extended "fin" payload parser, the
/// foreground dedupe rule, the INSendMessageIntent the app and the fin-nse
/// extension both build, the SiriKit handler's recipient resolution, and the
/// typed-reply routing — all without a control plane, a Siri session, or a
/// device. Whether Announce actually reads the result aloud needs a car.
final class CommunicationNotificationTests: XCTestCase {

    // MARK: - Category registration

    func testRegistersReplyAndInputCategoriesWithOneTextInputActionEach() {
        let categories = AgentNotificationService.notificationCategories
        XCTAssertEqual(Set(categories.map(\.identifier)), ["fin.reply", "fin.input"])

        for category in categories {
            XCTAssertEqual(category.actions.count, 1, "\(category.identifier) carries exactly one action")
            let action = category.actions.first
            XCTAssertTrue(action is UNTextInputNotificationAction, "\(category.identifier)'s action must take typed text")
            // The category is what ties a notification to the Messaging intent
            // the app donates and handles.
            XCTAssertEqual(category.intentIdentifiers, ["INSendMessageIntent"])
        }
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0) })
        XCTAssertEqual(byID["fin.reply"]?.actions.first?.title, "Reply")
        XCTAssertEqual(byID["fin.reply"]?.actions.first?.identifier, "fin.reply.text")
        XCTAssertEqual(byID["fin.input"]?.actions.first?.title, "Answer")
        XCTAssertEqual(byID["fin.input"]?.actions.first?.identifier, "fin.input.text")
    }

    func testOnlyMessageCategoriesAreCommunication() {
        XCTAssertTrue(FinCommunicationNotification.isCommunicationCategory("fin.reply"))
        XCTAssertTrue(FinCommunicationNotification.isCommunicationCategory("fin.input"))
        XCTAssertFalse(FinCommunicationNotification.isCommunicationCategory(""))
        XCTAssertFalse(FinCommunicationNotification.isCommunicationCategory("fin.attention"))
    }

    // MARK: - Payload parsing

    func testPayloadParsesTheControlPlaneShape() {
        let agentID = UUID()
        let payload = FinCommunicationNotification.Payload.parse([
            "aps": ["alert": ["title": "Fin", "body": "evals passed"], "category": "fin.reply"],
            "fin": ["agentID": agentID.uuidString, "agentName": "Fin", "messageId": "m-abc", "originDeviceID8": "a4a1d987"],
        ])
        XCTAssertEqual(payload, FinCommunicationNotification.Payload(
            agentID: agentID, agentName: "Fin", messageID: "m-abc", originDeviceID8: "a4a1d987"
        ))
    }

    func testPayloadDegradesFieldByFieldNeverWholesale() {
        // A push with only a name (no agent id) still attributes the message.
        let nameOnly = FinCommunicationNotification.Payload.parse(["fin": ["agentName": "Ops"]])
        XCTAssertEqual(nameOnly?.agentName, "Ops")
        XCTAssertNil(nameOnly?.agentID)
        // Garbage id, blank name → those fields absent, the payload survives.
        let garbage = FinCommunicationNotification.Payload.parse(
            ["fin": ["agentID": "nope", "agentName": "   ", "messageId": ""]]
        )
        XCTAssertNotNil(garbage)
        XCTAssertNil(garbage?.agentID)
        XCTAssertNil(garbage?.agentName)
        XCTAssertNil(garbage?.messageID)
        // No "fin" dict at all → nil.
        XCTAssertNil(FinCommunicationNotification.Payload.parse(["aps": ["alert": "hi"]]))
        XCTAssertNil(FinCommunicationNotification.Payload.parse([:]))
    }

    func testLocalBannerUserInfoRoundTripsThroughBothParsers() {
        let agentID = UUID()
        let userInfo = FinCommunicationNotification.Payload.userInfo(
            kind: "agentReply", agentID: agentID, agentName: "Fin", messageID: "m-1"
        )
        let shared = FinCommunicationNotification.Payload.parse(userInfo)
        XCTAssertEqual(shared?.agentID, agentID)
        XCTAssertEqual(shared?.agentName, "Fin")
        XCTAssertEqual(shared?.messageID, "m-1")
        XCTAssertNil(shared?.originDeviceID8, "a local banner never claims an origin")

        let app = AgentNotificationService.parseFinPayload(userInfo)
        XCTAssertEqual(app?.agentID, agentID)
        XCTAssertEqual(app?.agentName, "Fin")
        XCTAssertEqual(app?.messageID, "m-1")
        XCTAssertNil(app?.originDeviceID8)
        // The kind key the tap router has always carried is still there.
        XCTAssertEqual((userInfo["fin"] as? [String: Any])?["kind"] as? String, "agentReply")
    }

    func testAppParserStillRequiresAnAgentID() {
        XCTAssertNil(AgentNotificationService.parseFinPayload(["fin": ["agentName": "Fin", "messageId": "m-1"]]))
    }

    // MARK: - Reply target

    func testReplyTargetNeedsBothIDAndName() {
        let agentID = UUID()
        let both = AgentNotificationService.replyTarget(
            from: ["fin": ["agentID": agentID.uuidString, "agentName": "Fin"]]
        )
        XCTAssertEqual(both?.agentID, agentID)
        XCTAssertEqual(both?.agentName, "Fin")
        XCTAssertNil(AgentNotificationService.replyTarget(from: ["fin": ["agentID": agentID.uuidString]]),
                     "an id alone can't address a control-plane message")
        XCTAssertNil(AgentNotificationService.replyTarget(from: ["fin": ["agentName": "Fin"]]),
                     "a name alone can't address the legacy inbox")
    }

    // MARK: - Foreground dedupe

    func testForegroundSuppressesOnlyEchoedReplyPushes() {
        let echo: [AnyHashable: Any] = ["fin": ["agentID": UUID().uuidString, "agentName": "Fin", "messageId": "m-seen"]]
        let fresh: [AnyHashable: Any] = ["fin": ["agentID": UUID().uuidString, "agentName": "Fin", "messageId": "m-new"]]
        let surfaced = ["m-old", "m-seen"]

        XCTAssertTrue(AgentNotificationService.shouldSuppressForeground(
            category: "fin.reply", userInfo: echo, surfacedMessageIDs: surfaced))
        XCTAssertFalse(AgentNotificationService.shouldSuppressForeground(
            category: "fin.reply", userInfo: fresh, surfacedMessageIDs: surfaced))
        // A question this device is parked on is still worth showing.
        XCTAssertFalse(AgentNotificationService.shouldSuppressForeground(
            category: "fin.input", userInfo: echo, surfacedMessageIDs: surfaced))
        // No message id → nothing to match on → present.
        XCTAssertFalse(AgentNotificationService.shouldSuppressForeground(
            category: "fin.reply", userInfo: ["fin": ["agentID": UUID().uuidString]], surfacedMessageIDs: surfaced))
    }

    @MainActor
    func testMarkSurfacedLocallyKeepsABoundedDedupedRing() {
        // UNNotification has no public initializer, so `willPresent` itself can't
        // be driven; it is a one-line wrapper over `shouldSuppressForeground`
        // fed by this ring, which IS observable.
        let service = AgentNotificationService.shared
        let id = "m-echo-\(UUID().uuidString)"
        service.markSurfacedLocally(messageID: id)
        service.markSurfacedLocally(messageID: id)
        service.markSurfacedLocally(messageID: "")
        XCTAssertEqual(service.recentlySurfacedMessageIDs.filter { $0 == id }.count, 1, "idempotent")
        XCTAssertFalse(service.recentlySurfacedMessageIDs.contains(""), "blank ids are never recorded")

        for index in 0..<AgentNotificationService.recentlySurfacedLimit {
            service.markSurfacedLocally(messageID: "m-fill-\(index)")
        }
        XCTAssertEqual(service.recentlySurfacedMessageIDs.count, AgentNotificationService.recentlySurfacedLimit)
        XCTAssertFalse(service.recentlySurfacedMessageIDs.contains(id), "the oldest id ages out")
        XCTAssertEqual(service.recentlySurfacedMessageIDs.last, "m-fill-\(AgentNotificationService.recentlySurfacedLimit - 1)")
        XCTAssertTrue(AgentNotificationService.shouldSuppressForeground(
            category: "fin.reply",
            userInfo: ["fin": ["agentID": UUID().uuidString, "messageId": "m-fill-3"]],
            surfacedMessageIDs: service.recentlySurfacedMessageIDs))
    }

    // MARK: - Intent construction (shared with fin-nse)

    func testSendMessageIntentIsAnIncomingMessageFromTheAgent() {
        let agentID = UUID()
        let intent = FinCommunicationNotification.sendMessageIntent(
            agentName: "Fin", agentID: agentID, body: "evals passed, 212 of 212"
        )
        XCTAssertEqual(intent.content, "evals passed, 212 of 212")
        XCTAssertEqual(intent.conversationIdentifier, agentID.uuidString, "one thread per agent")
        XCTAssertEqual(intent.outgoingMessageType, .outgoingMessageText)
        XCTAssertNil(intent.recipients, "Fin is the sender, not a recipient")
        XCTAssertEqual(intent.sender?.displayName, "Fin")
        XCTAssertEqual(intent.sender?.customIdentifier, agentID.uuidString)
        XCTAssertEqual(intent.sender?.isMe, false)
        XCTAssertNotNil(intent.sender?.image, "Announce shows and Siri needs a sender avatar")
    }

    func testSendMessageIntentFallsBackToNameAsConversationWithoutAnID() {
        let intent = FinCommunicationNotification.sendMessageIntent(agentName: "Ops", agentID: nil, body: "hi")
        XCTAssertEqual(intent.conversationIdentifier, "Ops")
        XCTAssertEqual(intent.sender?.customIdentifier, "Ops")
    }

    func testRewriteLeavesNonMessagePushesUntouched() {
        // The extension's decision rule: no communication category, or no name
        // to attribute the message to → the original content object comes back.
        let plain = UNMutableNotificationContent()
        plain.title = "Fin"
        plain.body = "still thinking"
        plain.userInfo = ["fin": ["agentID": UUID().uuidString, "agentName": "Fin"]]
        XCTAssertTrue(FinCommunicationNotification.rewrite(plain) === plain)

        let nameless = UNMutableNotificationContent()
        nameless.categoryIdentifier = "fin.reply"
        nameless.body = "done"
        nameless.userInfo = ["fin": ["agentID": UUID().uuidString]]
        XCTAssertTrue(FinCommunicationNotification.rewrite(nameless) === nameless)
    }

    func testRewriteOfAMessagePushNeverThrowsAndKeepsTheBody() {
        // The test host is unentitled, so `updating(from:)` may throw — the
        // contract is that the caller still gets valid content with the body.
        let push = UNMutableNotificationContent()
        push.categoryIdentifier = "fin.reply"
        push.title = "Fin"
        push.body = "shipped to TestFlight"
        push.userInfo = ["fin": ["agentID": UUID().uuidString, "agentName": "Fin", "messageId": "m-9"]]
        let result = FinCommunicationNotification.rewrite(push)
        XCTAssertEqual(result.body, "shipped to TestFlight")
        XCTAssertEqual(result.categoryIdentifier, "fin.reply")
    }

    // MARK: - Target resolution (FinVoiceIntentCore additions)

    func testRequestedTargetMatchesByIDThenNameCaseInsensitively() {
        let fin = (id: UUID(), name: "Fin")
        let ops = (id: UUID(), name: "Ops")
        let agents = [fin, ops]
        XCTAssertEqual(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: ops.id.uuidString.lowercased()), 1)
        XCTAssertEqual(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: "ops"), 1)
        XCTAssertEqual(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: " FIN "), 0)
        XCTAssertNil(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: "Scout"))
        XCTAssertNil(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: nil))
        XCTAssertNil(FinVoiceIntentCore.requestedTargetIndex(agents: agents, requested: "  "))
    }

    // MARK: - SiriKit handler resolution

    /// `INPersonHandle` is non-optional on this initializer, so an "absent"
    /// handle is modelled as a blank value — which `requestedAgent` must skip.
    private func person(name: String?, customID: String? = nil, handle: String = "") -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown),
            nameComponents: nil, displayName: name, image: nil,
            contactIdentifier: nil, customIdentifier: customID
        )
    }

    func testRequestedAgentPrefersCustomIdentifierThenDisplayNameThenHandle() {
        XCTAssertEqual(FinMessageIntentHandler.requestedAgent(from: [person(name: "Fin", customID: "ID-1", handle: "h")]), "ID-1")
        XCTAssertEqual(FinMessageIntentHandler.requestedAgent(from: [person(name: "Fin", customID: " ", handle: "h")]), "Fin")
        XCTAssertEqual(FinMessageIntentHandler.requestedAgent(from: [person(name: nil, handle: "handle")]), "handle")
        XCTAssertNil(FinMessageIntentHandler.requestedAgent(from: [person(name: nil)]))
        XCTAssertNil(FinMessageIntentHandler.requestedAgent(from: [person(name: "  ", handle: "  ")]))
        XCTAssertNil(FinMessageIntentHandler.requestedAgent(from: []))
        XCTAssertNil(FinMessageIntentHandler.requestedAgent(from: nil))
    }

    func testResolveRecipientDefaultsToFinAndFallsBackOnUnknownNames() {
        let fin = (id: UUID(), name: "Fin")
        let ops = (id: UUID(), name: "Ops")
        // Nothing named → the agent called Fin.
        XCTAssertEqual(FinMessageIntentHandler.resolveRecipient(requested: nil, agents: [ops, fin])?.id, fin.id)
        // An explicit match wins.
        XCTAssertEqual(FinMessageIntentHandler.resolveRecipient(requested: "ops", agents: [ops, fin])?.id, ops.id)
        XCTAssertEqual(FinMessageIntentHandler.resolveRecipient(requested: fin.id.uuidString, agents: [ops, fin])?.id, fin.id)
        // A mis-heard name still reaches Fin instead of failing the reply.
        XCTAssertEqual(FinMessageIntentHandler.resolveRecipient(requested: "Finn", agents: [ops, fin])?.id, fin.id)
        // No agents at all → nothing to send to.
        XCTAssertNil(FinMessageIntentHandler.resolveRecipient(requested: "Fin", agents: []))
    }

    func testPersonForAgentCarriesTheIDAsCustomIdentifier() {
        let agent = (id: UUID(), name: "Fin")
        let person = FinMessageIntentHandler.person(for: agent)
        XCTAssertEqual(person.displayName, "Fin")
        XCTAssertEqual(person.customIdentifier, agent.id.uuidString)
        XCTAssertEqual(person.isMe, false)
    }

    // MARK: - SiriKit handler end to end, with stubs

    private func handler(
        agents: [(id: UUID, name: String)],
        prepared: FinVoiceIntentCore.Prepared,
        delivered: Bool,
        sink: @escaping (UUID, String, String) -> Void = { _, _, _ in }
    ) -> FinMessageIntentHandler {
        FinMessageIntentHandler(
            agents: { agents },
            prepare: { _, _ in prepared },
            deliver: { id, name, text in sink(id, name, text); return delivered }
        )
    }

    func testHandleDeliversPreparedTextAndReportsSuccess() {
        let agentID = UUID()
        var captured: (UUID, String, String)?
        let handler = handler(
            agents: [(agentID, "Fin")],
            prepared: .ready(agentID: agentID, agentName: "Fin", text: "ship it to TestFlight"),
            delivered: true
        ) { captured = ($0, $1, $2) }

        let intent = INSendMessageIntent(
            recipients: [person(name: "Fin", customID: agentID.uuidString)],
            outgoingMessageType: .outgoingMessageText, content: "ship it to TestFlight",
            speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil
        )
        let done = expectation(description: "completion")
        handler.handle(intent: intent) { response in
            XCTAssertEqual(response.code, .success)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(captured?.0, agentID)
        XCTAssertEqual(captured?.1, "Fin")
        XCTAssertEqual(captured?.2, "ship it to TestFlight")
    }

    func testHandleReportsFailureWhenDeliveryFailsOrPrepareRefuses() {
        let agentID = UUID()
        let undeliverable = handler(
            agents: [(agentID, "Fin")],
            prepared: .ready(agentID: agentID, agentName: "Fin", text: "hi"),
            delivered: false
        )
        let first = expectation(description: "delivery failed")
        undeliverable.handle(intent: INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hi", speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)) { response in
            XCTAssertEqual(response.code, .failure)
            first.fulfill()
        }
        wait(for: [first], timeout: 5)

        var deliverCalls = 0
        let refused = handler(agents: [], prepared: .failure("Nothing to send."), delivered: true) { _, _, _ in deliverCalls += 1 }
        let second = expectation(description: "prepare refused")
        refused.handle(intent: INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "", speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)) { response in
            XCTAssertEqual(response.code, .failure)
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(deliverCalls, 0, "a refused message must never be delivered")
    }

    func testResolveRecipientsAlwaysAnswersWithExactlyOneResult() {
        // INIntentResolutionResult exposes no public outcome, so the decision
        // itself is covered by the pure `resolveRecipient` tests above; this
        // pins the SiriKit contract — one result per call, on both paths.
        let agentID = UUID()
        let empty = handler(agents: [], prepared: .failure("x"), delivered: false)
        let none = expectation(description: "no agents")
        empty.resolveRecipients(for: INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)) { results in
            XCTAssertEqual(results.count, 1)
            none.fulfill()
        }
        wait(for: [none], timeout: 5)

        let some = handler(agents: [(agentID, "Fin")], prepared: .failure("x"), delivered: false)
        let resolved = expectation(description: "resolved")
        some.resolveRecipients(for: INSendMessageIntent(recipients: [person(name: "fin")], outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)) { results in
            XCTAssertEqual(results.count, 1)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 5)
    }

    func testContentResolutionTrimsAndRejectsBlankText() {
        XCTAssertNil(FinMessageIntentHandler.content(from: nil))
        XCTAssertNil(FinMessageIntentHandler.content(from: "   "))
        XCTAssertEqual(FinMessageIntentHandler.content(from: " ok "), "ok")
    }

    // MARK: - Typed notification reply

    @MainActor
    func testTypedReplyGoesToTheNamedAgentThroughTheInjectedDeliverer() async {
        let service = AgentNotificationService.shared
        let original = service.replyDeliverer
        defer { service.replyDeliverer = original }

        let agentID = UUID()
        var captured: (UUID, String, String)?
        service.replyDeliverer = { id, name, text in captured = (id, name, text); return true }

        let userInfo: [AnyHashable: Any] = ["fin": ["kind": "agentReply", "agentID": agentID.uuidString, "agentName": "Fin"]]
        let delivered = await service.handleTypedReply("  yes, merge it  ", userInfo: userInfo)
        XCTAssertTrue(delivered)
        XCTAssertEqual(captured?.0, agentID)
        XCTAssertEqual(captured?.1, "Fin")
        XCTAssertEqual(captured?.2, "yes, merge it")

        // Blank text and an unaddressable payload never reach the deliverer.
        captured = nil
        let blank = await service.handleTypedReply("   ", userInfo: userInfo)
        let unaddressed = await service.handleTypedReply("hello", userInfo: ["fin": ["agentID": agentID.uuidString]])
        XCTAssertFalse(blank)
        XCTAssertFalse(unaddressed)
        XCTAssertNil(captured)
    }
}
