# Fin in the car and in Messages

Design for Levi's ask (2026-09-12): "for carplay it's basically a microphone that
lets you send a message to fin and if it could display the eventual response or
show a notification in carplay for when your attention is needed that's
sufficient, for imessage if you can just send okay but want to know what are the
actual capabilities of an imessage app and how could fin fit into that?"

Sources: Apple CarPlay Developer Guide (June 2026 edition), Apple developer
documentation for Messages / SiriKit / App Intents / UserNotifications,
register.apple.com (Messages for Business), WWDC21 10091, WWDC26 212/240/343,
and the Fin codebase as of commit 3a02e1f. Where a claim is not verified against
an Apple source it is marked **unverified**.

---

## 1. TL;DR

1. **Build first (no Apple approval, iOS 17+):** turn Fin's pushes into *communication notifications* so Siri **announces** Fin's replies and "needs your input" in the car (and on AirPods) and takes a spoken reply hands-free. The microphone half already works today: "Hey Siri, ask Fin ..." runs Fin's existing headless App Intents from CarPlay.
2. Concretely: Communication Notifications capability (self-serve) + a Notification Service Extension that donates `INSendMessageIntent` with an `INPerson` "Fin" sender + an in-app `INSendMessageIntent` handler + a text-input reply action + a Lambda push on every answered message.
3. **Nothing in the first phase draws on the CarPlay screen.** Non-entitled apps get no CarPlay banners; the reply is *spoken*, not displayed. The only entitlement-free on-screen artifact is a Live Activity tile in CarPlay Dashboard (iOS 26+), which is Phase 2.
4. **Needs Apple approval:** a Fin icon on the CarPlay home screen. The only honest category is *voice-based conversational* (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+, the ChatGPT/Claude/Gemini path). File it after Phase 1 ships; nothing depends on it. Never request `carplay-communication`.
5. **iMessage: an iMessage app cannot make Fin a contact you text.** It is a UI inside the Messages drawer; it can send *to* Fin only while the user is in Messages, it can never post a reply *from* Fin, it cannot read the thread, has no background/push/Siri, and is iOS-only (won't build for Mac).
6. The only way a bot *receives* iMessages is Messages for Business through an Apple-approved MSP with a mandatory human-escalation path. Wrong shape for a personal agent. **Recommendation: build nothing iMessage-specific.** The "message Fin" feeling comes from the same communication-notification work, and it also works on the Mac.

---

## 2. Platform facts that decide the design

### CarPlay

| Capability | Works without entitlement? | Entitlement needed | Source |
|---|---|---|---|
| Siri dictates into a Fin App Intent from the CarPlay Siri button; Siri speaks the `IntentDialog` | **Yes** (Fin's intents are headless, `openAppWhenRun = false`) | none | `fin/Intents/SendToFinIntent.swift:149,192`; https://developer.apple.com/documentation/appintents |
| Siri *announces* a third-party notification aloud in CarPlay/AirPods/HomePod and takes a voice reply | **Yes**, if it is a *communication notification* (INSendMessageIntent donation with INPerson sender) and the user enables Announce Notifications > CarPlay | `com.apple.developer.usernotifications.communication` (self-serve Xcode capability, no review) | https://developer.apple.com/videos/play/wwdc2021/10091/ ; https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications ; https://support.apple.com/en-us/102536 |
| Ordinary banner notification shown on the CarPlay screen | **No** — only communication, EV charging, parking, public safety, and (iOS 18.4+) driving-task CarPlay apps; others get `.notSupported` | a granted CarPlay category entitlement | CarPlay Developer Guide p.27 https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf ; https://developer.apple.com/forums/thread/720159 |
| "In general, notifications are not read aloud in CarPlay" (announce comes from Announce Notifications, not CarPlay) | n/a | n/a | CarPlay Developer Guide p.27 |
| Widget / Live Activity tile in CarPlay Dashboard (iOS 26+) | **Yes** ("Your app does not need to be a CarPlay app"); `.supplementalActivityFamilies([.small])`; cannot launch Fin in CarPlay | none | CarPlay Developer Guide pp.3, 9, 10 ; https://developer.apple.com/videos/play/wwdc2025/216/ |
| Any template / app icon on the CarPlay screen | **No** — every template is gated by a category entitlement, enforced at runtime | one of the eleven category entitlements | CarPlay Developer Guide pp.12-14 ; https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements |
| Voice-based conversational app (mic via `CPVoiceControlTemplate`, spoken answers, up to 2 action buttons) | No | `com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+, Apple-reviewed, no wake word, not in the CarPlay-notifications list, 3-template depth, no text/imagery in response to queries | CarPlay Developer Guide pp.7, 13, 14 ; https://www.macrumors.com/2026/02/18/ios-26-4-carplay-support/ |
| Communication CarPlay app | No | `com.apple.developer.carplay-communication`; must be a short-form messaging/VoIP app implementing INSendMessageIntent + INSearchForMessagesIntent + INSetMessageAttributeIntent; message content may never be shown on the CarPlay screen; "designed primarily" test applies to the whole app | CarPlay Developer Guide pp.4-5 |
| In-app microphone in CarPlay | No | only navigation and voice-based conversational apps, and only while the voice control template is showing | CarPlay Developer Guide p.29 |
| iOS 27: Voice Control template / overlay for all categories | No (still needs a category entitlement) | category entitlement | https://developer.apple.com/videos/play/wwdc2026/212/ |
| iOS 27: Siri AI in CarPlay running a third-party App Intent and showing the result on the car screen | **Unverified** (beta anecdotes; Apple-Intelligence hardware only; not EU/China at launch) | n/a | https://www.apple.com/newsroom/2026/06/apple-unveils-next-generation-of-apple-intelligence-siri-ai-and-more/ ; WWDC26 212 has no Siri/App Intents mention |
| App Intents `.messages` schema domain (sendMessage etc.; all five schemas required if any) | Yes, but availability lines on the doc pages read OS 27.0 and the iOS 18 AssistantSchemas list has no Messages domain — **treat as OS 27+ until checked against the Xcode 27 SDK** | none | https://developer.apple.com/documentation/appintents/app-schema-domain-messages ; https://developer.apple.com/documentation/appintents/appschema/messagesintent/sendmessage |
| SiriKit `INSendMessageIntent` ("send a message to Fin *using Fin*") | Yes, iOS 10+ / macOS 12+; Apple's messaging docs remain live (press reports of WWDC26 deprecation are **unverified**) | none | https://developer.apple.com/documentation/sirikit/messaging ; https://developer.apple.com/documentation/intents/insendmessageintent |
| Time Sensitive interruption level | Yes | `com.apple.developer.usernotifications.time-sensitive` (self-serve) | https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel |
| CarPlay Simulator | Yes | none | CarPlay Developer Guide p.8 (Xcode Additional Tools) |

### Messages (iMessage)

| Capability | Works without entitlement? | Entitlement needed | Source |
|---|---|---|---|
| Custom UI in the Messages drawer / expanded sheet / live bubble in the transcript | Yes (iMessage app extension target) | none | https://developer.apple.com/documentation/messages |
| Insert text / sticker / attachment / `MSMessage` into the input field; user taps Send | Yes | none | https://developer.apple.com/documentation/messages/msconversation/insert(_:completionhandler:)-3g248 |
| Send without the extra Send tap (`send`, `sendText`, iOS 11+) | Only while the extension is visible and after a recent touch; otherwise `sendWhileNotVisible` / `sendWithoutRecentInteraction` | none | https://developer.apple.com/documentation/messages/msconversation/send(_:completionhandler:)-9krz |
| Receive messages programmatically | **No** — `didReceive` fires only for the extension's *own* bubbles and only while it is active on screen | n/a | https://developer.apple.com/documentation/messages/msmessagesappviewcontroller/didreceive(_:conversation:) |
| Read the transcript / see plain-text messages | **No** | n/a | same |
| Run in the background / receive push / be reached by Siri | **No**; `willResignActive` warns async work may not complete | n/a | https://developer.apple.com/documentation/messages/msmessagesappviewcontroller/willresignactive(with:) |
| Identify participants | **No** — opaque per-device UUIDs that rotate on reinstall | n/a | https://developer.apple.com/documentation/messages/msconversation/localparticipantidentifier |
| Payload on a bubble | `MSMessage.url`, http/https/data only, <= 5,000 chars; macOS opens it in a browser | none | https://developer.apple.com/documentation/messages/msmessage/url |
| Update an earlier bubble in place | Yes (`MSSession`) | none | https://developer.apple.com/documentation/messages/mssession |
| Build for macOS / Mac Catalyst | **No** ("iMessage Applications are not available when building for Mac Catalyst"; medium confidence, forum thread) | n/a | https://developer.apple.com/forums/thread/731364 |
| A bot that receives iMessages | Only via **Messages for Business**: registered business + Apple-approved MSP (direct connection prohibited) + mandatory human escalation + customer-initiated conversations | Apple Business Register approval; MSP contract | https://register.apple.com/resources/messages/messaging-documentation/faq ; https://register.apple.com/resources/messages/msp-rest-api/ |
| Shortcuts "Send Message" / message automations | On-device only, confirmation prompts, no server hook | none | https://support.apple.com/guide/shortcuts/communication-triggers-apdd711f9dff/ios |
| Critical Messaging API (iOS 18.2+) | Background SMS to pre-authorized numbers, rate-limited, enterprise check-ins | `com.apple.developer.messages.critical-messaging` | https://developer.apple.com/documentation/messages/critical-messaging-api |

---

## 3. CarPlay design

### 3.1 What already works (Phase 0, zero code)

`AskFinIntent` and `SendToFinIntent` (`fin/Intents/SendToFinIntent.swift`) are
headless App Intents (`openAppWhenRun = false`, lines 149 and 192) whose
`String` parameter is filled by Siri dictation (`requestValueDialog`). Siri in
CarPlay is the same Siri, so today:

1. Driver presses the steering-wheel voice button: "Ask Fin, are the evals green on the iMac?"
2. `FinVoiceIntentCore.prepare` (lines 52-84) resolves the agent named "Fin"; `deliver` (35-46) POSTs `/messages` via `ControlPlaneClient.sendMessage` with `source: "voice"`.
3. `AskFinIntent` polls `GET /messages/{id}` for ~8s (4 x 2s, lines 201-204) and speaks `spokenSummary(replyPreview)` (<= 320 chars) if the row is `answered`; otherwise "Sent to Fin. It'll reply in the app."
4. "Hey Siri, tell Fin to restart the daemon" is the fire-and-forget variant.

The CarPlay screen shows Siri's UI, not Fin's. That satisfies the "microphone"
half. Phase 0 is: open CarPlay Simulator (Xcode Additional Tools), confirm both
phrases work, record a short capture for App Store review notes.

Spoken examples in this document use Fin's existing phrases ("Ask Fin",
"Tell Fin to"). "Send a message to Fin" *without* "using Fin" loses to the
built-in Messages domain (comment at `SendToFinIntent.swift:280-286`); with
SiriKit adopted, "send a message to Fin using Fin" is the verified form.

### 3.2 The gap: the eventual reply and "attention needed"

Today `/notify` pushes are plain APNs alerts. CarPlay neither shows them (banner
notifications on CarPlay are restricted to five entitled categories) nor reads
them aloud. The daemon also only pushes on `request-input`, `task-complete`,
`agent-stalled`, and the model's notify tool (`daemon/Sources/fin-agentd/DaemonNotifyClient.swift:72-137`,
`Daemon.swift:1052,1461,1523`) — never on an ordinary answered turn. So a reply
that lands minutes after Siri's 8-second poll gave up reaches nobody in the car.

### 3.3 The flow we build (Phase 1)

1. A site answers: `POST /messages/{id}/ack {state: answered, replyPreview}` (`lambda.py:3416-3466`).
2. **New:** `ack_message` fires a best-effort push through the existing APNs fan-out with title = agent name, body = `replyPreview`, and APNs keys `mutable-content: 1`, `category: fin.reply`, `thread-id: <agentID>`; the custom `fin` dict gains `agentName` and `messageId`. Push failure never fails the ack.
3. **New:** a Notification Service Extension (`fin-nse`) receives it, builds `INSendMessageIntent(recipients: nil, ..., conversationIdentifier: agentID, sender: INPerson(displayName: agentName, image: app icon, isMe: false))`, donates it via `INInteraction(direction: .incoming)`, and returns `content.updating(from: intent)`. It needs nothing from the app (no app group, no token).
4. iOS now treats it as a direct message: avatar, breaks through Focus and the summary by default, and — with Settings > Notifications > Announce Notifications > CarPlay on — **Siri says in the car: "Fin says: evals passed, 212 of 212. Want to reply?"**
5. Driver: "Reply: ship it to TestFlight." Siri reads it back, confirms, and hands the text to Fin's **new** in-app `INSendMessageIntent` handler, which calls `FinVoiceIntentCore.deliver` → `/messages` with `source: "voice"`.
6. `request-input` / `agent-stalled` pushes ride the same path (title "Fin needs input"); they additionally carry `interruption-level: time-sensitive` (Time Sensitive capability, self-serve), because Announce's default filter is "Time Sensitive and Direct Messages".
7. Tapping the notification anywhere uses the unchanged `AgentNotificationService.didReceive` / `parseFinPayload` deep link into the conversation.

Off-car, the same notification gets a `UNNotificationCategory("fin.reply")` with
a `UNTextInputNotificationAction`, so a typed reply from the Lock Screen, Watch,
or Mac Notification Center posts through the same `deliver` path with
`source: "app"`.

**What appears on the CarPlay screen in Phase 1: nothing from Fin.** The reply is
spoken. This is the accepted shape for a non-entitled app; do not describe it to
anyone as "displaying the response".

### 3.4 Attention tile on the car screen (Phase 2, no entitlement, iOS 26+)

A small-family Live Activity ("Fin is working on <goal>" / "Fin needs your
input"), headline and glyph taken verbatim from `FinPresence.fold`
(`fin/Agent/SiteDirectory.swift:100-133`), appears in CarPlay Dashboard and
doubles as Dynamic Island / Lock Screen status. It is started from the
foreground app (or later via ActivityKit push-to-start tokens) and updated via
`apns-push-type: liveactivity` pushes from Lambda — **not** from an alert-push
background wake, which ActivityKit does not support. It cannot launch Fin in
CarPlay (only CarPlay apps can); the question itself is answered by voice via 3.3.

### 3.5 A Fin icon in the car (Phase 3, Apple-gated, optional)

- Request `com.apple.developer.carplay-voice-based-conversation` at developer.apple.com/carplay and accept the CarPlay Entitlement Addendum. Framing: "Fin is a voice-first assistant that answers questions about, and performs actions on, your computers. Primary modality on launch is voice; replies are spoken; no text or imagery is shown in response to queries." Never use "messaging" or "chat app". Submit only once Phase 1 has shipped and a CarPlay Simulator build exists (Apple rejects placeholders). No SLA (days to weeks).
- Scene: `CPTemplateApplicationSceneDelegate`, root `CPVoiceControlTemplate` with listening / thinking / speaking states and two action buttons (iOS 26.4+): "Ask Fin", "Read last reply". Depth cap 3. On iOS 27 optionally present it as an overlay (`CPInterfaceController.showOverlayTemplate`) over a one-deep list of recent goals from `ControlPlaneClient.listMessages`; full-screen template on 26.4.
- This is Fin's **first in-app microphone**: `AVAudioSession` + `SFSpeechRecognizer` (prefer `requiresOnDeviceRecognition`) + `AVSpeechSynthesizer` for the answer. Adds `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`; audio session must be released when idle.
- Keep the key in a separate `fin-iOS-carplay.entitlements` so builds without the grant still sign.
- Limits to tell Levi up front: no wake word (tap the icon or "Hey Siri, open Fin"); the conversational category is not in the CarPlay notifications list, so attention still comes from 3.3/3.4.
- **If denied:** nothing is lost; Phases 1-2 are the product. Do not fall back to `carplay-communication` — it fails the "designed primarily" test, forces a messaging-app identity, and forbids showing replies anyway.

### 3.6 Reuse vs new

Reused unchanged:
- `fin/Intents/SendToFinIntent.swift` — `FinVoiceIntentCore.prepare/deliver/spokenSummary/newReply`, `AskFinIntent` poll loop, `FinAppShortcuts` phrases.
- `fin/Agent/ControlPlaneClient.swift:135-165` — `sendMessage`, `messageState`, `listMessages`, `MessageContext`.
- `fin/Agent/AgentNotificationService.swift:278-306` — `parseFinPayload`, `didReceive` deep link, `persistSignal`.
- `fin/Agent/DeviceTokenUplink.swift`, `fin/finApp.swift:26-50` — token registration.
- `fin/Agent/SiteDirectory.swift:85-133` — `FinPresence.fold` (Phase 2 headline).
- `lambda.py:1362 _apns_push`, `1387-1431 device tokens`, message lifecycle `3265-3466`.
- Tests: `finTests/VoiceIntentCoreTests.swift`, `finTests/SitesAndMessagesTests.swift`, `scripts/cloud-agent/control-plane/test_lambda.py`.

New (app, Phase 1):
- `fin/NotificationService/` — NSE target `fin-nse` (`bundle.app-extension` in `project.yml`, then `xcodegen generate`; never hand-edit the xcodeproj). ~60 lines: payload → `INPerson` / `INSendMessageIntent` donation → `updating(from:)`.
- `fin/Intents/FinMessageIntentHandler.swift` — `INSendMessageIntentHandling` resolving the recipient to the agent and calling `FinVoiceIntentCore.deliver`; registered from the AppDelegate in `fin/finApp.swift` via `application(_:handlerFor:)`. **Unverified end-to-end** that Announce's voice reply reaches an in-app handler with no Intents extension; validate in Phase 1, fall back to a small Intents extension target if required. `INSearchForMessagesIntent` / `INSetMessageAttributeIntent` are *not* needed for Announce of communication notifications and are deferred.
- `AgentNotificationService`: register `UNNotificationCategory("fin.reply")` with a text-input action; handle `UNTextInputNotificationResponse.userText` → `deliver`; the local `notifyTurnFinished` / `notifyInputRequested` banners set the category and perform the same intent donation so app-hosted and remote replies look identical.
- Entitlements / Info: `com.apple.developer.usernotifications.communication` and `...time-sensitive` in `fin/fin-iOS.entitlements` (try `fin-macOS.entitlements` too — **macOS support unverified**; degrade to plain alerts there if it doesn't build); `NSUserActivityTypes: [INSendMessageIntent]` in `project.yml` `info`; an app-level `PrivacyInfo.xcprivacy` for the app and each new extension (none exists today).
- Setup copy: one line in the existing voice-button setup screen (from 9e53d3b): "To hear Fin in the car, turn on Announce Notifications > CarPlay."
- Build plumbing: exclude the NSE from `fin-tv`; update `scripts/testflight-macos.sh` (arm64-only) and the other TestFlight scripts for the extension bundle.

New (app, Phase 2): WidgetKit extension target with the Live Activity; App Group only if the widget needs anything beyond ActivityKit state.

New (app, Phase 3): `fin/CarPlay/FinCarPlaySceneDelegate.swift`, `fin/CarPlay/FinCarPlayVoiceController.swift`, `UIApplicationSceneManifest` CarPlay scene entry, usage-description strings, `fin-iOS-carplay.entitlements`.

### 3.7 Control-plane changes (`scripts/cloud-agent/control-plane/lambda.py`)

1. **Refactor** the APNs fan-out out of the `notify` route (`:1433-1547`) into a reusable `_push_to_user(user_id, title, body, fin, aps_extra)` that wraps the existing `_apns_push` (`:1362`). The route keeps its 503/502 semantics.
2. **Payload** (`:1495-1503`): add `"mutable-content": 1`, `"category"` (`fin.reply` / `fin.input`), `"thread-id": agentID`; add `agentName` and `messageId` to the `fin` dict; add `"interruption-level": "time-sensitive"` only for `request-input` / `agent-stalled` (daemon passes an `event` field in `DaemonNotifyClient.requestBody`). Backward compatible — old builds ignore the keys.
3. **Push on answered** in `ack_message` (`:3441-3466`) when `state == "answered"` and `replyPreview` is present. Dedupe rule: **do not gate on `source == "voice"`** (that would silently drop replies to app / Mac-terminal questions). Instead: skip when the answering site is the foreground device (the app drops it in `willPresent` when `fin.messageId` matches a turn it already surfaced locally), and dedupe by `messageId` against the daemon's `task-complete` push. Best-effort; never fail the ack.
4. `MESSAGE_SOURCES` (`:3075`): unchanged for Phase 1 (Announce/CarPlay Siri replies are `"voice"`, typed notification replies are `"app"`). Add `"carplay"` only in Phase 3 for provenance; `send_message` rejects unknown sources with 400 (`:3280-3282`).
5. Phase 2: an `apns-push-type: liveactivity` sender for Live Activity updates.
6. Tests in `test_lambda.py`: payload keys; ack-answered triggers exactly one push; foreground/dedupe rules.

---

## 4. iMessage

### 4.1 The honest answer to "what can an iMessage app actually do?"

An iMessage app is a **Messages-framework extension that lives inside the
Messages app's drawer and only runs while the user has it open.** Verified
against Apple's docs:

It can:
- Show a custom UI in the drawer (compact / expanded) or as an interactive "live" bubble in the transcript (`MSMessageLiveLayout`).
- Put text, a sticker, an attachment, or an `MSMessage` bubble into the input field; the user taps Send. `send*` APIs (iOS 11+) skip that tap, but only while the extension is visible and within a recent touch.
- Carry <= 5,000 chars of http/https/data URL on the bubble and replace an earlier bubble via `MSSession`.
- Get `didReceive` for **its own bubbles only, only while it is open on screen**.

It cannot:
- Read the conversation or see ordinary text messages. "User typed *hey Fin* in a thread and Fin saw it" does not exist.
- Send anything when the user is not inside Messages with the drawer open. **Fin can never post a reply into an iMessage thread.** No background execution, no push, no Siri hook.
- Know who the user is: participants are opaque per-device UUIDs that rotate on reinstall.
- Build for the Mac: Xcode refuses iMessage extensions for Mac Catalyst; macOS Messages just opens the bubble's URL in a browser. This collides with the native-Mac pillar and the ship-all-platforms-in-sync rule.

The **only** way a bot receives iMessages is **Messages for Business**: a
registered company, an Apple-approved Messaging Service Provider in the middle
(direct connections prohibited), a mandatory human-agent escalation path,
customer-initiated conversations (invitations need Apple approval and explicit
opt-in). It is a B2C support channel for a brand. For Fin it would mean every
user texting one shared "Fin" business identity through a paid MSP with an
OAuth identity-mapping step. Feasible, heavyweight, and the wrong shape for a
personal terminal agent. Shortcuts "Send Message", Critical Messaging, and the
iOS 18.2 default-messaging-app entitlement are likewise not channels.

### 4.2 How Fin fits: not as a channel

What people want from "iMessage Fin" is: Fin shows up like a person, his
messages arrive like texts, break through Focus, get announced, and I can reply
in place from the Lock Screen, Watch, car. **Communication notifications
deliver all of that with no Apple review, and they are exactly the Phase 1
CarPlay work.** On iOS this is verified; on macOS it is unverified but, if it
works, gives the Mac something an iMessage extension never could.

- Fin's replies and "needs input" arrive with Fin's avatar and name, grouped in one thread per agent.
- Reply field on the notification posts straight to `/messages`.
- Siri announces them on AirPods and CarPlay and takes a spoken reply.
- Compose side: "Ask Fin ..." / "Tell Fin to ..." already work everywhere Siri does; with SiriKit adopted, "send a message to Fin using Fin" puts Fin in Siri's messaging-app picker (iOS 17+); on OS 27 the `.messages` App Schemas let Siri AI send without opening the app.

**Recommendation: ship nothing iMessage-specific.** Zero new targets.

If a Messages presence is still wanted later, scope it as a **share surface,
not a channel**: an `app-extension.messages` target whose only job is an
`MSMessageTemplateLayout` bubble ("Fin: working on <goal>", caption from
`replyPreview`) with an https link to a transcript/status page, refreshed with
`MSSession` when the sender reopens the extension, and an optional "Ask Fin"
field using `sendText` plus `FinVoiceIntentCore.deliver`. Blockers: Fin has no
public https share links (new control-plane share-token route and landing page),
the extension needs an App Group / keychain access group to reach the bearer
token (none exists; `FinSharedState.modelContainer` is in-process only), and it
ships as a dead target on macOS/tvOS/visionOS. ~1 week, iOS-only, dilutes the
"voice + native apps" framing. Defer indefinitely.

Messages for Business: revisit only if Fin LLC wants a support line.

---

## 5. Shared foundation

One piece of work serves the car, the "message Fin" feeling, the Mac, Watch, and AirPods.

1. **Communication notifications** — the keystone. Capability `com.apple.developer.usernotifications.communication` (self-serve). NSE donates `INSendMessageIntent` + `INPerson("Fin")` with `conversationIdentifier = agentID`, returns `updating(from:)`. Local banners in `AgentNotificationService` do the same donation. `UNNotificationCategory("fin.reply")` / `"fin.input"` with `UNTextInputNotificationAction`.
2. **`INSendMessageIntent` donation and handling** — the donation is what makes Announce read the notification as a direct message; the in-app handler (`application(_:handlerFor:)`, `NSUserActivityTypes` in the app Info.plist) is what makes Announce's spoken reply land in `/messages`. `INIntentsSupported` is the Intents-*extension* key and is only needed if the in-app path proves insufficient.
3. **App Intents assistant schema (`.messages`)** — gate behind `#available(iOS 27, *)` and implement all five (draft / send / edit / unsend / setReadStatus; edit and unsend may return unsupported errors but must exist), each a thin wrapper over `FinVoiceIntentCore`. Verify against the Xcode 27 SDK that the `AppIntent(schema:)` types compile availability-gated inside a 17.0-floor target (`SendToFinIntent.swift:252-257` assumed not). Optional in Phase 1; add the WWDC26 343 entity annotations on the reply notification at the same time so "Reply to that" via Siri AI targets Fin.
4. **Control plane** — reusable push helper, richer payload, push-on-answered with dedupe, later Live Activity pushes (section 3.7).
5. **Project plumbing** — `project.yml` targets, `CODE_SIGN_ENTITLEMENTS` per target, tvOS exclusion, TestFlight scripts, `PrivacyInfo.xcprivacy` per bundle; App Group `group.dev.levischoen.fin` + keychain access group only when an extension needs `CloudControlPlaneConfig` (not in Phase 1).
6. **Review hygiene** — keep "Siri" out of all intent metadata (ITMS-90626 already bit build 42); review notes stating that the "Fin" sender is the user's own agent, not another human, and that messaging intents route over Fin's transport, not SMS/iMessage (reviewers test communication notifications for marketing misuse); guideline 2.5.11 intents match the stated voice-interface functionality. If the Fin LLC developer-account transfer happens, any CarPlay entitlement and the addendum must be re-requested on the new team.

---

## 6. Phased delivery

| Phase | Approval gate | Work | Estimate | What Levi sees |
|---|---|---|---|---|
| **0 — Verify** | none | CarPlay Simulator: "Hey Siri, ask Fin ..." / "tell Fin to ...". Record it. | half a day, 0 code | The microphone half works in the car today; Siri speaks short answers. |
| **1 — Fin talks back in the car** | none | Communication Notifications + Time Sensitive capabilities; NSE; in-app `INSendMessageIntent` handler; `fin.reply` text-input category; Lambda push helper + payload keys + push-on-answered with dedupe; setup copy; privacy manifests; tvOS/TestFlight plumbing; tests. Lambda deploys first (additive), then one TestFlight wave to iOS+macOS+visionOS+tvOS. | ~1 week engineering, ~1.5 weeks calendar incl. real-car validation | Fin's notifications look like texts from a contact "Fin" with a Reply field; in the car and on AirPods Siri announces "Fin says ..." and takes a spoken reply; "Fin needs your input" is announced as time-sensitive. Nothing Fin-branded on the CarPlay screen. |
| **2 — Attention tile** | none | Live Activity target fed by `FinPresence`; foreground start (push-to-start later); Lambda `liveactivity` pushes. | 3-4 days | "Fin is working / needs your input" card in CarPlay Dashboard (iOS 26+), Dynamic Island, Lock Screen. |
| **3a — File entitlement** | Apple review, no SLA | Request voice-based conversational entitlement the day Phase 1 ships, with the Phase 1 build as evidence. | 1 hour + wait | Nothing until granted. |
| **3b — Fin icon in the car** | granted entitlement | CarPlay scene, `CPVoiceControlTemplate`, on-device speech + TTS, separate entitlements file, iOS 27 overlay. Simulator-only until granted. | ~1.5 weeks | A Fin icon on the CarPlay home screen; tap, talk, hear the answer. |
| **OS 27 (any time after 1)** | none | `.messages` schemas (all five) behind `#available(iOS 27)`, notification entity annotations. | 3-4 days once Xcode 27 SDK is in the chain | "Send a message to Fin" and "reply to that" via Siri AI on iPhone 15 Pro+/16+; car-specific behaviour unverified. |
| **iMessage** | — | Nothing. | 0 | Nothing; the "message Fin" feeling arrives with Phase 1. |

### Risks

- **Announce reliability**: third-party announce in CarPlay is user-toggled and field reports say "results vary". Fallback is a visible message-style notification, not a spoken one. Validate in a real car before calling Phase 1 done.
- **In-app SiriKit handler**: Announce's voice reply reaching `application(_:handlerFor:)` without an Intents extension is unverified end-to-end; fallback is a small Intents extension (still no Apple approval).
- **macOS communication notifications**: unverified; the Mac may keep plain alerts in the same TestFlight wave.
- **Duplicate notifications**: push-on-answered adds a fourth trigger next to daemon `/notify`, app-local banners, and CloudKit `AgentSignal` pushes; dedupe by `messageId`/foreground device is required, and answered-detection on the app-hosted site is count-based (`AppSiteClient.swift:140-149`), so an announced `replyPreview` can be the latest assistant text when turns overlap.
- **"Reply sent" is not "reply seen"**: a notification reply targets whichever agent the push named; cold cloud bodies take minutes.
- **SiriKit deprecation** (press, unverified): if real, iOS 17-26 keeps working but the reply handler's future is the `.messages` schema, which requires all five schemas and an OS 27 gate.
- **`.messages` schema floor**: documented as OS 27; do not assert 18 until checked.
- **Siri AI in CarPlay** invoking third-party intents is anecdotal, hardware-gated (iPhone 15 Pro/16+), English-only, not EU/China at launch. Nothing here depends on it; Phase 0's intents get it for free if it lands.
- **Entitlement denial**: the conversational request may fail the "designed primarily" test. No code path depends on the grant; never pivot to `carplay-communication`.
- **New extension targets** are Fin's first multi-target build: signing/provisioning on four platforms, tvOS exclusion, TestFlight scripts, privacy manifests.
- **Phase 3 in-app mic** changes the privacy nutrition label unless on-device recognition is used and is entirely new subsystem code for Fin.
- **Fin LLC account transfer** (deferred) would require re-requesting the CarPlay entitlement and re-accepting the addendum.

---

## 7. Open questions for Levi

1. **Is a spoken reply enough, or do you want a Fin icon on the CarPlay screen?** The icon is Phase 3 (Apple review, no SLA, possible denial, first in-app mic). Everything else ships without it. If spoken-only is fine we skip 3a/3b entirely.
2. **Push on every answered turn, or only on turns that started from voice / notification reply?** The design pushes on all answered messages (with dedupe). For chatty in-app sessions this may be noisy; a per-agent "announce replies" toggle is cheap if you want it from day one.
3. **Do you want the OS 27 `.messages` schemas at all** (Fin appears to Siri as a messaging app, all five schemas mandatory), or is "Ask Fin / Tell Fin to" plus the Announce reply loop sufficient? This decides whether Fin ever presents as a "messaging app" to Apple, which also affects the entitlement framing.
4. **iMessage: confirm "nothing" is the answer.** The only alternative worth building is a share-bubble extension, iOS-only, ~1 week, requiring public share links. Say the word only if you want Fin transcripts shareable into chats.
