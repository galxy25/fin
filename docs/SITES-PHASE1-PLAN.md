# Sites Phase 1 — implementation plan

`docs/SITES.md` is the design. This is the build order for its **Phase 1**,
written against the repo as it actually stands on 2026-09-11, and it amends the
design in two places where the world moved after that document was written.

## Where we actually are

- **Phase 0 landed.** Fin lives on the iMac: `fin-agentd` pid-resident under
  launchd, `connectCommand: exec tmux -L fin new-session -A -s fin`, its own
  `site_ed25519`, `deviceToken8 a4a1d987`, local LM Studio brain. The cloud body
  is paused. Everything in SITES.md §10 steps 1–13 is done.
- **Phase 1 is untouched.** `grep` for `fin-sites`, `fin-messages`,
  `DaemonSiteClient`, `/sites/enroll` across `scripts/`, `daemon/`, `fin/`
  returns nothing. The live config has no `site` block.

## Two amendments to SITES.md

1. **Multi-tenancy came first.** SITES.md was written against a single-tenant
   control plane with flat `fin/*` keys. Phases A–C of the multi-tenancy work
   shipped since: every S3 key is `users/{userId}/fin/*` and `_authorize`
   attaches `event["_userId"]`. So every table in §3 gains a `userId` column,
   every key in §5 gains the `users/{user}/` prefix, and **a site token must
   resolve to a userId** — a site is owned by exactly one user, and a site token
   is a second way to become that user, never a way to skip being one.
   `_authorize` gets a second branch, not a bypass.
2. **`device_id8` already exists and is already per-device.** The per-device
   supervision-status work (`969e588`) made `users/{u}/fin/devices/{d8}/status.json`
   real, with a legacy fold-in. `siteId8` should simply *be* that `device_id8`
   for the resident site (`a4a1d987`), so Phase 1 inherits a working per-device
   status lane instead of inventing a parallel one. `fin/sites/{agent}/{siteId8}/`
   becomes the per-run transcript home only.

## Status (2026-09-12)

| slice | state |
|---|---|
| 1a registry | **deployed, live-verified** — iMac enrolled as `a4a1d987-0000-…`, wins primary |
| 1b messages + election | **deployed, live-verified** — claim/ack/register, routing, eligibility |
| 1c daemon 1.6.0 | **built** — `DaemonSiteClient` actor, `config.site`, pane-title capabilities, held/unacked ledger, `site_id8`/`in_reply_to` on transcript lines; dated compaction |
| 1d app | **built** — `ControlPlaneClient`, `SiteDirectory`/`FinPresence`, Fin's computers, presence header, `/messages` send with queued→claimed→applied→answered rows, memory view "What Fin Sees Right Now", voice via `/messages` |

Deferred from the design, on purpose: presigned-URL refresh over the heartbeat
(the daemon keeps its provisioned URLs and the launchd refresh job); the `update`
command (Phase 2); `finSite` in the push payload (a tap already deep-links by
agent, and the conversation is one merged transcript); per-run transcript keys
(superseded by hourly chunks before this work started).

## Phase 2 / 3 status (2026-09-12)

| item | state |
|---|---|
| Fin's computers lifecycle buttons | done (1d) |
| One-time enroll tokens | **live** — `POST /sites/enroll-tokens`, redeemed by `POST /sites/enroll` with no bearer |
| Goals ledger sync | **live** — `GET/PUT /agents/{a}/goals` with If-Match; daemon `DaemonGoalsSync` (three-way merge, debounced push, 412 retry) |
| macOS binary in S3 + `update` | **built** — `publish-binary.sh`, presign kind `agentdBinary`, daemon verifies sha256 and renames atomically |
| Sweep `/notify` on silent resident sites | **live** — once, at the stale transition |
| Operator bearer off EC2 | **live** — every worker is enrolled as a site and boots with its site token; site scope widened to a body's own work |
| fin-wake reads `fin-messages` / `fin-sites` | **live** — oldest unclaimed queued row; any live site counts as a live body |
| Inbox retirement (Phase 3) | **live** — a site does not poll the inbox; workers are provisioned without `inboxURL`; wake no longer scans inbox objects |
| Forced-command key hardening | **not done, on purpose** — `read_session`, the pane inventory, and the launch preflight are SSH exec channels with the site key; a forced command would replace every one of them with `tmux`. The airtight upgrade is the dedicated UNIX user (needs sudo) — Levi's call. |
| "Let Fin live on this computer", app-device sites claiming their own queue, hosting-mode relabel, multi-agent pane | app work, in progress |
| Scoped self-signing for BYO | optional; not started |

## Sub-phases

Phase 1 as written in SITES.md is one commit-sized bullet list covering three
codebases. It is four independently mergeable and verifiable slices.

### 1a — Site registry (Lambda only, purely additive)

`fin-sites` table; site-token branch in `_authorize`; `POST /sites/enroll`,
`GET /sites`, `POST /sites/{id}/heartbeat` (lease renewal, capability
inventory, command drain, presigned-URL refresh), `DELETE /sites/{id}`.

No existing route changes behaviour, and nothing calls the new ones yet, so
this can ship ahead of any client. Election and messages are deliberately *not*
here — a registry that only knows who is alive is independently useful (it is
what "Fin's computers" reads) and independently testable.

**Verify:** unit tests in `test_lambda.py` for token scoping (a site token
cannot act on another site, cannot act for another user, cannot reach
`/workers`), lease arithmetic against an injected clock, and enroll
idempotency by `enrollKey`. Then enroll the iMac by hand and confirm
`GET /sites` shows it live without changing its config.

### 1b — Message queue and election

`fin-messages` + `fin-agents`; primary election (§6.1); `POST /messages`,
`/messages/{id}/claim|ack|register`; eligibility (§6.2); the legacy-inbox trim
with `If-Match` and the backfill-as-`applied`; `create_worker` stops resetting
`fin/inbox/{agent}.json`.

This is the slice with the real concurrency hazards, and the one that touches
a route (`create_worker`) the running system depends on.

**Verify:** the claim protocol's exclusion pinned directly — two concurrent
claims, one grant; a lapsed lease re-offering a row; `unacked` crash recovery
acking under `claimedBy`. These are conditional-write tests, not integration
tests, and belong next to the existing ownership tests.

### 1c — Daemon 1.5.0

`SiteConfig`; `DaemonSiteClient` on its own `Task` (the whole point: a 12B-model
turn takes minutes and today's poll only runs *between* turns, so a working site
looks dead to every lease); `held`/`unacked` in the ledger object; per-run
transcript keys; `DaemonRemoteDirective.site` filter.

**Verify:** the daemon's existing test target, plus a live swap of the iMac's
config to a `site` block — it keeps its identity (`a4a1d987`) and its ledger, so
this is reversible by editing one file back.

### 1d — App

`ControlPlaneClient` (generalizing `CloudWorkerClient`, keeping `Outcome`);
`SiteDirectory`/`FinPresence` header fold; delivery states on pending rows;
manifest merge in `CloudAgentChannel.fetchTranscript`; voice through
`/messages`; `finAgent`/`finSite` push tap routing.

**Verify:** scoped UI tests per the standing rule (tests scoped to the files
changed), and the presence fold unit-tested directly — it is pure logic over a
`GET /sites` payload and deserves to not be tested through a view.

## Sequencing note

1a is safe to ship alone. 1b through 1d are only *useful* together, but they are
still worth landing separately: 1c and 1d each have a live rollback that is one
config edit or one build, and bundling them would forfeit that.
