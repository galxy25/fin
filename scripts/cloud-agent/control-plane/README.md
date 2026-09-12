# Cloud-worker control plane

A serverless front door for the cloud agents `../launch.sh` launches by hand: one
Lambda (`lambda.py`) behind an API Gateway HTTP API, a DynamoDB table of worker
records (`fin-cloud-workers`), and an EventBridge schedule that terminates idle
workers every 10 minutes.

Launching through the API produces the same instance `launch.sh` does — AL2023
arm64 from the SSM alias, the egress-only `fin-agent-egress` group, the SSM-only
`fin-agent-ssm` profile, IMDSv2 required, binary and config fetched at boot over
presigned URLs — plus the tags the sweep needs (`fin-managed=control-plane`,
`fin-idle-minutes`). The presigned URLs are signed by the Lambda role and expire
in an hour; the instance role still holds no S3 permission of its own.

```
./deploy.sh          # idempotent; prints the endpoint and the token file path
```

`deploy.sh` needs the `fin-agent-egress` security group and the `fin-agent-ssm`
instance profile to exist. `launch.sh` creates both on its first run; the Lambda
deliberately cannot, and answers 503 if either is missing.

## Routes

Every route needs `authorization: Bearer <token>`. The token lives in
`~/.fin-control-plane-token` (mode 600) — read it from the file, never paste it
into a command line or a commit.

```sh
API=https://<api-id>.execute-api.us-west-2.amazonaws.com
AUTH="authorization: Bearer $(cat ~/.fin-control-plane-token)"

# launch a worker (instanceType defaults to t4g.nano, idleMinutes to 30)
curl -sS -X POST "$API/workers" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent": "fin-agentd-1", "instanceType": "t4g.micro", "idleMinutes": 45}'

# every worker, live and dead, most recent first, with uptimeSeconds
curl -sS "$API/workers" -H "$AUTH"

# terminate one
curl -sS -X DELETE "$API/workers/<workerId>" -H "$AUTH"

# uptime and estimated spend, per agent and per instance type
curl -sS "$API/usage" -H "$AUTH"

# run the idle sweep now instead of waiting for the schedule
curl -sS -X POST "$API/sweep" -H "$AUTH"

# vend short-lived presigned S3 URLs (kinds and agent both optional)
curl -sS -X POST "$API/presign" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent": "Nimbus", "kinds": ["inbox", "supervisionDirective"]}'

# model-factory ingest: opt-in, pre-redacted app telemetry (FROZEN contract —
# see scripts/model-factory/README.md for the full spec and privacy rules)
curl -sS -X POST "$API/feedback" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"kind": "user_feedback", "rating": 1, "comment": "routed correctly",
       "payload": null, "appVersion": "1.4.0", "platform": "ios",
       "createdAt": "2026-09-05T17:00:00Z"}'

# store or rotate a service credential (write-only; see below)
curl -sS -X PUT "$API/secrets/gmail" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agentScope": "Nimbus", "kind": "app-password", "username": "levi@example.com",
       "value": "abcd efgh ijkl mnop", "note": "Gmail app password for Nimbus"}'

# list credential METADATA (never values); ?agentScope=Nimbus to filter
curl -sS "$API/secrets" -H "$AUTH"

# schedule a credential for deletion (7-day recovery window)
curl -sS -X DELETE "$API/secrets/gmail?agentScope=Nimbus" -H "$AUTH"

# register this device's APNs token (the app does this itself on every launch)
curl -sS -X PUT "$API/device-tokens" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"token": "<64 hex chars>", "platform": "iOS", "deviceName": "iPad"}'

# push one alert to every registered device (what fin-agentd's notify client calls)
curl -sS -X POST "$API/notify" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"title": "Nimbus needs input", "body": "Which branch should I deploy?",
       "agent": "Nimbus"}'
```

`POST /workers` refuses with 409 when the agent already has a live worker. When
there is no config at `fin/agentd/<agent>.json`, it **auto-provisions** one from
the template (next section); only when the template is missing too does it
refuse, with a 400 that says so plainly (the instance would boot, fail the
fetch, and bill for nothing). `instanceType` is restricted to the priced t4g
sizes below. Note the default is `t4g.nano`, one size below `launch.sh`'s manual
`t4g.micro` — nano's 0.5 GiB is tight for the harness, so pass `instanceType`
explicitly if a worker dies on memory. The agent name `shared` (any case) is
refused: it is reserved as the everyone-readable secret scope (below).

## Sites

A **site** is one body that can act as an agent — an EC2 worker, the resident
daemon on a Mac, a BYO box, an app install. See `docs/SITES.md` for the design;
this is Phase 1a, the registry only. Dispatch, primary election and the claim
protocol are Phase 1b and do not exist yet, so nothing here routes a message.

```sh
# enroll (operator token). Idempotent by enrollKey: re-running the installer
# returns the SAME site with a fresh token, it does not add a row.
curl -sS -X POST "$API/sites/enroll" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent":"Fin","kind":"resident","displayName":"Levi'"'"'s iMac",
       "enrollKey":"levis-imac/deepspacenine"}'

# the caller's own sites, highest priority first
curl -sS "$API/sites" -H "$AUTH"

# queue a lifecycle command; it is delivered on the site's next heartbeat
curl -sS -X POST "$API/sites/<siteId>/commands" -H "$AUTH" \
  -H 'content-type: application/json' -d '{"kind":"restart"}'

# retire it — this also destroys the stored token hash, so it IS the revocation
curl -sS -X DELETE "$API/sites/<siteId>" -H "$AUTH"
```

The heartbeat is the site's own call, authenticated with the **site token**
returned by enroll plus an `X-Fin-Site` header naming itself:

```sh
curl -sS -X POST "$API/sites/<siteId>/heartbeat" \
  -H "authorization: Bearer <siteToken>" -H "X-Fin-Site: <siteId>" \
  -H 'content-type: application/json' \
  -d '{"state":"working","capabilities":{"daemon_version":"1.5.0"}}'
```

It renews the 60-second lease from the Lambda's own clock (sites send
durations, never timestamps), records what the body can reach, drains any
queued commands exactly once, and re-signs the site's presigned URLs when the
site reports they are within 20 minutes of expiry.

A site token is scoped to **that one body**: its own heartbeat, its own
retirement, `/presign` and `/notify`. It cannot list its siblings, enroll new
sites, queue commands, or touch `/workers`, `/secrets` or `/memory` — the
allow-list in `_require_site_scope` is deny-by-default and is the entire
boundary, since a site token attaches its owner's `userId` exactly like a
session token does. Revoke one by re-enrolling (rotates) or retiring (destroys).

### For a supervisor (Phase 3)

An external supervisor reads **`GET /sites`** for presence and **`GET
/messages?agent=`** for the queue — not `fin/status*.json` and not the inbox
object. Both are gone: `fin/inbox/*`, `fin/status-*.json` and the whole-document
`fin/transcripts/{agent}.jsonl` were archived under `users/{u}/fin/_retired-2026-09-12/`
and deleted. The directive document (`fin/directives.json`) is unchanged.
Per-site work goes through `POST /messages` with `context.siteHint`.

Site-side `update` needs a published binary: `scripts/mac-fin-agentd/publish-binary.sh`
uploads `fin/agentd/fin-agentd-macos-arm64` and its `.sha256` sidecar; queue
`{"kind":"update"}` on a site and it verifies, renames, and restarts.

## Messages (the claim protocol)

Phase 1b of `docs/SITES.md`. A message is applied by **at most one body**; the
thing that decides which is a conditional write on the message row, never
"whoever polled first". Roles (primary/standby) route; claims exclude.

```sh
# send (operator/session token). messageId is optional; supply your own
# m-<uuid> and a retry is a no-op. context is optional routing context.
curl -sS -X POST "$API/messages" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"agent":"Fin","text":"what is the main session doing?","source":"app",
       "context":{"device_id8":"a4a1d987","activeSessionNames":["main"],"siteHint":null}}'
# -> {messageId, state:"queued", routedBy:"hint"|"context"|"primary"|"clarify"|null,
#     pinSiteId?, targetSiteId?, targetSiteName?, clarifyCandidates:[...]}

# poll one, or list the newest 50 for the console
curl -sS "$API/messages/<messageId>" -H "$AUTH"
curl -sS "$API/messages?agent=Fin" -H "$AUTH"
```

Routing (`_pin_for`, pure): a `siteHint` naming a live site pins to it; else
the text plus `activeSessionNames` is matched whole-word against every live
site's `capabilities.tmux_sessions[].session|tasks` — exactly one match pins,
several yield `routedBy: "clarify"` with candidate display names, none leaves
the row unpinned and targeted at the live primary. No live site at all still
queues the row; the app shows Fin asleep.

The site side, all with the site token + `X-Fin-Site`:

```sh
# the heartbeat carries the queue: wantsPrimary, held ids (leases renewed),
# unacked ids (acked under claimedBy=me before anyone else is offered them),
# and returns role, the eligible messages[], and legacyInboxGet for the primary
curl -sS -X POST "$API/sites/<siteId>/heartbeat" -H "$SAUTH" -H "X-Fin-Site: <siteId>" \
  -d '{"state":"working","wantsPrimary":true,"held":["m-…"],"unacked":[]}'

curl -sS -X POST "$API/messages/<id>/claim"    -d '{"leaseSeconds":120}'   # 200 {granted:true} | 409
curl -sS -X POST "$API/messages/<id>/ack"      -d '{"state":"applied","runId":"…"}'
curl -sS -X POST "$API/messages/<id>/ack"      -d '{"state":"answered","replyPreview":"…"}'
curl -sS -X POST "$API/messages/<id>/register" -d '{"text":"…"}'   # legacy-inbox lane, primary only
```

Eligibility per heartbeat (`_eligible`, pure): a `queued` row, or a `claimed`
one whose lease lapsed, is offered to site X iff it is pinned to X; or unpinned
and targeted at X; or unpinned with a dead/absent target and X is primary; or
no primary is alive at all and X is. Acks only move forward and only from the
claimant; an applied row can never be reclaimed however stale its lease.

`create_worker` no longer resets `fin/inbox/{agent}.json`. The sweep marks a
site silent for three leases `stale` — never terminates it.

## Threads

`docs/THREADS.md`: a thread is one user request plus everything it caused,
across the user, Fin's sites, the panes Fin relays into, and operator
sessions. Identity is `threadId` on every `fin-messages` row (a root's is its
own `messageId`; a row written before threads existed reads as its own root).
Status is derived on read, never stored.

**Membership.** `POST /messages` takes an optional `threadId` — any message id
of the thread, resolved to its root; a foreign, unknown, or other-agent id is a
400. Otherwise the message roots a new thread. At `applied` ack time the site
may propose `threadId` (+ `threadReason`, ≤ 40 chars, e.g. `pane:main:2.0`)
for a message that relayed into the same pane as an earlier request; explicit
membership chosen by the sender always wins. The decision is logged once per
message as `thread.assigned` with reason `explicit | <threadReason> | root`.

**Events** (`fin-thread-events`, hash `threadId`, range `seq`, TTL 30 days) —
one row per transition, written only by the Lambda, `seq` allocated by an
atomic counter on the thread's root message row (`ADD threadEventSeq`), so it
is strictly monotonic per thread with no extra table. Every write also prints
one `{"thread_event": {...}}` line to CloudWatch. Best-effort: a bookkeeping
failure never fails the route that caused it.

| kind | actor | written by | detail |
|---|---|---|---|
| `message.queued` | device id8 / `user` | `POST /messages`, `/register` | messageId, source, routedBy, targetSiteId, authorSiteId8 |
| `message.claimed` | site id8 | `/claim` (first claim only; renewals are not transitions) | messageId, siteId8, claimedBy |
| `message.applied` | site id8 | `/ack applied`, heartbeat `unacked` | messageId, siteId8, runId |
| `thread.assigned` | `system` | `/ack applied` | messageId, threadId, reason |
| `message.answered` | site id8 | `/ack answered` | messageId, siteId8, replyPreview (≤ 200), pushed |
| `notify.sent` | site id8 / `operator` | `POST /notify` | event, title, body (≤ 200), delivered, failed, suppressed, messageId, threadId |
| `goal.followup` | site id8 / `operator` | `PUT /agents/{agent}/goals` (a `g-followup-*` goal the previous version lacked) | goalId, title, nextAction (≤ 200), target |
| `relay.sent` / `relay.read` | site id8 | `PUT /transcript-chunk` (new `toolCall` lines for `send_session` / `read_session` carrying `target`) | target, text (≤ 200), lineId, runId, inReplyTo, threadId |

`POST /notify` takes optional `threadId` (or resolves it from `messageId`);
the APNs payload then carries `fin.threadId` and `aps.thread-id` = the thread
(the per-agent id is the fallback grouping), so the Lock Screen groups by
request. The answered-ack push does the same.

**Routes** (session, operator, and site tokens; a site may only read):

```sh
curl -sS "$API/threads?agent=Fin&limit=20" -H "$AUTH"
# -> {agent, threads:[{threadId, agent, title (first message, ≤ 80), status,
#     messageCount, lastActivityAt, createdAt, participants:[...], openGoal?}]}
#    newest activity first, at most 50
curl -sS "$API/threads/<threadId>" -H "$AUTH"
# -> {thread:{...same summary...}, messages:[public rows, oldest first],
#     events:[oldest first — the thread's own plus the early events of members
#     that were rooted alone before ack time moved them]}
curl -sS "$API/threads/<threadId>/events?after=<seq>" -H "$AUTH"   # debug tail
```

**Status** (`_thread_status(messages, events)`, pure, in precedence order):

| status | when |
|---|---|
| `waiting_on_you` | the last event is `notify.sent` with event `request-input` |
| `stalled` | the last event is `notify.sent` with event `agent-stalled` (outranks an open message: the stall *is* that message's state) |
| `working` | any message still `queued` / `claimed` / `applied`, or the last event is `goal.followup` |
| `answered` | otherwise |

`openGoal` is the latest `goal.followup` goal id with no `message.answered`
after it. Participants are the distinct actors in first-seen order: user
device id8s (or `user` when no device is known), site id8s, pane targets,
`operator`.

## Auto-provisioning

The app lets any agent be set to Cloud Harness and delivers mail to its
per-name inbox, so `POST /workers` has to work for any agent name — not just
the hand-provisioned ones. On a config head-check miss the Lambda instantiates
`s3://<bucket>/fin/agentd/_template.json`: it parses the template, substitutes
the `{{…}}` placeholders at the JSON level (never by templating the raw text,
so substitution cannot corrupt the document), and PUTs the result to
`fin/agentd/<slug>.json` with bucket-default SSE, a
`fin-autoprovisioned` metadata marker, and an `If-None-Match` guard — an
existing config is **never** overwritten, even by a concurrent launch losing a
race. The launch then proceeds exactly as if the config had been there all
along; the Lambda logs one line, `auto-provisioned config for <agent>`.

`../make-config-template.sh [source-slug]` (default `nimbus`) generates the
template from a live hand-provisioned config and uploads it S3-to-S3, so the
shared LLM bearer token inside never lands in git. The placeholders and what
fills them:

| placeholder | filled with |
| --- | --- |
| `{{AGENT}}` | display name as given to `POST /workers` |
| `{{AGENT_SLUG}}` | lowercased name (tmux session; the key slug) |
| `{{AGENT_ID}}` | fresh UUID (the daemon requires a parseable `agentID`) |
| `{{DEVICE_TOKEN8}}` | fresh 8-char device stamp |
| `{{DIRECTIVE_GET_URL}}` | presigned GET `fin/directives.json` |
| `{{STATUS_PUT_URL}}` | presigned PUT `fin/status-<slug>.json` |
| `{{INBOX_GET_URL}}` | presigned GET `fin/inbox/<slug>.json` |
| `{{TRANSCRIPT_PUT_URL}}` | presigned PUT `fin/transcripts/<slug>.jsonl` |

The Lambda also sets `supervision.inboxResetAtLaunch: true` on the instantiated
config when the template doesn't say either way: `POST /workers` empties the
per-agent inbox right before the launch, and that flag is how fin-agentd 1.4.1+
knows a message it finds in the inbox on its first run arrived while the worker
booted (deliver it) rather than being backlog (seed it as history — the
resident-install rule). A **hand-provisioned** config launched through
`POST /workers` needs the flag added by hand; one launched with `launch.sh`
(which does not reset the inbox) must leave it off.

Sharp edges:

- **Auto-provisioned agents share the template's LLM route.** The template
  preserves `agent.endpointURL`, `agent.apiKey`, and the model parameters from
  its source config as shared infrastructure — every auto-provisioned agent
  talks to the same backend with the same token. The same goes for a
  `controlPlane` push block when the source config carries one: one control
  plane serves every agent. An agent that needs its own route still needs a
  hand-provisioned config.
- **The presigned URLs inside an auto-provisioned config are signed by the
  Lambda role's temporary credentials** and die with them (hours in practice,
  whatever the stated week-long expiry says) — unlike the operator-minted URLs
  in a hand-provisioned config. And since an existing config is never
  overwritten, a *relaunch* days later boots against dead supervision URLs and
  gets swept for silence. For a long-lived or frequently relaunched agent,
  hand-provision the config; to force a fresh instantiation, delete
  `fin/agentd/<slug>.json` and launch again (the `fin-autoprovisioned` object
  metadata tells you which configs are safe to delete that way).

## Browser workers

`POST /workers` takes an optional `"browser": true`, which appends a bootstrap
block installing headless chromium + playwright (python) on the AL2023 instance
— after the harness is enabled, so the chromium download never delays the
status object the sweep's boot grace waits on. It requires `instanceType` of at
least `t4g.small` (400 otherwise): chromium in nano/micro's 0.5–1 GiB dies on
memory and bills for nothing, the same refuse-before-spending logic as the
config head-check. The default stays browserless, so nano workers keep their
90-second boot. Browser workers are tagged `fin-browser=1` and their records
carry `"browser": true`.

The boot runs an inline smoke check (load `https://example.com`, assert the
title) and logs `BROWSER SMOKE OK` / `BROWSER SMOKE FAILED` to
`/var/log/cloud-init-output.log` without failing the boot. The same check lives
in `../browser-smoke.py` as a standalone script — the empirical-verification
primitive: run it on the worker over SSM whenever you need proof the browser
stack really works, rather than trusting that the install succeeded. The manual
path has it too: `../launch.sh <agent> <config-key> t4g.small browser`.

## Push notifications (APNs)

The loop from a headless agent back to a human. The app registers its APNs
device token with `PUT /device-tokens` on every launch (tokens rotate; the
token is the `fin-device-tokens` table's hash key, so re-registration is a
dedupe-by-overwrite), and `POST /notify` — called by fin-agentd's
`DaemonNotifyClient` when its config carries a `controlPlane` block — fans one
alert out to every stored token.

- **Routes.** `PUT /device-tokens` takes `{"token": "<hex>", "platform":
  "iOS|macOS|visionOS", "deviceName"?: "…", "deviceId8"?: "<8 hex>"}`; the token
  is validated as hex and lowercased; `deviceId8` is the device's own
  `DeviceIdentity.short`, stored so an answered ack from that device can skip
  its own tokens (absent from pre-Phase-1 builds, which dedupe in-app instead). `POST /notify` takes `{"title", "body", "agent"?, "agentID"?,
  "originDeviceID8"?, "event"?, "messageId"?}` — overlong title/body are
  truncated (the sender is an unattended daemon with nobody there to shorten
  and retry), and the 200/502 body reports `{"delivered", "failed", "removed",
  "reasons"}`: counts and APNs reason strings only, never a token. 502 means
  tokens exist but nothing got through, so the daemon's audit trail records
  the outage. `event` is one of `request-input`, `task-complete`,
  `agent-stalled`, `notify`, `answered` (absent/unknown reads as `notify`) and
  picks the APNs `category` (`fin.input` for the two "needs you" events, which
  also get `interruption-level: time-sensitive`; `fin.reply` otherwise).
  Every push carries `mutable-content: 1` (routes it through the app's
  notification service extension), `thread-id: <agentID>` when known, and a
  custom `fin` dict with `agentID`/`originDeviceID8`/`agentName`/`messageId`
  as available. `messageId` names the `fin-messages` row the push reports on:
  the control plane pushes each message's reply **once** — the answered ack
  (`POST /messages/{id}/ack {"state":"answered","replyPreview":…,"agentID"?,
  "originDeviceID8"?}`) pushes title = agent name, body = the preview,
  category `fin.reply`, `thread-id` + `fin.agentID` from the ack's `agentID`
  (what a tap deep-links on and a typed Reply is addressed to — send it), and
  whichever of that ack or a `/notify` carrying the same `messageId` arrives
  first wins (the daemon's request-input push for a claimed message counts:
  the time-sensitive question is the push worth keeping, the closing text's
  fin.reply is the one suppressed); the other is suppressed (`"suppressed":
  true` on `/notify`; silently on the ack, whose push is best-effort and never
  fails the ack). The claim is given back when a push reaches nobody (APNs
  down, 502, no tokens), so `suppressed` always means a push for that message
  actually landed (or is in flight) — never that one was merely attempted.
  `originDeviceID8` names the answering device: its own tokens (registered
  with the matching `deviceId8`, below) are left out of the fan-out, since it
  hosted the turn and already showed the reply. Not gated on the message's
  `source`: a reply to an app-typed question pushes the same way a voice one
  does.
- **Live Activity tokens (Phase 2, the CarPlay Dashboard tile).** The same
  `PUT /device-tokens` route takes an optional `"kind"`: absent or `"alert"`
  is the APNs alert token above; `"activity-start"` is the device's ActivityKit
  push-to-start token (iOS 17.2+, one per device); `"activity-update"` with
  `"activityId"` is one running Live Activity's update token. All three live
  in `fin-device-tokens` (the token is still the hash key); `_push_to_user`
  sends alerts only to `alert` rows and `_push_live_activity` only to the two
  activity kinds, so neither fan-out can burn the other's tokens. Activity
  pushes go to the `dev.levischoen.fin.push-type.liveactivity` topic with
  `apns-push-type: liveactivity` and an `aps` of `{timestamp, event:
  start|update|end, content-state: {headline, detail, glyph, status, updatedAt},
  attributes-type + attributes (start only), dismissal-date (end only), alert?}`
  — the content-state keys are `FinActivityAttributes.ContentState` verbatim
  (`updatedAt` is epoch seconds as a number). They are sent, best-effort and
  never failing the caller, from `POST /sites/{id}/heartbeat` whenever the
  user's folded presence (needs-input > working > idle, `FinPresence.fold`
  mirrored in `_presence_fold`) changes — `update` to running activities,
  `start` to devices with none, `end` (lingering 120 s) when Fin goes quiet —
  and from an answered ack as a `"Fin answered"` update to running activities
  only. A token APNs reports dead is deleted like an alert token; an `end`
  also deletes the update tokens it reached, since an ended activity's token
  is spent.
- **Transport.** APNs' token-based HTTP/2 API. The stdlib has no HTTP/2 client
  and APNs speaks nothing else, so `deploy.sh` vendors `httpx[http2]` into the
  Lambda zip, plus `ecdsa` to sign the ES256 provider JWT — all pure python,
  no compiled wheels, so the zip builds identically on any machine. The JWT is
  cached per warm container and refreshed after 40 minutes (Apple's window is
  20–60).
- **Environments.** A TestFlight build's token lives in APNs production, a
  devicectl debug build's in the sandbox, and the registration carries no
  reliable marker of which — so each token is tried against production first
  and retried against sandbox on `BadDeviceToken`. The discovered environment
  is stored on the token row; later notifies go straight there. Tokens APNs
  declares dead (`Unregistered`, `ExpiredToken`, `DeviceTokenNotForTopic`, or
  `BadDeviceToken` in both environments) are deleted — the app re-PUTs a live
  token on its next launch.

**The one manual step**: create an APNs auth key, once. At
[developer.apple.com](https://developer.apple.com/account) → Certificates,
Identifiers & Profiles → **Keys** → **+**, name it, check **Apple Push
Notifications service (APNs)**, register, and download `AuthKey_<KEYID>.p8` —
Apple hands the file out exactly once, at creation. Then either

```sh
mkdir -p ~/.appstoreconnect/apns && mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/apns/
./deploy.sh
```

or point `FIN_APNS_KEY_PATH` at the file and run `./deploy.sh`. The key id is
parsed from the filename; the team id (`EC27UF79GL`) and topic
(`dev.levischoen.fin`, the app's bundle id) are baked-in defaults, overridable
via `APNS_TEAM_ID` / `APNS_TOPIC`. Without the key the deploy still succeeds:
token registration, storage, and every other route work — only `POST /notify`
answers `503 APNs key is not configured`.

## Key vault (sealed SSH keys for devices without iCloud Keychain)

tvOS is excluded from iCloud Keychain, so the Apple TV cannot receive the
user's SSH private keys the way every other Fin device does. The vault is how
they get there without a local network in the loop:

- Every keychain-holding device seals each key with the account's **vault
  key** — 32 random bytes that live only in the user's private CloudKit
  database (`RemoteInputPairing`, name frozen for schema reasons) — and
  `PUT /vault/keys/{keyId}` the ciphertext (`{"name","keyType","ciphertext"}`,
  base64, ≤ 64 KB). The app does this once per key at import/generation and
  sweeps at launch (`KeyVaultSync`).
- The Apple TV signs in with Apple (`POST /auth/apple`), `GET /vault/keys`,
  and opens each entry with the vault key CloudKit delivered (`TVCloudAccount`).
- `DELETE /vault/keys/{keyId}` is idempotent.

The service holds ciphertext only (ChaChaPoly, HKDF-derived key, key id as
associated data — `fin/Vault/KeyVault.swift`). Session tokens only: a site
token is denied by `_require_site_scope`, since a body has its own SSH
identity (`fin-agent-ssh-key`) and never needs the user's.

## Service credentials (write-only secret store)

Third-party credentials a worker needs — a Gmail app password, an API key, an
OAuth refresh token — live in AWS Secrets Manager under
`fin/service-creds/<agentScope>/<service>`:

- `agentScope` is the agent's key slug (the display name validated against the
  same rule as `POST /workers`, then lowercased: `Nimbus` → `nimbus`), or the
  reserved scope `shared`, readable by every worker. Omitted anywhere it is
  accepted, it defaults to `shared`.
- `service` matches `[a-z0-9][a-z0-9-]{0,39}` — e.g. `gmail`,
  `app-store-connect`.
- Encryption is the default `aws/secretsmanager` KMS key: same-account access
  needs zero extra KMS policy, nothing to deploy.

**The API is write-only, and not just in code.** No route ever returns a secret
value, no handler logs one, and the Lambda role holds no
`secretsmanager:GetSecretValue` at all — even a code regression in `lambda.py`
could not leak a value through this API. The read path belongs to the workers
alone: `launch.sh` grants the `fin-agent-ssm` instance role `GetSecretValue`
scoped to `fin/service-creds/*` and nothing else (re-run `launch.sh` once after
this change so an existing role picks the policy up). On a worker:

```sh
aws secretsmanager get-secret-value \
  --secret-id fin/service-creds/shared/gmail \
  --query SecretString --output text
```

The SecretString is a flat JSON object of string fields —
`{"value": "…", "username": "…"}` — the shape a runner's `{{secret:…}}`
placeholder resolution addresses. Today every worker can read every scope (all
workers share the one `fin-agent-ssm` role); per-agent read isolation means
per-agent instance roles and is future work.

### The routes

- `PUT /secrets/{service}` — body `{"value": "…", "username"?: "…",
  "privateKey"?: "…", "publicKey"?: "…", "note"?: "…", "agentScope"?: "Nimbus",
  "kind"?: "app-password"}`. `value` (or `privateKey` — the shape Fin's key
  uses, below) is required; each field is capped at 4 KB and the whole secret
  at 64 KB (the Secrets Manager hard limit). `kind` is one of `app-password | oauth |
  api-key | password` (default `password`) and is stored as a tag, so listing
  never touches values. 201 on create, 200 on update; the response is
  `{"service", "agentScope", "kind", "lastUpdated"}` — never the value, never
  the ARN. A re-PUT during a pending deletion restores the secret first, then
  overwrites it. **`note` (≤ 200 chars) is stored as the Secrets Manager
  Description and comes back as `label` from `GET /secrets`: it is metadata,
  visible to anything that can list secrets and NOT encrypted like the value —
  never put a credential in it.**
- `GET /secrets[?agentScope=Nimbus]` — metadata only: `service`, `agentScope`,
  `kind`, `label`, `lastUpdated`, `lastAccessed` (day granularity, from
  Secrets Manager's `LastAccessedDate` — the app's "the worker actually read
  this" signal), plus `deletionScheduled` while a delete is pending.
- `DELETE /secrets/{service}?agentScope=Nimbus` — schedules deletion with a
  7-day recovery window, never force-delete; 200 `{"service", "agentScope",
  "deletionDate"}`, 404 when absent, and idempotent — deleting an
  already-scheduled secret answers the same 200.

### Fin's key (`fin-agent-ssh-key`)

The reserved service `fin/service-creds/shared/fin-agent-ssh-key` is the SSH
identity the app generates under **Fin's Key** (in any agent's editor): an
ed25519 key pair stored with `kind: api-key` and fields
`{"privateKey": "…", "publicKey": "…"}` instead of `value`/`username`. The user
grants their Fin access to a computer by appending the public line to that
computer's `~/.ssh/authorized_keys` (the app hands them the one-line command),
and revokes it by deleting that line — the key's comment, `fins-key`, is the
grep handle.

At boot, **before** `fin-agentd` starts, the worker bootstrap (both copies —
`launch.sh` and this Lambda's `USER_DATA`; `../check-userdata-parity.py`
verifies they match) fetches the secret with the instance role's
`GetSecretValue` and installs the private key at
`/home/fin-agent/.ssh/fin_agent_ed25519` (0600, owned `fin-agent`). A config's
`server.privateKeyPath` can point there to let a cloud worker reach the same
computers the user granted. A missing secret is a clean no-op: workers without
a provisioned key boot exactly as before.

Write-only like every secret here: the app shows only `GET /secrets` metadata
(provisioned/last-read dates) and re-provisions by re-PUT. Redeploy the Lambda
(`./deploy.sh`) once after this change so `PUT /secrets` accepts the
`privateKey`/`publicKey` fields.

### Rotation and staleness

There is no rotation Lambda on purpose: these are third-party credentials AWS
cannot rotate. Rotation is a user-driven re-PUT from the settings page, and
Secrets Manager versioning keeps `AWSPREVIOUS` automatically. The app should
badge staleness from `lastUpdated` — a nudge at ~180 days is the suggested
default.

### Which credential shape to store

Prefer, in this order: **OAuth** (a refresh token the service minted for this
exact purpose), an **app password** (a per-app secret like Gmail's, minted
under the account's 2FA), an **API key** — and the account's primary password
only as a last resort. App passwords and OAuth tokens are revocable without
touching the account, skip interactive 2FA at use time entirely, and cap the
blast radius of a compromised worker to one service instead of one identity.
For Gmail specifically: an app password (requires 2-Step Verification on the
account) is the recommended shape for SMTP/IMAP; OAuth for anything using the
Gmail API.

### 2FA relay (design, not yet implemented)

Some browser flows will still hit an interactive second factor no stored
credential can answer. The worker never holds a TOTP seed or a recovery code —
that would turn a per-service secret into account takeover material. The design
instead relays the human factor through the channel that already exists:

1. The harness's browser flow hits a 2FA prompt and parks.
2. The harness surfaces `needs-2fa` (service + prompt context, never
   credentials) through its status object and transcript, which the app renders
   as a push to Levi.
3. Levi answers through the agent's inbox (`fin/inbox/<agent>.json`) with the
   one-time code; the harness types it into the parked flow and discards it.

Relaying a code this way is materially different from storing a credential:
codes are single-use and expire in seconds-to-minutes, so nothing durable ever
rides the channel or rests on the instance. Implementing the park/resume state
machine in the daemon is follow-up work; nothing in this API needs to change
for it.

## Presigned URLs

`POST /presign` hands the app the same kind of short-lived S3 URLs the launch
bootstrap uses, so the app can read and write the agent's channel objects without
holding any S3 permission of its own. The body is `{ "agent": "<name>", "kinds":
[...] }` and both fields are optional:

- `kinds` omitted returns every kind the request can satisfy — the agent-scoped
  kinds only when `agent` is present, the supervision kinds always.
- `agent` must match the `[A-Za-z0-9][A-Za-z0-9._-]{0,62}` name rule (the same one
  `POST /workers` enforces, so a presign can never traverse out of the key space).
  It is required for `transcript`, `inbox`, and `status`, and ignored for the
  app-wide supervision kinds.

The five kinds map to these objects and methods:

| kind | object | response fields |
| --- | --- | --- |
| `transcript` | `fin/transcripts/<agent>.jsonl` | `transcriptGet` |
| `inbox` | `fin/inbox/<agent>.json` | `inboxGet`, `inboxPut` |
| `status` | `fin/status-<agent>.json` | `statusGet` |
| `supervisionDirective` | `fin/directives.json` | `supervisionDirectiveGet` |
| `supervisionStatus` | `fin/status.json` | `supervisionStatusPut` |

The 200 body is `{ "generatedAt", "expiresAt", "ttlSeconds", "urls": {...} }`,
with only the requested (or applicable) fields present under `urls`. The URLs are
signed by the Lambda role and expire in an hour — but like the boot URLs they die
with the Lambda's temporary credentials even before that, so the app re-requests
on demand rather than caching them. An unknown kind, or an agent-scoped kind with
a missing or malformed `agent`, is a 400.

## Model-factory ingest

`POST /feedback` is the app's one door into the model-factory data lake
(`fin-model-factory-011183829623` — a separate bucket from the agent channel,
with a 180-day expiry on `raw/`). The body contract is **frozen** and specified
in `scripts/model-factory/README.md`; the Lambda validates it, wraps it with a
server `receivedAt` and an id, and writes one JSON object to
`raw/feedback/YYYY/MM/DD/<uuid>.json` (or `raw/trajectories/...` for
`"kind": "trajectory"`). 400 on a contract violation, 401 unauthenticated, 413
over 1 MiB. Everything the app sends is opt-in and pre-redacted before upload;
comment and payload content is never logged.

## How the sweep decides

The schedule invokes the Lambda directly every 10 minutes (`POST /sweep` runs the
same code). For each live worker it reads `fin/status-<agent>.json` and applies,
in order:

- **No status object.** Terminated only after 45 minutes from launch — before
  that the instance may still be installing packages and fetching the binary.
- **Stale status.** `updated_at` older than the worker's idle window. The harness
  PUTs status after every poll, so a stale stamp means the daemon is dead,
  wedged, or cut off from the bucket.
- **Idle.** `state` is `idle` or `task-complete` and the last real turn
  (`last_turn_at`, or launch time for a worker that never took one) is older than
  the idle window. The clock cannot run off `updated_at` here: a healthy idle
  daemon refreshes that every poll, so it never goes stale on its own.

All three stamp `terminatedReason: "idle-sweep"`; the sweep's response carries the
specific reason per worker. The idle window is the worker's `idleMinutes`, which
is also written to the instance as the `fin-idle-minutes` tag.

The sweep also **adopts** any running instance tagged `fin-agent` with no live
record — a worker launched by hand with `launch.sh` gets a record (backfilled
from its `LaunchTime`, idle window from its tag or 30 minutes) and is swept from
then on. And it **reconciles**: a record whose instance EC2 no longer reports gets
stamped `instance-gone`, so `/usage` stops accruing hours for a dead worker.

## Prices are estimates

`/usage` multiplies uptime by a hardcoded us-west-2 on-demand map — `t4g.nano`
0.0042, `t4g.micro` 0.0084, `t4g.small` 0.0168, `t4g.medium` 0.0336 $/hr. This
exists to calibrate subscription pricing and is **not billing truth**: it ignores
Savings Plans, Spot, EBS, data transfer, and free-tier credit. Adopted workers of
an unpriced type contribute 0 to the totals and are listed under
`unpricedInstanceTypes`.

## Fallbacks

`../launch.sh` and `../terminate.sh` still work and remain the manual path — use
them when the control plane is down, when you need an instance type outside the
priced set, or when you would rather not have a record at all. Anything launched
that way is adopted by the next sweep, so it is still subject to the idle window;
tag the instance `fin-idle-minutes` if you want a window other than 30 minutes.
