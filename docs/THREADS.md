# Threads: one request, everything it caused, in one place

Levi (2026-09-12, after the first Claude → Fin → Levi notification loop worked):
"we need to add support for threads so I can see the status of my request for
African Intellect and this back and forth 3-way conversation between Claude and
Fin, Fin and me, and Fin and Claude in one place. Add a thread selector to
everywhere we show the current transcript. This should complement the
extension to the notification service we are doing for CarPlay. Lots of fiddly
bits so make sure it is well instrumented and observable and well tested unit
wise."

## 1. What a thread is

A **thread** is a user request plus everything it caused, across every party:

| Party | Speaks through | Appears in the thread as |
|---|---|---|
| Levi | `/messages` (voice, app, supervisor), notification replies | user turns with source + device |
| Fin (a site) | transcript lines (reasoning, tool calls, reply) | Fin turns, collapsible steps |
| An inner session (a tmux pane such as `main:2.0`, usually a Claude Code session) | `send_session` / `read_session` tool results | pane turns: what Fin sent, what the pane showed |
| Claude (an operator session) | `POST /notify` via `scripts/dev/notify-levi.sh`, supervisor messages | operator events |
| The system | `/notify` pushes (task-complete, request-input, stalled), follow-up goals | events with delivery counts |

The thread's **status** is derived, never stored: *waiting on you* (last event is
a request for input or an unanswered notification asking for something), *Fin
working* (a message claimed or applied, or an open follow-up goal), *answered*
(every message answered, no open follow-up), *stalled* (agent-stalled event
after the last message, nothing since).

## 2. Identity: `threadId`

- Every `fin-messages` row gains `threadId`. The root message's `threadId` is
  its own `messageId`; every message in a thread shares it.
- **Explicit** membership: `POST /messages` accepts `threadId`. The app sends
  it when the user replies inside a thread view or from a notification whose
  payload carried `fin.threadId`. The control plane rejects a `threadId` that
  is not a message id it holds for the same user + agent (400).
- **Implicit** membership, proposed by the daemon at ack time (`applied` →
  `threadId`): a message whose turn relays into a pane (`send_session` target)
  joins the newest thread that relayed into the **same pane** within 24 h;
  otherwise it roots a new thread. This is what puts nine separate voice
  requests to "the African Intellect claw session" in one place. The daemon
  proposes; the Lambda records and logs the decision (`thread.assigned`,
  reason `explicit | pane:<target> | root`).
- Transcript lines gain `thread_id` on **every** line of the turn (today only
  the user line carries `in_reply_to`). `send_session` / `read_session` lines
  gain a structured `target` field (the pane) so the pane's side is a first
  class participant, not a string parsed out of prose.
- `/notify` gains optional `threadId` and `messageId` (the daemon passes the
  message it is answering; `notify-levi.sh --thread <id>`). The APNs payload
  carries `fin.threadId`, and `thread-id` = threadId so iOS groups the Lock
  Screen by Fin thread, which is exactly what the CarPlay communication
  notification work wants.

## 3. Thread events: the observable spine

A new table `fin-thread-events` (`threadId` hash, `seq` range; TTL 30 days)
receives one row per transition, written by the Lambda, never by clients:

| kind | actor | written by | detail |
|---|---|---|---|
| `message.queued` | user device | `send_message` | messageId, source, routedBy, target |
| `message.claimed` / `applied` / `answered` | site | `claim_message` / `ack_message` | siteId8, runId, replyPreview (answered) |
| `thread.assigned` | system | `ack_message` | reason |
| `notify.sent` | site / operator | `notify` | event, title, delivered/failed counts |
| `goal.followup` | site | `put_goals` (diff) | goal id, pane target |
| `relay.sent` / `relay.read` | site → pane | `put_transcript_chunk` (lines with `target`) | pane, preview |

Every write also emits one structured CloudWatch log line
`{"thread_event": {...}}` so a bug can be traced without the app. Routes:

- `GET /threads?agent=<name>` — threads for the caller, newest activity first:
  `{threadId, title, status, messageCount, lastActivityAt, participants[],
  openGoal?}`. Title = first message text, trimmed to 80 chars.
- `GET /threads/{threadId}` — the thread: its messages (public shape) and its
  events, ordered.
- `GET /threads/{threadId}/events?after=<seq>` — debug tail.

Thread status derivation lives in one pure function (`_thread_status(rows,
events, goals)`) with table-driven tests.

## 4. App

- `ThreadStore` (`fin/Agent/ThreadStore.swift`): polls `GET /threads` on the
  console cadence (10 s), caches per agent, exposes `threads`, `selected`,
  `timeline(for:)`. A pure `ThreadTimeline.build(messages:records:events:)`
  merges the three sources into ordered `ThreadItem`s with a `party` (levi /
  fin / pane(name) / operator / system) and a `status` chip per thread.
  Logged through `os.Logger(subsystem: "dev.levischoen.fin", category:
  "threads")` at every fetch, merge, and selection change with counts, never
  content.
- `ThreadPicker` (`fin/Views/ThreadPicker.swift`): a `Menu` showing the status
  chip, title, and relative time per thread, plus "All activity". Default
  selection: the newest thread that is not *answered*, else newest.
- Surfaces:
  - `AgentRemoteConsoleView`: picker in the header strip; when a thread is
    selected the turn list is filtered to that thread's `thread_id` /
    `in_reply_to` set, pane turns are rendered as their own party, and
    notify/system events are interleaved. Reply box sends with `threadId`.
  - `AgentHubWindowView` (macOS): a "Threads" sidebar section under
    Conversation, one row per open thread with its chip; selecting one opens
    the console filtered.
  - `AgentLogView`: picker filters runs to those whose lines carry the thread.
  - `AgentConsoleView` (local runtime): the same picker, keyed by the local
    turn's `in_reply_to`/thread when the app hosts the site; "All" otherwise.
  - Notifications: the reply action posts with `fin.threadId`.
- Instrumentation surface for the first iterations: a hidden "Thread debug"
  sheet (long-press the picker) that shows the raw events tail from
  `/threads/{id}/events` with seq and actor, so a wrong status is diagnosable
  on the phone.

## 5. The reply-text bug this exposes (fix first)

Live rows show `{"decision": "idle", ...}` as `replyPreview` for voice
messages. Cause: `Daemon.swift` clears `inFlightSiteMessageID` only in the
`.answered` branch; a cancelled, failed, or budget-exhausted turn leaves it
set, and the next heartbeat's decision JSON is acked as the message's answer,
pushed to the phone, and spoken by Siri. Fix: clear the id on every outcome;
never ack `answered` from a heartbeat-mode turn; `AppSiteClient` records a
reply only if the latest assistant message belongs to the submitted turn.
Regression tests on both.

## 6. Tests (unit, before UI)

- Lambda: thread assignment (explicit, pane-match within 24 h, pane-match
  older than 24 h roots new, foreign threadId → 400), status derivation table,
  event writes per transition (exactly one each, seq monotonic), `/notify`
  with threadId records `notify.sent`, transcript lines with `target` produce
  `relay.*` events, list ordering and limits.
- Daemon: `thread_id` on every line of a message turn and absent on heartbeat
  turns; `target` on send/read session lines; in-flight id cleared on every
  outcome; no answered ack from heartbeat mode.
- App: `ThreadTimeline.build` (ordering across sources, pane party detection,
  dedupe against the console's existing collapse rules), status chip mapping,
  default selection rule, `ThreadStore` decode against a live-shaped fixture,
  `AgentRemoteConsoleView.turns(from:)` filtered by thread.

## 7. Delivery order

1. Daemon fix for the reply-text bug + tests (ships with the next TestFlight).
2. Lambda: `threadId`, events table, routes, notify/transcript hooks, tests,
   deploy (additive, old apps ignore the fields).
3. Daemon: `thread_id` / `target` on lines, thread proposal at ack, notify
   threadId. `notify-levi.sh --thread`.
4. App: `ThreadStore`, `ThreadTimeline`, `ThreadPicker`, console/hub/log
   integration, debug sheet, tests. Ship all four platforms.

Sequenced after the CarPlay Phase 1 branch merges: both touch `notify`,
`ack_message`, `AgentNotificationService`, and the APNs payload.
