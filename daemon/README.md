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

Inside `server`, `connectCommand` (typed into the shell once the PTY is up — normally a
`tmux new-session -A …` attach) and `environment` (extra SSH env requests) are optional
too. Since 1.4.0 the environment always carries one entry the config can't remove:

### The session marker (`LC_FIN_AGENT`)

Every SSH session the daemon opens carries the environment request `LC_FIN_AGENT=1` on
its PTY channel — **always**, not only when `server.environment` lists it. It exists
because a login shell that auto-attaches every interactive remote login to the human's
real tmux session (`exec tmux new-session -A -s main`) does so *before* the daemon types
its `connectCommand`, so the daemon's `FIN_READY_*` readiness probes and every keystroke
after them land in the human's live session (the 2026-09-05 iMac shakedown bug). The
marker is how that shell profile tells the daemon apart. The daemon has no PTY+exec
mode (Citadel's `withPTY` is a shell channel), so the marker — not a remote command — is
what keeps it out of your session.

It is `LC_`-prefixed because the sshd configs that forward anything at all forward
`LC_*`: macOS (`/etc/ssh/sshd_config.d/100-macos.conf`) and Debian/Ubuntu ship
`AcceptEnv LANG LC_*`, so there it crosses the wire with no sshd change. The RHEL family
— Fedora, RHEL, and Amazon Linux, which derives from Fedora — enumerates locale names
instead (`AcceptEnv LANG LC_CTYPE LC_NUMERIC … LC_ALL LANGUAGE`, no glob), which drops
`LC_FIN_AGENT` silently; a hardened sshd may forward nothing. Check the host you SSH
into with `sshd -T | grep -i acceptenv`, and where `LC_*` isn't listed add
`AcceptEnv LC_FIN_AGENT` to `sshd_config` (or to a drop-in under
`/etc/ssh/sshd_config.d/` where the main file includes that directory) and reload sshd
— that gates any other `server.environment` entry too. The cloud worker's bootstrap
does not do this today: its `fin-agent` login shell is a stock bash with no
auto-attach, so nothing there needs the marker yet.

If your login shell auto-attaches tmux, gate it on the marker:

```fish
# fish — ~/.config/fish/config.fish
if status is-interactive; and set -q SSH_TTY; and not set -q TMUX; and not set -q LC_FIN_AGENT
    exec tmux new-session -A -s main
end
```

```sh
# bash / zsh — in the SAME file as your auto-attach. An SSH login shell reads
# ~/.bash_profile (or ~/.profile) and ~/.zprofile; ~/.bashrc runs only if one of
# those sources it (Fedora's skeleton does, macOS's default doesn't).
if [ -n "$SSH_TTY" ] && [ -z "$TMUX" ] && [ -z "$LC_FIN_AGENT" ]; then
    exec tmux new-session -A -s main
fi
```

`server.environment` is merged over the marker: an entry named `LC_FIN_AGENT` changes
its value (any non-blank string), but nothing in the config can remove or blank it — a
blank value would read as unset to the `[ -z … ]` guard above, and a `null` value fails
the config load (exit 64, `bad config`) rather than dropping the key. Everything else in
the block is passed through as-is, subject to the same `AcceptEnv` caveat.
(`DaemonSessionEnvironmentTests` pins what the daemon requests;
`DaemonSessionMarkerLiveTests` proves the request reaches a real login shell — and that
the shell which got it is not inside tmux — against the dev machine's own sshd.)

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
  `fin-agentd-directives.json` next to the audit log — since 1.4.0 an object
  `{"applied": […], "seeded": […], "seed_pending": false}` (the 1.3.0 bare array still
  loads); `applied` is capped at 500, oldest evicted — so a restart never replays old
  instructions.

  **First run (1.4.0).** A box with no ledger file at all — a fresh cloud worker, a new
  install — treats the first directive document it successfully reads as history, not
  instructions: every id in it (matching this agent or not, well-formed or not) is
  recorded as seeded without being injected, the ledger is written, and one line audits
  `[s3] first run: N historical directive(s) in the supervision doc marked applied, not
  replayed`. That read happens **at launch** — before the SSH connect, the readiness
  probes and the first task turn, which together can run for minutes — so the boundary
  is the same one the control plane draws when it empties the per-agent inbox, and a
  directive written after launch is delivered even if it lands mid-first-turn. (If the
  launch fetch fails, `[s3] first run: directive document not read at launch — seed
  deferred to the next poll` is audited and the poll loop seeds on the first document
  it does read.) Seeded ids live in the ledger's own `seeded` list, uncapped: the
  document may hold more than the 500-id applied cap, and a seeded id evicted from a
  capped list would replay — so the audit count is what was kept. The document is
  shared by every agent, so the control plane can't empty it at launch the way it
  empties the per-agent inbox; before this a fresh worker replayed weeks of operator
  directives, one model turn each. An existing ledger — even an empty `[]` — or a
  corrupt or unreadable one is *not* a first run: the daemon has run here, and every
  unapplied directive is delivered as before. The one exception is a ledger the first
  run itself wrote while its seed was still owed (an inbox message applied while the
  directive URL was failing, then a restart — systemd's `Restart=always`): the file
  says so (`"seed_pending": true`), the next launch audits `[s3] first run: resumed
  with the directive seed still pending`, and the seed lands when the document finally
  arrives instead of the document replaying.

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
  `[s3] inbox poll failed: …` and still delivers directives. The inbox is exempt from
  the first-run seed: the control plane empties it at launch (the launch is the
  conversation boundary), so a message that arrives while the worker boots still
  applies.

- **Status** — after every poll and every finished turn the daemon PUTs:

  ```json
  {"schema": 1, "device": "fin-agentd", "device_id8": "cloud001",
   "daemon_version": "1.4.0", "agent": "fin-agentd-1", "state": "idle",
   "last_applied_id": "d-1", "last_turn_at": "…", "last_assistant_preview": "…",
   "last_error": null, "updated_at": "…"}
  ```

  (`last_assistant_preview` is capped at 200 characters; `last_error` carries the most
  recent turn failure, including a directive-injected turn that failed after its id was
  consumed. After a first-run seed, `last_applied_id` is the newest seeded id — the
  high-water mark — until the daemon applies something itself. `daemon_version` tells a
  supervisor which harness features exist; 1.4.0 = the always-on `LC_FIN_AGENT` session
  marker and the first-run directive high-water.)

- **Audit** — `[s3] applied directive <id>` on application, `[s3] poll failed: <reason>`
  / `[s3] put failed: <reason>` on failure, throttled to one line per 5 minutes per
  distinct error string so a dead bucket can't flood the log. A directive whose injected
  turn fails audits `[s3] directive <id> turn failed — not retried` (application is
  at-most-once by design); a dedupe state file that exists but doesn't parse audits
  `[s3] state file unreadable — dedupe reset` once at startup; a first run with history
  in the directive document audits `[s3] first run: N historical directive(s) in the
  supervision doc marked applied, not replayed` once, on the read that seeded it —
  normally the launch fetch (a missing ledger with an empty document audits nothing).
  The other first-run lines: `[s3] first run: directive document not read at launch —
  seed deferred to the next poll` when the launch fetch failed, and `[s3] first run:
  resumed with the directive seed still pending` when a restart finds a ledger the
  previous life wrote before its seed landed.

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
injected transport including the first-run high-water and its launch-time prime, the
`LC_FIN_AGENT` session marker, the transcript line format against the app reader's
contract, the stayResident gates, classifier guards). The live integration tests (real
sshd + tmux on 127.0.0.1, LM Studio at `localhost:1234`, and
`DaemonSessionMarkerLiveTests` asking a real login shell whether the marker arrived)
skip cleanly when the dev-machine prerequisites are missing.
