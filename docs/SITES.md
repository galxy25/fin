# Fin sites — one agent, many bodies

*Design document. Repo state: `main @ 5904207` (fin-agentd 1.4.0). Spine: the lease/claim design; grafted: fin-wake-aware key placement, the legacy-inbox compat lane, the presence-fold UX, context-driven pinning, and a heartbeat that survives long turns.*

## 1. Principle

The user talks to **Fin**. Fin has one name, one conversation, one voice. Where Fin's hands are at any moment — an EC2 worker the control plane launched, the resident daemon on Levi's iMac, a daemon someone installed on a tailnet box, or the `AgentRuntime` inside the app on the phone in your pocket — is the app's job to abstract away. Those places are **sites**: interchangeable bodies for one agent, not separate agents.

Three rules follow, and every section below is checked against them:

1. **Nothing below the agent reaches the conversation.** No worker ids, instance ids, site ids, hostnames. Sites appear only in the "Fin's computers" pane, by display name, with ids behind a Details disclosure.
2. **The control plane is the only orchestrator.** Enrollment, heartbeat, dispatch, lifecycle — one contract for every kind of site. Sites dial *out*; the control plane never needs inbound access to anything, so a BYO box behind a tailnet is as first-class as an EC2 instance.
3. **A message is applied by at most one body.** Exclusion is decided by one linearizable authority (a DynamoDB conditional write), never by "whoever polled first."

Out of scope and untouched: `scripts/cloud-agent/lmstudio-auth-shim.py` and the Funnel route `https://levis-imac.tail2e2bdf.ts.net:8443/llm`. EC2 sites keep using it through `_template.json`; the resident iMac site talks to LM Studio at `http://127.0.0.1:1234/v1` because it is on the same box.

## 2. Vocabulary

- **Agent.** The conversational identity: `Agent.id` (UUID, CloudKit-synced) and `Agent.name` ("Fin"). Still the cross-system join key (`_key_slug("Fin") == "fin"`).
- **Site.** One process that can act as an agent: `(siteId, siteId8, kind, agent, displayName, priority, capabilities, token)`. `kind ∈ {ec2, resident, byo, app}`. `siteId` is a lowercase UUID minted at enroll; `siteId8` is its first 8 hex and **is** the daemon's `deviceToken8`, so the existing `device_id8` field in status and transcript lines becomes the site identity with no schema change. App installs are sites too: `siteId = DeviceIdentity.id`, `siteId8 = DeviceIdentity.short`.
- **Primary.** The one site that receives an agent's *unaddressed* messages. Elected by the control plane on every heartbeat from `priority` (resident 100, byo 50, ec2 10, app 1; operator-overridable) and liveness. A primary that stops heartbeating loses the role within one lease.
- **Lease.** A server-clock expiry the control plane attaches to two things: a site's liveness (`fin-sites.leaseUntil`, renewed by heartbeat, 60 s) and a message claim (`fin-messages.leaseUntil`, 120 s, renewed while the claiming site holds the message). Sites send durations, never timestamps; clock skew cannot forge a claim.
- **Capability.** What a site can reach or do, reported in every heartbeat: hosts, tmux sessions (the site's `routing-registry.json`, finally reported upward), browser, secrets scope, brain endpoint kind and model, daemon version. Dispatch reads capabilities; the user never does.

## 3. Control-plane orchestration of sites

Everything lives in `scripts/cloud-agent/control-plane/lambda.py`. Existing routes (`/workers`, `/usage`, `/sweep`, `/presign`, `/feedback`, `/device-tokens`, `/notify`, `/secrets`) are unchanged. Three tables are added; `fin-cloud-workers` stays the EC2 infrastructure/billing ledger and **never** gains non-EC2 rows (a resident row there would be terminated as `instance-gone` by `create_worker`'s reconcile, would pin the iMac awake through fin-wake's `any_live_worker`, and would show as unpriced in `/usage`).

| table | key | fields |
|---|---|---|
| `fin-sites` | `siteId` | `siteId8, agent, kind, displayName, priority, tokenSha256, enrollKey, enrolledAt, lastHeartbeatAt, leaseUntil, state live\|working\|stale\|retired, capabilities{}, runId, transcriptKey, commands[], workerId?` |
| `fin-messages` | `messageId` (+GSI `agent-createdAt`) | `agent, text, source, createdAt, authorSiteId8, pinSiteId?, targetSiteId?, claimedBy?, claimedAt?, leaseUntil?, state queued\|claimed\|applied\|answered\|expired, appliedRunId?, replyPreview?` |
| `fin-agents` | `agent` | `agentID, primarySiteId, primaryPriority, primaryLeaseUntil, goalsVersion, goalsUpdatedBy` |

### 3.1 Authorization

`_authorize` accepts the operator bearer (`FIN_CP_TOKEN`; the app and operator scripts) **or** a per-site token: `Authorization: Bearer <siteToken>` + `X-Fin-Site: <siteId>`, checked by `hmac.compare_digest(sha256(token), fin-sites.tokenSha256)`. A site token is scoped to `/sites/{ownId}/*`, `/messages/*/claim|ack|register` for its own agent, `/presign` for its own agent, `/notify`, and `/agents/{ownAgent}/goals`. A leaked token can act only as that one site and is revoked by re-enrolling.

### 3.2 Enrollment

`POST /sites/enroll` (operator token) `{agent, kind, displayName, priority?, enrollKey, siteId?}` → `{siteId, siteId8, siteToken, heartbeatSeconds: 20}`. `enrollKey` (e.g. `levis-imac/deepspacenine`) makes it idempotent: re-enrolling returns the same site and rotates the token. `siteId?` lets the operator adopt a site that already exists under a hand-chosen `deviceToken8` (tonight's iMac).

- **EC2**: `create_worker` calls enroll internally (kind `ec2`, displayName "Cloud computer", priority 10) *before* `_provision_config`, which gains placeholders `{{SITE_ID}}`, `{{SITE_ID8}}`, `{{SITE_TOKEN}}`, `{{DISPLAY_NAME}}`; the config is written to `fin/sites/{agent}/{siteId8}/config.json` and `_record` gains `siteId`. USER_DATA is byte-identical except the substituted config URL, so `check-userdata-parity.py` stays green.
- **Resident / BYO**: the installer (§9) redeems a one-time token from `POST /sites/enroll-tokens` (operator token; 15-min TTL) and writes the returned `site` block into the local config. Same daemon, same row shape; the only difference is who typed the install command.
- **App**: `AgentDirectiveChannel.uplinkStatus` auto-enrolls `d-<DeviceIdentity.short>` on first heartbeat with the operator token the app already holds.

### 3.3 Heartbeat and capability inventory

`POST /sites/{siteId}/heartbeat` (site token), every 20 s, **from a task independent of the turn loop**. Today's `putStatus` and `supervision.poll` run only in the inner wait between turns (`Daemon.swift` run loop); a multi-tool turn on a 12B LM Studio model takes minutes, and a site that goes silent mid-turn would look dead to every lease. The 1.5.0 `DaemonSiteClient` therefore runs its own `Task`, reports `state: "working"` while a turn is in flight, and dispatch treats `working` as online.

Request:
```json
{ "schema": 2, "state": "idle|working|needs-input|task-complete|draining",
  "wantsPrimary": true, "runId": "…", "transcriptKey": "fin/sites/fin/3f9a1c2e/runs/….jsonl",
  "held": ["m-…"], "unacked": ["m-…"], "urlsExpireAt": "…",
  "capabilities": {
    "hosts": [{"host":"127.0.0.1","username":"deepspacenine"}],
    "tmux_sessions": [{"session":"fin","registered":true,"tasks":["fin app","xcode"]},{"session":"scratch","registered":false}],
    "browser": false, "secrets_scope": null, "always_on": true,
    "brain": {"kind":"lmstudio-local","model":"google/gemma-4-12b-qat"},
    "daemon_version": "1.5.0" } }
```
`tmux_sessions` = `tmux list-sessions -F '#S'` run over a **second exec channel on the daemon's existing SSH connection** (correct for a BYO daemon whose `server.host` is remote) joined with `RegistryDocument.loadIfPresent`. If tmux is absent the list is empty; the heartbeat never fails for it.

Response:
```json
{ "role": "primary|standby", "leaseUntil": "…",
  "messages": [{"id":"m-…","text":"…","createdAt":"…","pinSiteId":null}],
  "commands": [{"id":"c-…","kind":"restart|update|stop|drain","args":{}}],
  "legacyInboxGet": "https://…fin/inbox/fin.json…",   // primary only
  "urls": {"directiveGet":"…","statusPut":"…","transcriptPut":"…","transcriptGet":"…"}, "urlsExpireAt": "…" }
```
The Lambda renews the site lease, runs primary election (§6.1), extends `leaseUntil` on every `held` row where `claimedBy == me`, acks `unacked` ids (crash recovery, §6.3), computes eligible messages, drains queued commands, and re-signs presigned URLs when `urlsExpireAt - now < 20 min`. The heartbeat *is* the poll, the URL refresh, and the command channel; no inbound path exists.

### 3.4 Dispatch

`POST /messages` (operator or app) `{agent, text, messageId: "m-<uuid>", context}` with `context = {source: "app"|"voice"|"mac-terminal", device_id8, activeServerName?, activeSessionNames: [], siteHint?}` → `put_item(ConditionExpression=attribute_not_exists(messageId))` (idempotent retry). The Lambda sets `pinSiteId` itself: `siteHint` if that site is live; else a whole-word, case-insensitive match of `text` and `activeSessionNames` against each live site's `capabilities.tmux_sessions[].session|tasks` (the same rule as `SessionRouter.wordMentioned`) — exactly one site → pin; several → `routedBy: "clarify"` with candidate display names; none → unpinned. Unpinned messages set `targetSiteId = fin-agents.primarySiteId` if its lease is fresh. No live site at all → the row is still queued (`targetSiteId: null`) and the app shows Fin asleep. **There is no keyword-triggered EC2 launch**; a cloud body is summoned only by an explicit "Wake a cloud computer" or the operator. Response `{messageId, state, targetSiteId, targetSiteName, routedBy}`.

### 3.5 Lifecycle — one model for every kind

| verb | EC2 | resident / BYO | app |
|---|---|---|---|
| start | `POST /workers` (enrolls the site) | installer / launchd `KeepAlive` | app launch |
| restart / update / stop / drain | `POST /sites/{id}/commands`, delivered on the next heartbeat | same (daemon executes: `restart` = exit 0, launchd respawns; `update` = presigned GET of `fin/agentd/fin-agentd-macos-arm64`, sha256 verify, atomic rename, exit 0; `drain` = finish turn, stop claiming, `state: draining`; `stop` = exit and stay down) | none |
| terminate / forget | `DELETE /sites/{id}` → existing `_terminate` | queue `stop`, mark `retired`, revoke token | row goes stale |
| health | `GET /sites?agent=` joins `fin-sites` with `fin-cloud-workers` (instanceType, launchedAt, cost) | `fin-sites` only | `fin-sites` only |
| sweep | idle rule unchanged; **never** terminates the current primary while `queued` rows exist for its agent | `lastHeartbeatAt` older than 3 leases → `stale` + `/notify` "Fin lost contact with Levi's iMac"; never terminated | stale only |

## 4. Single pane of glass

**The Fin conversation** (`AgentRemoteConsoleView`, cloud branch): one merged transcript across every site and the on-device mirrors; a plain composer; a one-line header from a `FinPresence` fold computed client-side over `GET /sites`:

```swift
enum FinPresence { case needsInput(site: FinSite, preview: String), working(site: FinSite), idle, asleep }
// fold: any live needs-input > any live working > idle > (no live site) asleep
```
"Fin needs your input", "Fin is working", "Fin is ready", "Fin is asleep — no computer is reachable" (+ one button, **Wake a cloud computer**, which is today's `POST /workers`). Assistant rows carry a glyph (`desktopcomputer` / `cloud` / `iphone`) whose tap-detail reads "on Levi's iMac · 2 min ago"; pending rows read "queued for Levi's iMac" and progress `queued → claimed → applied → answered` from `GET /messages/{id}`. A "Do this on…" chip appears only when `routedBy == "clarify"`. The header shows no per-site strip and no Start Worker button.

**Fin's computers** — a section of the Servers list (`ServerListView`), display names only: "Levi's iMac · Fin lives here · online", "Cloud computer · online 3h · ~$0.02", "This iPhone". Row actions Restart / Update / Stop (Terminate for EC2) via `ControlPlaneClient.siteCommand`; a Details disclosure shows `siteId8`, host, daemon version, capabilities, `instanceId`. Because `agent` is a column on every row, a second agent is another group in the same pane — this is the remote control for all agents and all servers.

**Add a computer** — `ServerEditView` gains step two after the existing Fin's Key grant: **Let Fin live on this computer**, which runs the site installer over the SSH session the app already holds (or shows the copyable one-liner). Granting the key makes a machine a *server Fin can reach*; installing the daemon makes it a *site Fin can run on*.

**Voice** — `FinVoiceIntentCore.prepare` targets the agent named "Fin" regardless of `hostingModeRaw` whenever `CloudControlPlaneConfig.isConfigured`, sends via `POST /messages` with `source: "voice"`; `AskFinIntent` polls `GET /messages/{id}` for `state == answered` and speaks `replyPreview`, falling back to today's transcript poll.

**Push** — `/notify` gains `site`; the APNs payload carries `finAgent` and `finSite`; `finApp.swift` maps them to `PushOpenTarget` so daemon pushes route like CloudKit signals. `DaemonNotifyClient` titles become "Fin needs your input" / "Fin: task complete" with the site's display name in the body.

**Model** — `AgentHostingMode` keeps raw values `local` and `cloud` (`cloud` relabelled "Fin's sites"); **no new synced fields on `Agent`** (the build-31 CloudKit outage rule). App types: `ControlPlaneClient` (generalizing `CloudWorkerClient`, keeping its `Outcome` enum) with `sendMessage`, `messageState`, `listSites`, `siteCommand`, `deleteSite`; `SiteDirectory` (`FinSite`, `SiteKind`, `FinPresence`, 15 s cache); `MessageContext`.

## 5. S3 key scheme and ownership

Rule: every object has exactly one writer type. Bucket `fin-agent-directives-011183829623`.

| key | writer | reader | status |
|---|---|---|---|
| `fin/agentd/fin-agentd` | build host | EC2 boot | unchanged |
| `fin/agentd/fin-agentd-macos-arm64` | build host | `update` command on Mac sites | new |
| `fin/agentd/_template.json` | operator (`make-config-template.sh`) | `_provision_config` | unchanged; preserves the Funnel route + token verbatim |
| `fin/sites/{agent}/{siteId8}/config.json` | Lambda (conditional PUT) / operator | that site at boot | new (replaces `fin/agentd/{agent}.json` for new EC2 sites) |
| `fin/sites/{agent}/{siteId8}/status.json` | that site only | ops mirror, fin-wake follow-up | new — **outside fin-wake's `Prefix="fin/status"` glob** |
| `fin/sites/{agent}/{siteId8}/runs/{runId}.jsonl` | that site, that process (whole-doc ring) | app merge | new — a restart starts a new object, never overwrites |
| `fin/agents/{agent}/manifest.json` | Lambda (on heartbeat when `runId`/`transcriptKey` change) | app, `AskFinIntent` fallback | new |
| `fin/agents/{agent}/goals-ledger.v{N}.json` | Lambda (`PUT /agents/{agent}/goals`) | sites, app | new |
| `fin/directives.json`, `fin/status.json` | external supervisor / app devices | daemons, supervisor | unchanged through Phase 2 |
| `fin/inbox/{agent}.json` | old app builds (GET-merge-PUT); **Lambda trims acked ids with `If-Match`** | the primary site only | legacy compat lane |
| `fin/status-{agent}.json` | nobody after Phase 0 | sweep for legacy rows | frozen; deleted Phase 3 |
| `fin/transcripts/{agent}.jsonl` | nobody after Phase 0 | app via manifest run `{siteId8:"legacy"}` | frozen; archived copy at `fin/sites/{agent}/legacy/runs/<date>.jsonl` |

`presign` gains kinds `manifest`, `goals`, and an optional `site` so per-site kinds resolve to the `fin/sites/…` keys.

## 6. Message routing and exactly-once application

### 6.1 Primary election
Each heartbeat with `wantsPrimary` runs one conditional update on `fin-agents`:
`SET primarySiteId=:me, primaryPriority=:p, primaryLeaseUntil=:now+60s` with
`ConditionExpression = attribute_not_exists(primarySiteId) OR primarySiteId=:me OR primaryLeaseUntil<:now OR primaryPriority<:p`.
The iMac (100) preempts a cloud worker (10) on its first heartbeat; a silent primary is replaced after 60 s; the loser sees `role: standby`. The primary flag only *routes*; it never *excludes*.

### 6.2 Eligibility (server-side, per heartbeat)
A `queued` row (or `claimed` with lapsed lease) is returned to site X iff: `pinSiteId == X`; or no pin and `targetSiteId == X`; or no pin, target null or stale, and X is primary; or no live primary at all and X is live (last-resort failover). The daemon implements no policy.

### 6.3 The claim protocol, step by step
1. **Send.** App mints `messageId = "m-<uuid>"`, `POST /messages`. Row `queued`. Retry with the same id is a no-op.
2. **Offer.** The eligible site receives the row in its heartbeat's `messages[]`.
3. **Claim.** `POST /messages/{id}/claim {leaseSeconds: 120}` →
   `update_item(ConditionExpression = attribute_not_exists(claimedBy) OR claimedBy=:me OR (leaseUntil<:now AND #state NOT IN (applied, answered)))`, `:now` = Lambda clock. `200 {granted:true}` or `409`. On 200 the daemon appends the id to `held[]` in its ledger file (`fin-agentd-directives.json` — since 1.4.0 an object, `{"applied": […], "seeded": […], "seed_pending": false, …}` with the 1.4.1 inbox pair alongside, so `held` and `unacked` are two more keys of that object; the bare-array form is only the 1.3.0 read path, and `loadLedger` decodes every key as optional); on 409 it forgets the message.
4. **Hold.** If a turn is in flight the message waits in `held`; every heartbeat renews the lease for `held` ids. Claiming at receipt rather than at apply time is deliberate: while the primary is busy, the conversation stays with the primary instead of drifting to a standby.
5. **Apply.** Between turns the turn loop pops the oldest held id: one atomic ledger write moves it `held → applied + unacked`, then `engine.submit(text)` (the existing `markApplied`-before-`submit` at-most-once discipline), then `POST /messages/{id}/ack {state:"applied", runId}`; on 200 remove from `unacked`. The injected `userMessage` transcript line carries `in_reply_to: "<messageId>"` and `site_id8`.
6. **Answer.** When the following assistant turn ends: `ack {state:"answered", replyPreview}`. The Lambda also trims the id from `fin/inbox/{slug}.json` if it originated there (§6.5).

### 6.4 Failover, case by case
- **Two live sites, overlapping eligibility.** Both call `claim`; DynamoDB is linearizable per item; exactly one is granted. The other's ledger never sees the id.
- **Site dies after claim, before apply.** Heartbeats stop, `held` renewals stop, the claim lease lapses at 120 s, the row is eligible again, another site (or this one on restart, since `held` is persisted) claims it. Delayed, not duplicated.
- **Site dies after submit, before ack.** The id is in `unacked`. On restart the first heartbeat carries `unacked[]`; the Lambda acks them under `claimedBy=:me`, so the row leaves `queued` before anyone else sees it — provided restart happens within the lease. If the site stays dead past 120 s, a second site applies it too. This is the **one at-least-once window**: a permanent death inside the ~50 ms between `submit` and `ack`. The merged transcript shows two `userMessage` rows with the same `in_reply_to`; the app collapses them with a note "handled by Levi's iMac and Cloud computer". Stated, not hidden.
- **Primary preempted mid-conversation.** The old primary's `held` claims remain valid until acked or lapsed; new unpinned messages target the new primary. Nothing is lost or duplicated because claims, not roles, exclude.
- **Long turn.** The independent heartbeat keeps both leases fresh with `state: working`; no reroute happens because Fin is busy.
- **Lambda unreachable.** Sites keep cached presigned URLs (≤1 h) and ledgers but cannot claim, so nothing is applied and nothing is duplicated. The app keeps rows `unsent` and retries with the same id. The app's direct S3 GET-merge-PUT is used **only** when no control plane is configured; with one configured it would bypass claims.
- **Clock skew.** All lease arithmetic uses the Lambda's `now`. Sites send durations.

### 6.5 The legacy compat lane
Old TestFlight builds and old-build voice intents still hold presigned `inboxPut` URLs and append directly to `fin/inbox/fin.json`. That object therefore keeps exactly one **consumer**: the primary. The heartbeat response includes `legacyInboxGet` only when `role == primary`; `DaemonDirectiveClient` adds or drops its second `PolledDocument` slot on every role change (the class already generalizes over slots and shares the applied ledger). For each unseen entry the primary calls `POST /messages/{id}/register {agent, text, source:"legacy"}` (conditional put; 200 or 409-exists are both fine), then proceeds through `claim → hold → apply → ack` exactly as above — so even a preemption race on the legacy doc is settled by the claim row. On `ack applied` the Lambda GETs the doc, removes the id, and PUTs with `If-Match`, one retry on 412; an old build's concurrent GET-merge-PUT can at worst resurrect already-applied ids, which the ledger and the claim state ignore. The legacy inbox thereby becomes pending-only, which also makes fin-wake's `any_inbox_nonempty` signal meaningful again (today it is true forever after the first message).

`create_worker` **stops resetting** `fin/inbox/{agent}.json` and never touches `fin-messages`; a new body can no longer discard messages another body will handle. The Phase 1 deploy backfills every id currently in the legacy doc as `state: applied` so no site replays it.

`fin/directives.json` stays broadcast. `DaemonRemoteDirective` gains `site: String?`; `matches(agentNamed:site:)` requires `site == nil || site == "*" || site == mySiteId8`. Until that ships, supervisors write per-site work through `POST /messages` with `siteHint`, never as `agent:"Fin"` user messages in the shared doc.

## 7. Status and transcript per site, and the app's merge

**Status.** The heartbeat is the authoritative record (`fin-sites`); the daemon still PUTs the same document to `fin/sites/{agent}/{siteId8}/status.json` as a human/ops mirror, on the heartbeat cadence. Nothing 1.5.0 writes under `fin/status*`.

**Transcript.** `DaemonTranscriptUplink` keeps its mechanics (in-memory ring of `maxLines`, whole-document PUT, unconditional post-turn flush) but writes to a **per-run key** `fin/sites/{agent}/{siteId8}/runs/{runId}.jsonl`; a new process is a new object, so the restart-overwrites-history bug is gone structurally. Lines gain `site_id8`, `site_name`, `in_reply_to?`; `AgentMirrorRecord.init(jsonlLine:)` parses them as optionals, so old lines still decode. The Lambda maintains `fin/agents/{agent}/manifest.json` = `{runs:[{siteId8, siteName, runId, key, startedAt, lastFlushAt}]}`, last 20 runs per site.

**Merge** (`CloudAgentChannel.fetchTranscript`): GET manifest → GET each run with `If-None-Match` → plus `AgentMirrorReader.loadRecent` for on-device mirrors → `AgentMirrorReader.merge` (exists today; sorts by timestamp, run id, sequence) → dedupe by `id` → collapse rows sharing `in_reply_to` → filter `.notice`. Timestamps are second-resolution; within a second `runId` groups a body's lines and `sequence` orders them, which is a total order within a run and sufficient across runs because a message and its reply live on one site. `AgentRemoteConsoleView.refresh` is otherwise unchanged.

## 8. Shared goals ledger

Goals belong to the user, not a host, so `goals-ledger.json` stops forking per site. `GoalsLedgerStore` stays the local cache and prompt source; new `GoalsLedgerSync` in `FinAgentCore` (compiled into app and daemon) does `pull()` = `GET /agents/{agent}/goals` → `{version, document}` and `push()` = `PUT /agents/{agent}/goals` with `If-Match: <version>`. The Lambda bumps `fin-agents.goalsVersion` with a conditional update *first*, then writes `fin/agents/{agent}/goals-ledger.v{N}.json`; a loser gets `412 {version, document}` and three-way merges: goals keyed by `id`; `updates[]` unioned by `(at, kind, text)`; scalar fields (`state, priority, next_action, blocked_on, tags`) from whichever side has the later `updates.at`; no deletes (removal is `state: dropped`). Three retries, then keep local and report `goals_sync: "conflict"` in the heartbeat. Pull before each mission-section composition and heartbeat tick; push after any `Goal` mutation. A freshly launched cloud body inherits the iMac's mission on its first turn. Versioned S3 keys avoid the 400 KB DynamoDB item cap. The routing registry stays machine-scoped by design and is only *reported* as `capabilities.tmux_sessions`.

## 9. Site config and identity

**`DaemonConfig` (1.5.0, additive):**
```json
"site": { "id": "<uuid>", "kind": "resident", "displayName": "Levi's iMac",
          "token": "<siteToken>", "heartbeatSeconds": 20 }
```
When `site` is present, `supervision.directiveURL/statusURL/inboxURL` and `transcript.putURL` become optional — the heartbeat supplies them; baked URLs are bootstrap-only. `deviceToken8` defaults to `site.id` prefix; `controlPlane.token` is the site token (the `/notify` call is unchanged). `agentID` must be the app's `Agent.id` for Fin; auto-provision no longer mints a fresh UUID but reads it from `fin-agents.agentID`.

**Presigned refresh, not self-signing.** Sites never hold AWS credentials: no IAM user per BYO box, no SigV4 code in the daemon, revocation is a token rotation. URLs are re-signed on the heartbeat whenever `urlsExpireAt - now < 20 min` and immediately after any S3 403, so the fact that Lambda-role URLs die with the role's temporary credentials stops mattering — nothing lives longer than a heartbeat cycle. Scoped self-signing (IAM Roles Anywhere) remains a Phase 3 option for BYO sites that need direct bucket access.

**Dedicated site key, not Fin's Key.** Fin's Key is the identity Fin uses to reach *other* computers: private half in the synced Keychain and the write-only vault, never read back. Writing it to disk on every resident/BYO host inverts that doctrine and couples revocation. The resident site only ever attaches a tmux session on its own box, so the installer runs
`ssh-keygen -t ed25519 -N "" -C fin-site-<siteId8> -f "~/Library/Application Support/fin-agentd/site_ed25519"`
and appends `restrict,pty,from="127.0.0.1,::1" ssh-ed25519 … fin-site-<siteId8>` to `~/.ssh/authorized_keys`. `restrict` disables forwarding and X11, `pty` re-enables the terminal the harness needs, `from=` pins it to loopback. Distinct comments (`fins-key` vs `fin-site-*`) make either revocation a one-liner. `LC_FIN_AGENT` still crosses (`AcceptEnv LANG LC_*` is the macOS default), so the fish auto-attach guard keeps the daemon out of Levi's own tmux. Tonight uses `connectCommand: "tmux new-session -A -s fin"` (the tested path); a forced-command variant is a Phase 2 hardening option.

**LaunchAgent** — `scripts/mac-fin-agentd/{install.sh, dev.levischoen.fin.agentd.plist, README.md}`, mirroring `scripts/mac-wake-for-fin/`: `ProgramArguments [~/Library/Application Support/fin-agentd/bin/fin-agentd, …/config.json]`, `RunAtLoad true`, `KeepAlive true` (plain `true`, so `restart`'s exit 0 respawns; `SuccessfulExit:false` would not), `ThrottleInterval 15`, `EnvironmentVariables.PATH` including `/opt/homebrew/bin`, logs under `~/Library/Logs/fin-agentd/`; `install.sh` renders paths, `launchctl bootout` then `bootstrap gui/$UID`. Zero sudo except one line: a resident site is only as always-on as its Mac, and a sleeping Mac cannot poll, so `sudo pmset -a sleep 0` on the iMac. fin-wake stays installed but becomes moot there; keeping site status off `fin/status*` means fin-wake on any *other* Mac is not pinned awake by remote sites' heartbeats.

**Linux BYO**: same daemon, user systemd unit with `Restart=always`; `install-linux.sh --enroll <one-time-token>`.

## 10. Migration from today's cloud-only Fin

Today: worker `i-08bd2753e5b291a50` (1.4.0, `stayResident`) consumes `fin/inbox/fin.json`, writes `fin/status-fin.json` and `fin/transcripts/fin.jsonl`, boots from `fin/agentd/fin.json` (auto-minted `agentID`, shim endpoint, 7-day URLs). This is a **hand-over, not a coexistence**: with zero code changes two daemons named Fin can only be safe on different keys, and today's app can only read the legacy keys — so the iMac inherits them and the cloud body is paused.

Verified facts the order depends on: as of 1.4.0 `seedLedgerIfFirstRun` seeded only the shared directive document ("the inbox is deliberately NOT seeded"); neither the app (trims at 200) nor the daemon ever removes applied inbox entries; `delete_worker` only terminates, it does not reset the inbox. A fresh iMac ledger under 1.4.0 would therefore replay every message since the last launch into a real tmux session, one model turn each. *(1.4.1 amendment: a first run now seeds the inbox backlog too unless the config carries `supervision.inboxResetAtLaunch: true` — the control plane sets it on configs it provisions, a resident config leaves it off — so a fresh iMac ledger on 1.4.1 seeds that backlog instead of replaying it. The ordering below stays correct; the blast radius of getting it wrong is what shrank.)*

Steps (operator shell with long-lived creds where AWS is touched; nothing heavy on the iMac tonight):

1. **Binary.** `daemon/.build/debug/fin-agentd` (arm64, built 20:27 today, contains the `LC_FIN_AGENT` marker) → `~/Library/Application Support/fin-agentd/bin/fin-agentd`. Do **not** use the 14:06 release binary (predates the marker) and do not build.
2. **Key.** ssh-keygen + the restricted `authorized_keys` line above. Remote Login on. LM Studio serving on `127.0.0.1:1234`.
3. **Mint.** `SITE8=$(uuidgen | tr A-F a-f | cut -c1-8)`. Find Fin's `Agent.id` in the app (Agent detail).
4. **Presign** (operator creds, 7 days; PUTs via the boto3 snippet in the control-plane README): GET `fin/directives.json`; GET `fin/inbox/fin.json`; PUT `fin/sites/fin/$SITE8/status.json`; PUT `fin/transcripts/fin.jsonl`.
5. **Config** `~/Library/Application Support/fin-agentd/config.json` (0600): `server {127.0.0.1, 22, deepspacenine, privateKeyPath ~/Library/Application Support/fin-agentd/site_ed25519, connectCommand "tmux new-session -A -s fin"}`; `agent {endpointURL http://127.0.0.1:1234/v1, modelIdentifier <loaded model>, contextWindowTokens 8192, maxOutputTokens 640, temperature 0.2, heartbeatSeconds 60}`; `task "You are Fin at home. Say hello and wait. TASK COMPLETE."`; `stayResident true`; `agentID <Fin Agent.id>`; `deviceToken8 $SITE8`; `auditLogPath ~/Library/Application Support/fin-agentd/audit.jsonl`; `supervision {agentName Fin, pollSeconds 30, directiveURL, inboxURL, statusURL}`; `transcript {putURL, flushSeconds 15, maxLines 2000}`; `controlPlane {endpointURL, token}`.
6. **Archive.** Copy `fin/transcripts/fin.jsonl` → `fin/sites/fin/legacy/runs/2026-09-05-ec2.jsonl` and `fin/status-fin.json` → `fin/sites/fin/legacy/status-2026-09-05.json`. The iMac's first flush overwrites the original.
7. **Pause the cloud body.** `GET /workers` → `DELETE /workers/{workerId}` for `i-08bd2753e5b291a50`. "Paused" means the instance is terminated and the row is `terminated`: a merely stopped instance would still be swept to termination on stale status and its live row would pin fin-wake. Its conversation survives in the archive; the cloud body is re-summoned later by `POST /workers`. `fin/agentd/fin.json` stays as the EC2 template source; `/usage` keeps its hours.
8. **Confirm** `fin/status-fin.json` LastModified stops advancing for >60 s.
9. **Conversation boundary.** PUT `{"version":1,"directives":[]}` to `fin/inbox/fin.json`.
10. **Start.** `install.sh` → bootstrap. Tail the log until the first poll and status PUT land; confirm `fin/sites/fin/$SITE8/status.json` shows `device_id8 == $SITE8`, `state idle|task-complete`.
11. **Round trip.** "Ask Fin what's in the fin session" from the phone; reply appears in the console and by voice. The app, `FinVoiceIntentCore` (Fin is already `cloud`), and `AskFinIntent` are unchanged.
12. `sudo pmset -a sleep 0`.
13. **Guardrail until Phase 1:** nobody taps Start Worker for Fin — `create_worker` still resets `fin/inbox/fin.json` and boots a second 1.4.0 consumer on the legacy keys.

## 11. Rollout phases

**Phase 0 — tonight.** Steps 1–13. No Swift builds, no Lambda deploy (the site tables and site-token auth are new surface and deserve tests; shipping them at midnight adds risk to the running control plane for no tonight benefit). Result: Fin lives on the iMac with real tmux and the local LM Studio brain as the sole consumer of the legacy inbox; voice and console unchanged; the cloud body paused.

**Phase 1 — first build day.** Lambda: three tables, `/sites/*`, `/messages*`, `/agents/{a}/goals`, site-token auth with tests, primary election, claim/ack/register, legacy trim with `If-Match`, legacy backfill as `applied`, `create_worker` enrolls and stops resetting the inbox, sweep reads `fin-sites`, `presign` site kinds. Daemon 1.5.0: `SiteConfig`, `DaemonSiteClient` (independent heartbeat task, claim/hold/ack, URL refresh, commands), legacy slot by role, `held/unacked` in the ledger, per-run transcripts with `site_id8/in_reply_to`, directive `site` filter, Fin-branded notify. App: `ControlPlaneClient`, `SiteDirectory`/`FinPresence` header, delivery states, `MessageContext`, manifest merge, voice via `/messages`, `finAgent/finSite` tap routing. Enroll the iMac with `siteId8 = $SITE8`, swap its config to the `site` block (it keeps the same identity and ledger), and let `POST /workers` launch the first cloud site on its own keys — true coexistence.

**Phase 2.** "Fin's computers" lifecycle buttons; "Let Fin live on this computer" over SSH; one-time enroll tokens; `GoalsLedgerSync`; app-device heartbeats (`d-<short>`); macOS binary in S3 + `update`; sweep `/notify` on silent resident sites; operator bearer removed from EC2 templates; fin-wake reads `fin-sites`/`fin-messages`; forced-command key hardening.

**Phase 3.** Device sites claim from their own queue, retiring the CloudKit relay for dispatch; supervisor moves to `GET /sites`; delete `fin/inbox/*`, `fin/status-*`, `fin/transcripts/{agent}.jsonl`; relabel hosting mode; multi-agent pane; optional scoped self-signing for BYO.

## 12. Open questions

1. **Should the resident iMac ever sleep?** `pmset -a sleep 0` is honest for tonight; a wake-on-demand story (APNs-to-Mac or a tailnet WoL) would let fin-wake's policy apply to resident sites too.
2. **Destructive commands inside the at-least-once window.** A second body re-applying "rm -rf build" after a permanent death mid-ack is bounded but not zero; should `submit` of a destructive-looking message require `ack applied` to succeed first (making it at-most-once with possible loss instead)?
3. **Presence vs. physical presence.** When Levi is at the MacBook with a live terminal, should the app site (priority 1) win pinning for messages about *that* terminal automatically, or only via `siteHint`?
4. **How long to keep the legacy lane.** It exists for old TestFlight builds; pick a build number after which `fin/inbox/*` is deleted.
5. **Heartbeat cost.** 20 s × N sites ≈ 4 300 Lambda invocations per site per day plus DynamoDB writes — negligible for tens of sites; revisit before hundreds (idle sites could back off to 60 s with a longer lease).
6. **Supervisor migration.** The external Claude Code supervisor reads `fin/status.json` and writes `fin/directives.json`; both survive through Phase 2, but the `site` filter changes what an `agent:"Fin"` entry means once several bodies exist.
7. **Second agent.** Every table already keys on `agent`; the open UX question is whether a second agent gets its own conversation surface or appears as a participant in Fin's.
8. **Fin's Key for resident sites.** Today only the EC2 instance role can read `shared/fin-agent-ssh-key`; a resident site that should reach *other* computers needs a site-scoped read (Phase 3) or a separate grant.