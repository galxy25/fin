# fin-agentd

Headless extraction of Fin's agent runtime: a daemon that runs 24/7 on a Mac or a Linux
box, driving an agent against a live SSH+tmux session with no app open. Phones and
tablets become notification surfaces via APNs pushes through the control plane
(`controlPlane` block), the `notifyCommand` hook, and the S3 remote-supervision
channel — and, with the cloud transcript and inbox, full remote consoles for an agent
running somewhere they cannot reach.

## Layout

- **`Sources/FinAgentCore/`** — the UI-free engine, and the *single source of truth* for
  the agent logic shared with the app: the root `project.yml` includes this directory as
  an additional sources path of the `fin` target, so the same files compile into both the
  app and this package. Keep these files free of UI, SwiftData, and app-only imports.
  - Extracted from the app: `AgentTranscript`, `AgentTools` (the full six-tool roster —
    `read_terminal`, `send_input`, `remember`, `recall`, `request_input`, `monitor` —
    plus the destructive-command heuristic), `AgentIntentClassifier`, `AgentEndpoint`,
    `TerminalEventLog`.
  - `AgentTurnLogic` — the shared statics formerly private to `AgentRuntime`
    (typed-body/submittable normalization, echo-vs-response detection, result framing,
    settle windows, `containsTaskComplete`). `AgentRuntime` forwards to these.
  - `AgentTurnEngine` — headless reproduction of `AgentRuntime`'s endpoint loop,
    including the split-Return send (typed body, 250 ms pause, then `\r` as its own
    keystroke — a `\r` in the same stdin burst reads as paste content to TUI input
    libraries). **Auto-mode only:** a daemon has no one to ask, so destructive-looking
    commands are refused with a logged error instead of waiting on an approval.
    Tools that act on runner-owned state are forwarded through hooks
    (`onRequestInput`, `onMonitorStart`, `onMonitorStop`); `remember`/`recall` answer
    honestly that memory is unavailable in headless mode.
  - `HeadlessTerminalSession` — Citadel SSH+PTY feeding a `TerminalEventLog`, no
    SwiftTerm. Probe-based shell readiness (`waitForShellReady`) because keystrokes
    typed into a still-spawning shell are silently flushed.
- **`Sources/fin-agentd/`** — the executable. Reads a JSON config (see
  `config.example.json`), connects, submits the task, then heartbeats a reflective
  prompt until the model ends a reply with `TASK COMPLETE`. JSONL audit log; clean
  SIGINT/SIGTERM shutdown. `DaemonDirectiveClient` is the S3 supervision consumer;
  `DaemonTranscriptUplink` is the cloud transcript writer; `DaemonNotifyClient` is the
  push-notification uplink to the control plane.

## Config

Beyond `server`, `agent`, and `task`, every field is optional:

| Field | Default | Meaning |
|---|---|---|
| `notifyCommand` | — | Hook run on request-input / task-complete (below) |
| `auditLogPath` | `./fin-agentd-audit.jsonl` | Local JSONL trail |
| `stayResident` | `false` | `TASK COMPLETE` suspends instead of exiting (below) |
| `agentID` | — | The app-side Agent UUID this harness embodies; malformed is fatal (exit 64) |
| `deviceToken8` | `cloud001` | Short host id echoed as the status document's `device_id8` |
| `supervision` | — | The S3 channel (below) |
| `transcript` | — | The cloud transcript (below) |
| `controlPlane` | — | Endpoint + bearer token of the serverless control plane; turns notify events into APNs pushes (below) |

### stayResident

The cloud posture: one isolated EC2 instance per agent outlives any one task. With
`"stayResident": true`, `TASK COMPLETE` still fires the notify hook and the status PUT,
but the process, the SSH session and the poll loop stay up — only heartbeats suspend,
exactly as they do for `request_input`, because beats would otherwise re-run finished
work. The status document keeps reporting `task-complete` (a routine idle PUT can't
overwrite it) until the next directive or inbox message arrives, which resumes normal
operation. Audited as `[monitor] task complete — staying resident, beats suspended` /
`[monitor] resumed — new message after task completion`. SIGINT/SIGTERM still shut down
cleanly; without a `supervision` block there is nothing that can wake a suspended agent,
so pair the two.

### Session routing registry

If a `routing-registry.json` sits next to the audit log (the same directory that holds
`fin-agentd-directives.json`), the daemon appends the tmux session-routing block to its
system prompt at startup: the model learns which registered sessions it may route
terminal work into, and that every other live session is off-limits. Schema:
`evals/tmux-routing/registry.example.json`. The app reads the same basename from its own
per-device spot, `Application Support/fin/routing-registry.json` — machine-scoped in both
places on purpose, because a tmux session exists on exactly one host, so the file never
rides CloudKit or any synced channel. Nothing creates the file automatically; absent (or
empty) it changes nothing, and the prompt stays byte-identical to a registry-less build.
Read once at startup, so edits take effect on the next launch.

## Run

```sh
swift build -c release --product fin-agentd
./.build/release/fin-agentd config.json
```

### Linux

The daemon package (and only the package — never the app) builds and tests on Linux.
In a `swift:6.x` container:

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift build -c release --product fin-agentd
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift test
```

Platform notes baked in: `TerminalEventLog` drops its Combine observability where
Combine doesn't exist, `AgentEndpoint` falls back to a buffered SSE read (corelibs
Foundation has no `URLSession.bytes`), and networking imports `FoundationNetworking`
conditionally. Signal handling (`DispatchSourceSignal`) and the notify hook
(`Process` → `/bin/sh`) work as-is under swift-corelibs.

## Agent tools

The engine advertises the same six tools as the app, with these headless behaviors:

- **`read_terminal` / `send_input`** — identical to the app, except destructive-looking
  commands are refused outright (no approval sheet exists here).
- **`request_input`** — records the question in the audit log and fires the notify hook
  with `FIN_EVENT=request-input`, `FIN_MESSAGE=<question>`. The answer arrives as a
  supervision directive or an inbox message (below) — there is no local user to type
  one. Heartbeats pause until one lands (each beat would otherwise re-ask the question
  and re-fire the hook — one push per interval, forever); audited as
  `[monitor] paused awaiting user input` / `[monitor] resumed — user input received`.
  The daemon stays connected and keeps polling while paused.
- **`monitor`** — drives the daemon's own heartbeat loop. `start` enables beats and can
  retune the cadence (`interval_seconds` clamped to 15…600; 0 keeps the current
  interval); `stop` idles the loop while the daemon stays connected — a later directive
  re-arms it. Audited as `[monitor] armed (every Ns)` / `[monitor] disarmed by model`.
- **`remember` / `recall`** — no memory store exists in headless mode; the tool result
  says so honestly and asks the model to carry anything important in its reply text.

## Remote supervision (S3 channel)

Add the optional `supervision` block to the config and the daemon becomes a consumer of
the same bucket contract the app's `AgentDirectiveChannel` speaks:

```json
"supervision": {
  "directiveURL": "https://…/directives.json",   // GET (presigned URL works)
  "statusURL": "https://…/agentd-status.json",   // PUT; optional
  "inboxURL": "https://…/agentd-inbox.json",     // GET; optional (below)
  "agentName": "fin-agentd-1",
  "pollSeconds": 30                                // optional; default 30
}
```

> **Presigned URLs must be SigV4.** Generate them with
> `boto3.client("s3", config=Config(signature_version="s3v4"))` (or the equivalent).
> A SigV2 presigned URL 403s any PUT, because the daemon sends a
> `Content-Type: application/json` header that SigV2 signatures don't cover —
> live-proven against a real bucket. This applies to the transcript `putURL` and the
> inbox GET too, not just the status PUT.

- **Directives** — the document is polled with `If-None-Match` (ETag) and a 1 MB body
  cap. Directives whose `agent` matches `agentName` (case-insensitive) or `"*"`, with
  `kind: "user_message"` and non-empty `text` (≤ 8000 chars), are injected as user
  messages via the engine **between turns only**. A directive with `"arm_monitor": true`
  (optionally `"interval_seconds"`) also takes the monitor-start path above; any fresh
  directive restarts a model-disarmed heartbeat. Applied ids are deduped in
  `fin-agentd-directives.json` next to the audit log (capped at 500, oldest evicted) so
  a restart never replays old instructions.

  ```json
  {"version": 1, "directives": [
    {"id": "d-1", "agent": "fin-agentd-1", "kind": "user_message",
     "text": "Also run the linter before you finish.",
     "arm_monitor": true, "interval_seconds": 120}
  ]}
  ```

- **Inbox** — the same document schema, written by the iOS app rather than a supervisor,
  polled on the same tick as `directiveURL`. Its ids are arbitrary strings (`m-<uuid>`),
  never the supervisor's monotonic `d-N`, and nothing assumes otherwise. Pending entries
  merge behind the directive document's, each in its own document order, and both share
  one applied-id ledger, so a message applied from either channel never replays. An
  inbox message resumes a `request_input`-paused or `stayResident`-suspended agent
  exactly as a directive does. The two sources fail independently: a dead directive URL
  audits `[s3] poll failed: …` and still delivers inbox messages, a dead inbox audits
  `[s3] inbox poll failed: …` and still delivers directives.

- **Status** — after every poll and every finished turn the daemon PUTs:

  ```json
  {"schema": 1, "device": "fin-agentd", "device_id8": "cloud001",
   "daemon_version": "1.2.0", "agent": "fin-agentd-1", "state": "idle",
   "last_applied_id": "d-1", "last_turn_at": "…", "last_assistant_preview": "…",
   "last_error": null, "updated_at": "…"}
  ```

  (`last_assistant_preview` is capped at 200 characters; `last_error` carries the most
  recent turn failure, including a directive-injected turn that failed after its id was
  consumed. `daemon_version` tells a supervisor which harness features exist.)

- **Audit** — `[s3] applied directive <id>` on application, `[s3] poll failed: <reason>`
  / `[s3] put failed: <reason>` on failure, throttled to one line per 5 minutes per
  distinct error string so a dead bucket can't flood the log. A directive whose injected
  turn fails audits `[s3] directive <id> turn failed — not retried` (application is
  at-most-once by design); a dedupe state file that exists but doesn't parse audits
  `[s3] state file unreadable — dedupe reset` once at startup.

## Cloud transcript

```json
"transcript": {
  "putURL": "https://…/agentd-transcript.jsonl",  // PUT; required within the block
  "flushSeconds": 15,                               // optional; default 15
  "maxLines": 2000                                  // optional; default 2000
}
```

Add the block and the daemon keeps a rolling in-memory ring of its last `maxLines` audit
lines and PUTs the **whole** document — every retained line, newline-joined — after each
finished turn and at most once per `flushSeconds` in between. This is what the iOS app
renders for an agent whose runtime is on a box the phone can't reach: paired with
`inboxURL` it is a full remote console, the transcript downstream and the inbox up.

The line format is a wire contract with the app's `AgentMirrorRecord.init(jsonlLine:)`
(`fin/Agent/AgentMirrorReader.swift`) — the same JSONL the app writes itself via
`AgentLogEntry.jsonlLine()`. Keys are snake_case and sorted; timestamps are plain
ISO8601 with **no fractional seconds** (the reader's formatter rejects them); UUID
strings are uppercase. `kind` is an `AgentLogKind` raw value — the engine's audit kinds
already are, and anything unrecognized is emitted as `notice`. Each line carries `id`,
`run_id` (one per daemon process), `sequence`, `timestamp`, `agent_id`, `agent_name`,
`server`, `kind`, `text`, `model`, `temperature`, `attempt`, `retry_count`,
`is_failure`, plus `tool_name` / `tool_arguments` on tool lines.
`DaemonTranscriptTests` pins the reader's expectations as a fixture, so drift fails a
test rather than silently rendering an empty timeline.

**Every text field passes through `MemoryRedactor` before it enters the ring** — this
data leaves the machine, and it quotes the same raw terminal output that keeps the app's
own log store off CloudKit. PUT failures audit `[transcript] put failed: <reason>` to
the local trail only (a transcript nobody can fetch is the one place its own failure
could never be read), throttled to one line per 5 minutes per distinct error, and are
otherwise swallowed.

## Notify events

Two events surface to a human, on two independent paths that both fire when both
are configured:

| Event | Fired when |
|---|---|
| `request-input` | The model called `request_input`, or 5 consecutive turns failed |
| `task-complete` | The model ended a reply with `TASK COMPLETE` |

**Push notifications** (`controlPlane` block): `DaemonNotifyClient` POSTs the
control plane's `/notify` route, which fans the alert out over APNs to every
device token the app has registered (`scripts/cloud-agent/control-plane`). The
message is redacted through `MemoryRedactor` and capped at 500 characters
before it leaves the machine — the same rule as the cloud transcript — and the
title comes from the event (`<agent> needs input` / `<agent>: task complete`).
POST failures audit `[notify] post failed: <reason>` (throttled to one line per
5 minutes per distinct error) and are otherwise swallowed. The bearer token
never reaches a log line.

**Shell hook** (`notifyCommand`): runs via `/bin/sh -c` with `FIN_EVENT` and
`FIN_MESSAGE` in its environment. Launch failures are logged and swallowed — a
broken notifier never takes down the agent.

## Test

```sh
swift test
```

Pure-logic tests always run (engine dispatch, directive and inbox polling with an
injected transport, the transcript line format against the app reader's contract, the
stayResident gates, classifier guards). The live integration tests (real sshd + tmux on
127.0.0.1, LM Studio at `localhost:1234`) skip cleanly when the dev-machine
prerequisites are missing.
