# CarPlay Phase 0 — verify what already works (design §3.1)

Date: 2026-09-12. Design source of truth: `docs/CARPLAY-IMESSAGE-DESIGN.md` §3.1.
Phase 0 is zero app code: Fin's existing headless App Intents are what Siri runs
from the CarPlay steering-wheel voice button.

## What is installed on the iMac

| Item | Where | How verified |
|---|---|---|
| CarPlay Simulator (bundle `com.apple.CarPlaySimulator`, CFBundleVersion 4.0) | `/Applications/CarPlay Simulator.app` | copied from `Additional Tools for Xcode 26.6.dmg` (Hardware/), downloaded 2026-09-12 from developer.apple.com/download/all; dmg CRC verified by `hdiutil attach` |
| Xcode 26.6 (17F113) | `/Applications/Xcode.app` | `xcodebuild -version` |
| Fin iOS simulator build (`dev.levischoen.fin`, unsigned, Debug) | installed into the booted "iPhone 17 Pro" (iOS 26.5) simulator | `xcodebuild build -scheme fin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` through `scripts/dev/one-at-a-time.sh` |

The dmg itself is kept out of the repo (it is 75 MB); re-download from
https://developer.apple.com/download/all/?q=Additional%20Tools (needs an Apple
Developer sign-in) if a newer Xcode needs a matching simulator.

## The intents Siri exposes (`fin/Intents/SendToFinIntent.swift`)

Both intents are headless — `static let openAppWhenRun = false` at line 149
(`SendToFinIntent`) and line 192 (`AskFinIntent`) — so Siri runs them in the
background without leaving the CarPlay screen. Their only parameter is a
free-form `String` that Siri fills by dictation via `requestValueDialog`.

`FinAppShortcuts` (line 262) registers these phrases. `\(.applicationName)`
resolves to "Fin" (CFBundleDisplayName). The message is never inline in the
phrase; Siri asks a follow-up question and dictation supplies it.

**AskFinIntent — dictated question in, spoken answer out**

- "Ask Fin"
- "Ask Fin a question"

Siri then asks "What do you want to ask Fin?". After delivery the intent polls
the control-plane row (`GET /messages/{id}`) **4 times, 2 s apart (~8 s total,
lines 202-203 and 228-229)** and speaks `spokenSummary(replyPreview)` (max 320
chars) if the row is `answered`; otherwise it says "Sent to Fin. It'll reply in
the app." A reply that lands after the 8 s window is NOT spoken in Phase 0 —
that gap is exactly what Phase 1 (communication notifications) closes.

**SendToFinIntent — fire and forget**

- "Talk to Fin"
- "Have Fin …" / "Get Fin to …" (never "Tell Fin to": that is Siri's Messages phrase and it will hunt for a contact)
- "Hey Fin"
- "Fin agent"
- "Fin"

Siri then asks "What should I tell Fin?". Phrases like "Message Fin" / "Send a
message to Fin" are deliberately absent: they lose to the built-in Messages
domain (Siri hunts for a *contact* named Fin) — see the comment at lines
281-286.

## What to say in the car

Press the steering-wheel voice button (or say "Hey Siri"), then:

1. "**Ask Fin**" → Siri: "What do you want to ask Fin?" → "Are the evals green on the iMac?"
   Expect either a spoken answer (warm agent, within ~8 s) or "Sent to Fin. It'll reply in the app."
2. "**Have Fin** restart the daemon." (or "Get Fin to …") → Siri: "What should I tell Fin?" if the trailing text was not captured → dictate the instruction. Expect a short confirmation; no answer is read back.

The CarPlay screen shows **Siri's UI only**. Nothing Fin-branded appears on the
car screen in Phase 0 (or Phase 1) — do not describe it as "displaying the response".

## Announce Notifications (needed for Phase 1, harmless to turn on now)

On the iPhone: **Settings › Notifications › Announce Notifications** → turn on
**Announce Notifications**, then turn on **CarPlay** (and **Headphones** if you
also want AirPods). Under CarPlay, keep "Announce New Messages" on and
"Time Sensitive and Direct Messages" as the filter. Until Phase 1 ships Fin's
pushes are plain alerts, so nothing will be announced yet; the setting is the
prerequisite for "Fin says: … Want to reply?".

## Simulator check (what was and was not verified)

- Verified: `xcodebuild build -scheme fin -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`; `simctl install` + `simctl launch dev.levischoen.fin` on the booted iPhone 17 Pro (iOS 26.5) succeeded and `linkd` logged "App Intents enabled bundle(s) installed: dev.levischoen.fin" and indexed `fin.app/Metadata.appintents/extract.actionsdata`. That metadata contains exactly two intents, `AskFinIntent` and `SendToFinIntent`, both `"openAppWhenRun":false`, with the phrases listed above.
- Verified: a CarPlay screen for the booted simulator via **Simulator.app › I/O › External Displays › CarPlay** (window "iPhone 17 Pro – CarPlay"), captured with `xcrun simctl io <udid> screenshot --display external` → `phase0-carplay-home.png`. Fin has no icon on it — expected, Fin holds no CarPlay entitlement (Phase 3 at the earliest). `phase0-iphone-fin.png` is the phone's Home Screen with the installed build.
- **The standalone CarPlay Simulator app does not pair with the iOS Simulator.** Its "Sessions" menu shows "No Devices Connected"; it only attaches to a *physical* iPhone over USB. It is still worth having: with the iPhone plugged into the iMac it stands in for a car head unit, and Siri works on the physical phone, so steps 3-4 of the checklist below can be rehearsed at the desk before driving.
- **Not verifiable here:** Siri does not run in the iOS Simulator, so "Ask Fin" / "Have Fin" cannot be exercised through CarPlay Simulator or the simulator's CarPlay display. The intents' plumbing is covered by `finTests/VoiceIntentCoreTests.swift`; the voice loop itself needs a physical iPhone (CarPlay Simulator over USB, or a real car).

## Real-car checklist for Levi (5 steps)

1. Install the current TestFlight build of Fin on the iPhone, open it once, and
   sign in so the cloud settings and an agent named "Fin" exist. Make sure the
   agent is warm (a site is online) so the 8 s poll has a chance to hear back.
2. Plug in / connect CarPlay. On the iPhone confirm **Settings › Siri › Apps ›
   Fin** allows "Use with Ask Siri" and that Shortcuts shows "Ask Fin" and
   "Talk to Fin" under Fin (this proves the phrases are registered on-device).
3. Press the voice button: "**Ask Fin**" → answer "What do you want to ask Fin?"
   with a question that has a short, known answer (e.g. "what time is it on the
   iMac?"). Note whether Siri speaks the reply or says "Sent to Fin. It'll reply
   in the app."; either is a pass for Phase 0. Check the message appears in the
   Fin app afterwards with source "voice".
4. Press the voice button: "**Have Fin** say hello in the transcript." Confirm
   Siri acknowledges without opening the app and that the message lands in the
   app.
5. Record a short phone/dash-cam capture of steps 3-4 (audio matters more than
   video) for the App Store review notes, and note any phrase Siri misrouted
   (e.g. to Messages) so the phrase list can be tuned.

## If Siri asks "who do you want to send it to?"

Siri routed the request to Messages. That happens with "Tell Fin …" or "Send a
message to Fin" without naming the app. Use "Ask Fin …", "Have Fin …", "Hey
Fin …", or, for the Messages-style path Fin also supports since Phase 1, say
it with the app name: "Send a message to Fin **using Fin**".
