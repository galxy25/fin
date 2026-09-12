# CarPlay Phase 2 — the attention tile (Live Activity)

Implements docs/CARPLAY-IMESSAGE-DESIGN.md §3.4 / §6 row "2 — Attention
tile". Fin appears on the CarPlay screen with **no CarPlay entitlement**: on
iOS 26+ a Live Activity that opts into the `.small` supplemental family is
shown on the CarPlay Dashboard (CarPlay Developer Guide pp. 3, 9, 10; WWDC25
session 216). It doubles as the Dynamic Island / Lock Screen status.

## SDK facts verified (Xcode 26.6, iOS 26.5 SDK, 2026-09-12)

From the `.swiftinterface` files shipped in the SDK, not from memory:

| API | Module | Availability |
|---|---|---|
| `WidgetConfiguration.supplementalActivityFamilies(_:)` | WidgetKit | `@available(iOS 18.0, *)`; macOS/tvOS/watchOS/visionOS unavailable |
| `ActivityFamily.small` / `.medium` | WidgetKit | `@available(iOS 18.0, *)` |
| `EnvironmentValues.activityFamily` | WidgetKit | `@available(iOS 18.0, *)` |
| `Activity.request(attributes:content:pushType:)` | ActivityKit | iOS 16.2+ |
| `Activity.pushTokenUpdates` | ActivityKit | iOS 16.1+ |
| `Activity.pushToStartTokenUpdates` | ActivityKit | `@available(iOS 17.2, *)` |
| `ActivityAttributes` | ActivityKit | `@available(macOS, unavailable)`; no ActivityKit in the visionOS SDK |
| `WidgetConfigurationBuilder.buildLimitedAvailability` | SwiftUI | **does not exist** (only `WidgetBundleBuilder` has one) |

Consequences in the code:

- The **API** gate is `#available(iOS 18.0, *)` (not 26): the family API is
  iOS 18, and iOS 26 is the runtime that started placing the `.small` family
  on the CarPlay Dashboard. Gating at 26 would have hidden the Smart Stack
  presentation on iOS 18/25 for nothing.
- The gate lives in `FinWidgetBundle` (two widget structs, one per OS
  generation), because a single `Widget.body` cannot branch on availability.
- Everything ActivityKit in the app is `#if os(iOS)`; the shared attributes
  file is a plain Codable struct everywhere and adopts `ActivityAttributes`
  only on iOS.

## Pieces

| File | Role |
|---|---|
| `fin/LiveActivity/FinActivityAttributes.swift` | `FinActivityAttributes {agentName, agentID}` + `ContentState {headline, detail, glyph, status, updatedAt}` — compiled into the app AND `fin-widgets` |
| `fin/LiveActivity/FinActivityViews.swift` | Lock Screen banner, `.small` tile, Dynamic Island pieces — shared, render-tested from the app |
| `fin/LiveActivity/FinLiveActivityPlan.swift` | Pure: presence → content state; start/update/end tracker (2-minute quiet grace) |
| `fin/LiveActivity/FinLiveActivityController.swift` | iOS-only `@MainActor` shell: polls `SiteDirectory` while foregrounded, drives ActivityKit, uploads tokens |
| `fin-widgets/` | The WidgetKit extension (`dev.levischoen.fin.widgets`), iOS only, embedded with `platformFilter: iOS` |
| `fin/fin-widgets.entitlements`, `fin-widgets/PrivacyInfo.xcprivacy` | Empty entitlements, no-API privacy manifest |
| `project.yml` | Target, embed, `NSSupportsLiveActivities` on the app |
| `scripts/cloud-agent/control-plane/lambda.py` | `kind`/`activityId` on `PUT /device-tokens`; `_push_live_activity`; heartbeat + answered-ack hooks |

## Token flow, end to end

1. **App foregrounds** → `FinLiveActivityController.appDidBecomeActive()`:
   installs observers once, adopts any activity already running (a previous
   launch, or one the control plane started by push), and starts a 15 s poll
   of `SiteDirectory.shared.refresh()` (`GET /sites`).
2. Each sample is folded with `FinPresence.fold` and stepped through
   `FinLiveActivityPlan.Tracker`: working/needs-input starts (once) or updates
   (on content change, timestamps ignored); idle/asleep updates the tile to
   "Fin is ready" once and ends it after 120 s of quiet.
3. **Push-to-start token** (iOS 17.2+): `Activity<FinActivityAttributes>
   .pushToStartTokenUpdates` → `PUT /device-tokens {token, platform,
   deviceName, deviceId8, kind: "activity-start"}`.
4. **Per-activity update token**: on every activity the app starts or adopts,
   `activity.pushTokenUpdates` → `PUT /device-tokens {…, kind:
   "activity-update", activityId}`. Same table (`fin-device-tokens`, token is
   the hash key); the alert fan-out skips non-`alert` rows.
5. **Control plane** — `_push_live_activity(user_id, content_state, event)`
   sends `apns-push-type: liveactivity` on topic
   `dev.levischoen.fin.push-type.liveactivity`, payload
   `{aps: {timestamp, event, content-state, attributes-type+attributes
   (start), dismissal-date (end), alert?}}`:
   - from `POST /sites/{id}/heartbeat` when the **user's folded presence**
     changes (`_presence_fold` mirrors `FinPresence.fold`): `update` to every
     running activity, `start` to devices without one (10-minute cooldown per
     device so a device that never registers its update token doesn't collect
     tiles), `end` (lingering 120 s) when everything is idle;
   - from an answered `POST /messages/{id}/ack` as a "Fin answered" `update`
     to running activities only (never starts one).
   Dead tokens are deleted like alert tokens; an `end` also deletes the update
   tokens it reached. Every call is best-effort and never fails the caller.
6. Back in the app, `Activity.activityUpdates` surfaces push-started
   activities so their update token gets registered (step 4).

Choice made: one route with a `kind` field rather than a new
`/live-activity-tokens` route — the table already keys by token and stamps
`userId`/`deviceId8`, the environment-discovery and dead-token sweep are
reused verbatim, and old builds keep sending the three-key shape unchanged.

## Not verified here

- **A real CarPlay Dashboard render.** Needs a car or the CarPlay Simulator
  (/Applications/CarPlay Simulator.app) attached to an iOS 26 device/simulator
  with a Live Activity running. Screenshots go in this folder when captured.
- **Push-to-start delivery** to a closed app on a physical device with the
  production APNs environment (TestFlight build). Sandbox/production
  discovery is inherited from the alert path.
- `NSSupportsLiveActivitiesFrequentUpdates` is deliberately not set: heartbeat
  transitions are minutes apart, well inside the normal budget.
