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
| `site` | — | This body's identity on the control plane (below); requires `controlPlane` |

Inside `server`, `connectCommand` (typed into the shell once the PTY is up — on a resident
site `exec tmux -L <socket> new-session -A -s <session> \; set status off`, which is where the
agent's own tmux SERVER is chosen; see "The tmux boundary") and `environment` (extra SSH
env requests) are optional too. Since 1.4.0 the environment always carries one entry the config can't remove:

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

### The tmux boundary: a private socket, not a parser

**The agent's shell runs on its own tmux server.** The resident `connectCommand` is
`exec tmux -L fin new-session -A -s fin \; set status off`. `tmux -L` names a socket
*file*, so Fin's tmux server is a different process, with a different socket, from the one
hosting the human's `main`. Nothing typed inside Fin's shell can reach the human's sessions
— not because the string was classified as safe, but because the server it would have to
talk to is not the one its `$TMUX` points at. Both facts the daemon needs (the socket name
and the session name) are parsed out of that one config string; nothing is hardcoded to
`fin`, so provisioning with `FIN_TMUX_SOCKET=wharf FIN_TMUX_SESSION=dockside` guards
`wharf`.

**`exec` is part of the boundary, not decoration.** Without it the tmux client is a child
of the login shell, and `tmux detach` — or `exit`, or killing its own session, all ordinary
allowed work *on its own server* — returns the PTY to that login shell. With `exec`, leaving
tmux ends the SSH session instead; the daemon reconnects (with backoff, so a shell that
cannot start tmux cannot spin) and re-attaches the same session, so the agent's work stays
inside a durable session rather than scattering across login shells that die with the
connection. What `exec` is **no longer** load-bearing for is safety: since R1 requires every
tmux command to name Fin's socket, a shell that fell out of tmux cannot reach the human's
server either.

**Why the previous design was replaced.** Until this branch the daemon shared the human's
socket and a 1,579-line `TmuxCommandGuard` parsed every `send_input` string, classifying
tmux subcommands against an allow-list of session names. Eight independent reviews found
**thirty-five distinct high-severity bypasses**, and each fix round produced new ones:
quoted `;` separators, getopt clusters, `kill-session -a` inverting `-t`,
`send-keys -K -c <client-tty>` with no `-t` at all, shell keywords before tmux,
redirections and brace expansion splitting a simple command, command substitution inside
double quotes, `sh -` reading stdin, inline interpreters (`python3 -c`, `perl -e`,
`node -e`, `osascript`), heredocs, backslash-newline continuations, quoted program names.
That is not a buggy implementation; it is evidence that a byte-level parser over an
adversarially-shaped shell string is the wrong *shape* of solution. The allow-list, the
90-command classification table, the `fin-` namespace and the registry snapshot are all
deleted along with it.

**The read half moved out of the shell** (see `read_session` under "Agent tools"). A
private socket costs exactly the capability a resident site exists for: `tmux capture-pane
-t main -p` typed into Fin's shell now talks to Fin's own server, where `main` does not
exist. So the daemon exposes a tool whose parameter is a session NAME, never a command
line, and runs a fixed argv against the DEFAULT socket on a separate SSH exec channel.

**What is left of the guard** (`Sources/FinAgentCore/TmuxCommandGuard.swift`): seven rules, no
classification, and — as of this round — no question about the ENVIRONMENT a command would
run in. That question is what the deleted machinery was for. Its two answers were a live
probe of the shell (R0: type `echo …$TMUX` into the PTY before every tmux-bearing send) and
a named list of wrappers that start a fresh environment (R1b: `ssh`, `sudo`, `env -i`,
`launchctl`…). Both are gone, because R1 now demands that a tmux command *say* which server
it means: `tmux -L fin …` reaches Fin's server from any shell, confined or not, and anything
that names no server is refused. It is a second layer behind a real boundary, not the
boundary itself.

The file did not shrink this round, and pretending otherwise would be the wrong kind of
tidy: 810 lines of code against last round's 782 (1,414 total against 1,344), because R6,
R7 and the two-posture prompt cost slightly more than R0, R1b and `env -i` detection
returned. What changed is what the code is *for*. Nothing in it now tries to model an
environment it cannot see, which is the class of reasoning every one of the thirty-five
bypasses lived in.

| Rule | What is refused | Why it is not the socket's job |
|---|---|---|
| R1 | A tmux invocation that names **another** server (`-L other`, `-S /path`, in every getopt-cluster and quoted spelling) — **or names none at all** (`tmux ls`, `tmux send-keys …`, `ssh box tmux …`, `sudo tmux …`) | Naming another socket is the explicit way out. Naming none is the implicit one: with no `-L`/`-S`, tmux reads its socket from `$TMUX`, which belongs to whichever shell runs the command — this one, or a fresh one under ssh/sudo/cron where it is empty and tmux falls back to the label `default`, the human's server. The guard cannot tell those apart from the command text, so it stops trying: the refusal names the exact rewrite, and six characters make it legal everywhere. tmux's precedence is mirrored: **`-S` wins over `-L`** however they are ordered (man tmux; verified on 3.6a), so `-S <the human's socket> -L fin` is refused. Not applied on a host still on the shared default socket, where no flag would say anything. |
| R2 | `kill-server`, and every prefix tmux would resolve to it (`kill`, `kill-s`, `kill-serv`) | It ends the agent's own shell mid-turn; on a host that never got a private socket it ends everything. `kill-session`/`-window`/`-pane` are NOT prefixes of it and stay allowed. |
| R3 | A signal aimed at tmux, judged on the whole LINE: `pkill tmux`, `killall tmux`, and `kill $(pgrep tmux)` | A signal is not a tmux command. It kills every tmux server on the machine, and no socket boundary stops it. Line-level because the pid comes from somewhere else on the line — segment by segment, `kill $(pgrep tmux)` was a `kill` with no tmux in it next to a harmless `pgrep`. `pkill node` and `kill 1234` are untouched: the *word* tmux has to be on the line. |
| R4 | Unsetting or overriding a variable tmux picks its SERVER from — `TMUX` **and `TMUX_TMPDIR`** (`TMUX= tmux …`, `env -u TMUX tmux …`, `unset TMUX`, `set -e TMUX`, `export TMUX_TMPDIR=…`) | **The one hole the private socket does not close** — see the residual list. `TMUX_TMPDIR` is the *directory* a `-L <label>` resolves in, so setting it re-points even Fin's own label at any socket file the model picks. (`TMUX` itself matters much less now that R1 refuses socket-less commands; `TMUX_TMPDIR` matters more, because it poisons the flag R1 demands.) |
| R5 | A half-typed line (trailing `\`, or an open quote) that mentions tmux, or a trailing fragment that could still *become* `tmux` | The PTY concatenates sends, so `tmux -L \` and `fin ls` are two individually-harmless calls the shell joins at its continuation prompt. |
| R6 | A line that names tmux and **starts a command with a substitution** — `$(which tmux) -L default send-keys …`, `` `which tmux` … `` | The lexer makes `(`/`)`/backticks hard boundaries, so this shape put the word `tmux` in one segment and `-L default send-keys …` in the next, as an argument list with no program: R1 compared nothing and allowed both halves. Verified on a private socket that `$(which tmux) -L fintest … ls` really does select the named socket. A substitution in *argument* position (`echo $(date)`, `kill $(pgrep tmux)`) is untouched. |
| R7 | A line that names tmux and hands a command to a **scheduler**: `crontab -`, `at`, `batch`, `launchctl`, `systemd-run` | What they run happens later, in a shell no guard is judging, and the tmux words are usually not in a command position this send can see (`echo '… tmux …' \| crontab -` is a quoted argument of `echo` on one segment and a `crontab` on the next). Line-level, for the same reason R3 is. |

Everything else on the agent's own server is now ordinary work — `new-session`,
`send-keys`, `kill-session`, `rename-session`, `set-option -g`, even `run-shell` — as long
as it names the socket. There is no allow-list, nothing to register, and no `fin-`
namespace, because every session on that server is the agent's.

**What survives from the old file, and why: the lexer.** Finding the word `tmux` at all
still has to see through shell quoting and escaping (`t\mux`, `tm"u"x`, `$'tmux'`, and
`TMUX` on a case-insensitive volume — all verified to run tmux), through chaining (`;`,
`|`, `&&`, `$( )`, backticks), through wrappers that run their **assembled** arguments
(`sh -c 'tmux …'` *and* `sh -c tmux\ -L\ default\ …`, `eval`, `python3 -c`, `awk`,
`osascript`), through heads this parser does not model (`find -exec tmux …`,
`if tmux …; then`, `for … do tmux …`), and through stdin, which it cannot see at all
(`echo … | sh`, `xargs tmux` — both refused whole rather than parsed). Those tests are kept
verbatim; they were the part that was genuinely hard. The word "assembled" there is this
round's fix: the payload recursion used to ask only whether a word had been *quoted*, so a
backslash-escaped command line (`sh -c tmux\ -L\ default\ send-keys\ -t\ main\ …`) lexed as
three unquoted words, `mentionsTmux` answered false, and the whole evaluation
short-circuited to `.allow` before any rule ran.

False refusals it still makes, all in the safe direction: `set -q TMUX` and other READS of
the variable, which R4 cannot tell from a write; a tmux command line quoted *inside* text a
runner will execute (`sh -c 'echo "tmux -L x ls" >> notes'`); a bare shell anywhere in a
line that mentions tmux (`tmux ls; bash`); a half-typed line, including one that is only a
read; **file content that happens to be a tmux command** — a here-doc body, a doc, a script
being written (the way through is a quoted argument, which is data:
`printf 'tmux -L other ls\n' >> notes.md`, and the refusal text says so); a `kill` on any
line that also names tmux; `crontab -l | grep tmux`; `$(brew --prefix)/bin/tmux -L fin ls`
(R6 cannot tell a substituted path from a substituted program); and — the new and by far
most common one — **every tmux command the model forgets to put `-L fin` on**. That last one
is a real cost, paid one wasted turn at a time: the prompt states the rule twice and the
refusal names the exact rewrite, but a small model will still trip on it.

**Residual risk, stated plainly.**

- **`TMUX_TMPDIR` re-points the flag R1 demands.** `-L <label>` resolves under
  `$TMUX_TMPDIR/tmux-<uid>/<label>`, verified here by pointing a private label at a scratch
  directory, so a model that can set that variable makes `tmux -L fin …` — the one form R1
  allows — mean any socket file it likes. R4 refuses the direct spellings (including a bare
  `export TMUX_TMPDIR=…` with no tmux command in the same send, since the guard sees one
  send at a time). It cannot refuse an assembled one: a value built up across sends, a
  helper script, an argv constructed structurally inside an interpreter, a shell function.
  **This is the sharpest edge of the current design**, and it is sharper than before,
  because the flag is now the whole rule.
- **A socket-less tmux under a head the parser does not model.** R1's second half fires
  where the guard can see tmux in *command position*: as the head, behind a stripped prefix
  (`sudo`, `env FOO=1`, `exec`), or under a modelled runner (`ssh`, `timeout`, `sh -c`,
  `xargs`…). Under an unmodelled head it does not, because there the word is far more often
  prose — `man tmux`, `which tmux`, `brew install tmux`, `grep -e tmux config.fish` — and
  refusing those costs real work in this repo. So `find . -exec tmux send-keys -t main x \;`
  is allowed, and lands on whatever `$TMUX` says: Fin's own server whenever the
  connectCommand took effect, the human's if it silently did not. (Naming another socket, or
  `kill-server`, is still refused there — those are unambiguous.) The dedicated UNIX user
  below is what closes this by construction.
- **The agent owns the directory its own socket lives in.** `-L fin` resolves to
  `/tmp/tmux-<uid>/fin`, a path the agent can delete and replace with a symlink to the
  human's socket, at which point `tmux -L fin …` — the command R1 *requires* — is talking to
  the human's. No parser can see that: the dangerous command is an `ln`, not a tmux. Kernel
  permissions are the only real answer; see the dedicated-user upgrade.
- **Same UNIX user.** The agent's SSH session runs as the human's own uid, so the default
  socket is *reachable* by any process that opens it deliberately; the guard is a heuristic
  standing in front of a door that is unlocked. Indirection the guard cannot see —
  `T=tmux; $T …`, base64/`eval`, an alias or shell function, a Makefile target, a
  `~/.tmux.conf` written now and read by a later tmux, a command split across two sends —
  remains open, as does plain non-tmux damage (`pkill -f mlx_lm`, `launchctl bootout`, an
  `rm` shape `DestructiveCommandHeuristic` misses).
- **Confinement is no longer proven, and deliberately so.** The daemon still asks the shell
  for `$TMUX` **once**, at launch, and logs loudly when the answer is not its own socket —
  but nothing refuses on that answer any more, for two reasons. It is stale the moment the
  shell does anything; and it comes back through the same PTY the model writes to, so a
  filter left running in the pane can print whatever the check wants to read (a `sed` that
  rewrites the probe line is enough). Under the previous design that forgery turned "refuse
  all tmux" into "allow socket-less tmux", i.e. into the human's server. Now it buys
  nothing, because a socket-less tmux is refused whatever any shell claims. What an
  unconfined shell still costs is real, just not a boundary: the agent's work is not inside a
  durable tmux session, so it dies with the SSH connection. That is what the log line is for.
- **`read_session` reads, and reading is not nothing — in both directions.** *Out:* it pipes
  another user's terminal into the model's context and from there into the cloud transcript;
  output is capped and run through `MemoryRedactor` (the same scrub the transcript uses),
  which catches shapes, not every secret. *In:* those panes are the untrusted ones (the
  human's `main` hosts other coding agents and whatever was pasted into them; build and
  `curl` output can carry attacker-authored text), and the model reading them holds
  `send_input` on its own server and `notify` to a human. The capture is fenced and labelled
  as data, and a pane cannot forge the fence (its copy of the marker is neutered) — but a
  fence is a mitigation, not a proof: a small model can still be talked into something by
  text inside one.
- **A timed-out `read_session` costs an SSH session slot until the remote command exits.**
  Citadel's public `executeCommandStream` returns the stream and keeps the `Channel`, so a
  read that hits its 20-second bound cannot be closed — the remote `tmux` holds the slot
  (OpenSSH's default `MaxSessions` is 10, and the PTY holds one). The daemon counts those:
  after two, the next read recycles the whole SSH connection instead, which drops every
  abandoned channel and re-attaches the same tmux session. So the failure is a visible
  reconnect and one honest tool error, not a read path that silently dies for the life of
  the connection.
- **A registry naming someone else's session is now read-only in practice.** Routing still
  renders its prompt section — on a private socket it renders the variant that sends the
  model to `read_session` and tells it NOT to recreate a session it cannot see — but a
  registered session that lives on the default socket cannot be driven from Fin's shell any
  more. The shipped resident registry lists only Fin's own session, so nothing regresses
  today; a multi-session routing story needs Fin's collaborators to live on Fin's socket.
- **A host still on the SHARED default socket has no boundary at all**, and its prompt now
  says so instead of inviting the opposite. `.standard` is what the EC2 template and a
  `FIN_TMUX_SOCKET=""` provision produce: there R1 is not applied (no flag would mean
  anything), the human's sessions are on the same server, and what keeps Fin out of them is
  the prompt paragraph plus the routing section's OFF-LIMITS rule — instructions, not code.
  `kill-server` and signals are still refused. The launch log says which posture the site is
  in; prefer the private socket.
- **`set status off` removed the traffic the idle timeout relied on.** The connection carries
  `IdleStateHandler(readTimeout: 90s)`; with the tmux status bar off, an idle pane emits
  nothing, so a quiet daemon reconnects roughly every 90 seconds. Each reconnect re-types the
  connectCommand (re-attaching the same session), and the reconnect backs off if the session
  keeps dying immediately — so this is churn in the log, not a correctness problem. It is
  written down because it is easy to mistake for a bug.

**The airtight version, and what it costs.** Run the agent's SSH session as a **dedicated
UNIX user**. tmux creates its socket directory `0700` under `/tmp/tmux-<uid>`, so a
different uid cannot open the human's socket **by kernel permission** — `TMUX=` included,
and every other spelling with it. The cost is one `sudo` step (create the user, authorize
the site key for it, chown the daemon's state directory), a decision about what that user
may read of the human's files, and a rethink of `read_session` (which runs as whoever the
SSH session is: under a dedicated user it would need the human's socket group-readable, a
small setgid helper, or a narrowed scope). The installer is deliberately zero-sudo, so
this is **out of scope for the code and squarely Levi's call** — it is named here so the
choice is available, not so it looks done.

**The guard is off unless a host arms it.** `TmuxSendGuard.unenforced` is an explicit
named value rather than a nil hook, so it can never be disarmed by omission, and
`TmuxSendGuard.forHost` arms it whenever the host has a tmux `connectCommand` or a routing
registry. The Fin app leaves it unenforced: it drives an arbitrary SSH session where tmux
is optional and the user's own session is often literally `main`. When armed, the daemon
also appends a prompt paragraph telling the model where it lives, that its own server is
unrestricted, and that `read_session` is the path to everything else — a refusal the model
understands beats a refusal it fights.

**Only the armed guard's own paragraph may claim enforcement.** `SessionRouter.promptSection`
states the routing rule and nothing more, deliberately: it is not daemon-only —
`AgentRuntime` renders the same paragraph in the Fin app, where `AgentTurnEngine.tmuxGuard`
is `.unenforced` and no guard exists — so a sentence there promising that "send_input
refuses … before a byte reaches the terminal" would tell an app user in auto-approve mode
about a gate that is not running. That sentence lives in `TmuxCommandGuard.promptGuidance`,
which is appended only when `isEnforced`. The wiring from `forHost` through
`Daemon.makeTurnEngine` to the engine is itself covered by `DaemonTmuxGuardPromptTests` —
before that factory existed, deleting the one line that armed the engine left the whole
suite green while the prompt still told the model the gate was there.

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

The engine advertises the same shared roster as the app
(`AgentToolSpec.all`), with these headless behaviors:

- **`read_terminal` / `send_input`** — identical to the app, except destructive-looking
  commands are refused outright (no approval sheet exists here), and a tmux command aimed
  at another tmux server is refused before it reaches the PTY (see "The tmux boundary").
- **`read_session`** — the read half of the private-socket design, and the only way the
  agent can see a terminal that is not its own. Its parameter is a session **name**
  (`^[A-Za-z0-9_.:-]{1,64}$`, no leading `-`, validated in the engine and again in the
  daemon), never a command line; with no arguments it lists the machine's sessions instead
  (`tmux list-sessions -F <fixed format>`). The daemon builds a fixed argv —
  `tmux capture-pane -p -J -t <name> -S -<lines>` — and runs it against the DEFAULT socket
  over a **separate SSH exec channel**, not the agent's PTY: the model supplies one word
  and the daemon supplies every other byte, so there is no command line to inject into.
  Output is capped (`maxResponseBytes` 64 KB — the newest bytes, cut at a line boundary,
  with the drop disclosed — and `lines` clamped to 1…400) and passed through
  `MemoryRedactor`, the same scrub the cloud transcript applies. The read is also bounded in
  TIME (20s on the exec channel), because a model-callable read that never returns would
  hang the turn with no way back short of restarting the daemon. stdout and stderr are kept
  apart and a non-zero exit is a FAILURE, so `can't find session: nope` reaches the model as
  a failed read rather than as the contents of a pane. What does come back is **fenced and
  labelled as untrusted data** — it is somebody else's screen, and a pane that prints the
  fence marker gets that copy neutered. A runner that does not wire
  `AgentTurnEngine.onReadSession` — the Fin app — answers "not available in this runtime"
  rather than an empty capture or an "unknown tool", the same honesty rule as `notify`.
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
  "inboxResetAtLaunch": false,                     // optional; default false (below)
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
  `fin-agentd-directives.json` next to the audit log — since 1.4.0 an object,
  `{"applied": […], "seeded": […], "seed_pending": false, "inbox_seeded": […],
  "inbox_seed_pending": false}` (the inbox pair since 1.4.1; every key is optional on
  read, so a 1.4.0 file or a hand-edited partial one keeps what it carries, and the
  1.3.0 bare array still loads); `applied` is capped at 500, oldest evicted — so a
  restart never replays old instructions.

  **First run (1.4.0; refined in 1.4.1).** A box the daemon has never run on — a fresh
  cloud worker, a new install: no ledger file, and (1.4.1) no audit log from an earlier
  launch either — first writes its ledger with the seeds recorded as owed
  (`"seed_pending": true`, the moment it launches: before any document is read, before
  the private key is read, and whether or not the config has a `supervision` block yet;
  *Not a first run* below says why), then treats the first directive document it
  successfully reads as history,
  not instructions: every id in it (matching this agent or not, well-formed or not) is
  recorded as seeded without being injected, the ledger is rewritten, and one line audits
  `[s3] first run: N historical directive(s) in the supervision doc marked applied, not
  replayed`. That read happens **at launch** — before the SSH connect, the readiness
  probes and the first task turn, which together can run for minutes — so a directive
  written after it is delivered even if it lands mid-first-turn. The boundary is the
  daemon's first directive read, and only that. It is *not* the one the control plane
  draws when it empties the per-agent inbox: that falls at the `POST /workers` call,
  minutes before the daemon's read on a cloud worker (cloud-init, downloads), and
  further before it if the early GETs fail — anything written to the shared document
  between the launch call and the daemon's first read is history to that daemon. The
  inbox has no such window. (If the launch fetch fails, `[s3] first run: directive
  document not read at launch — seed deferred to the next poll` is audited and the poll
  loop seeds on the first document it does read; a 304 with nothing cached — a caching
  proxy can answer that even to the unconditional first GET — defers the same way.)
  That window is minutes only while the reads succeed. A first run whose reads all
  fail — stale URLs, a bucket that isn't there yet, a key the daemon can't read so
  every launch dies — keeps the seed owed *across restarts* (it is on disk), so the
  first document it ever reads, on whichever life that is, is history in full: the seed
  covers everything written since the first life started, not just one launch's
  launch-to-first-read gap. A directive written over that weekend *because* the agent
  went quiet is in that set and is dropped with the rest; the audit count is the only
  trace. That is the intended direction (a silent drop over a noisy replay), and it is
  why the count is audited.
  Seeded ids live in the ledger's own `seeded` list, uncapped: the document may hold
  more than the 500-id applied cap, and a seeded id evicted from a capped list would
  replay — so the audit count is what was kept. The document is shared by every agent,
  so the control plane can't empty it at launch the way it empties the per-agent inbox;
  before this a fresh worker replayed weeks of operator directives, one model turn each.

  *No document yet (1.4.1).* Nothing creates `fin/directives.json` until an operator
  writes the first directive (the control plane only ever PUTs the per-agent inbox), so
  on a bucket without it every first-run read fails — until that first directive, which
  would then be the first successful read, and seeded. A read that finds no object —
  **HTTP 404, and only 404** — therefore means "no history" at first run: the seed
  completes empty, the ledger is written with `seed_pending: false`, `[s3] first run: no
  supervision directive document yet (HTTP 404) — nothing to seed` is audited, and the
  first directive written afterwards is delivered. Only at first run, only for the slot
  whose seed is owed: after it, 404 is a poll failure as before. Timeouts, connection
  errors, 5xx — and 403 — still defer.

  *403 is never "absent".* S3 answers 403 for a missing key when the presigned URL's
  signer may not `s3:ListBucket` — but also for an expired URL (`Request has expired`),
  a `SignatureDoesNotMatch`, an `ExpiredToken` or `InvalidAccessKeyId`, and a denied
  bucket policy; and the XML `<Code>` can't split them, because `AccessDenied` is what
  both a missing key without ListBucket and a denied read say, so the daemon doesn't
  try. Had 403 counted as absent, a resident install that starts with stale 7-day URLs
  would complete its seed empty and write a ledger; the operator re-mints the URLs and
  restarts in the same state directory — no longer a first run — and every unapplied
  directive plus the whole inbox backlog replay, one model turn each. So a 403 is what
  it was under 1.4.0, a plain `[s3] poll failed: HTTP 403` (or `inbox poll failed`),
  and the seed stays pending until a document is actually read — pending *on disk*: a
  first run writes its ledger with `"seed_pending": true` (and `inbox_seed_pending`)
  at launch, before any document is read, so the restart after the re-mint finds that
  file and resumes the wait rather than being judged by the audit log the first launch
  created (the upgrade rule below), and the first documents actually read seed the
  directive document's N ids and the inbox's M, delivering none — N and M being
  everything in those documents by then, including whatever was written during the
  days the URLs were stale (see *First run* above). A missing key reads 404
  to the signers that matter — the control plane holds ListBucket on the bucket
  (`control-plane/deploy.sh`, `SeeMissingAgentObjects`), and so do the operator's own
  credentials. A signer without it sees the seed deferred until the document exists
  (`[s3] first run: directive document not read at launch — seed deferred to the next
  poll`, then the throttled 403 line each window) — the safe direction: nothing is
  stamped history on the strength of a status that may mean "denied".

  *Not a first run.* An existing ledger — even an empty `[]` — or a corrupt or
  unreadable one is *not* a first run: the daemon has run here, and every unapplied
  directive is delivered as before. Neither (1.4.1) is a missing ledger next to an audit
  log that already existed when the daemon started: 1.3.0 wrote the ledger only on its
  first apply, so a box that ran it for weeks with no matching directive has no ledger
  at all, and a 1.4.0 upgrade there would seed the next directive as history; the audit
  log is the evidence it ran, and `[s3] no directive ledger, but the audit log predates
  this launch — not a first run, nothing seeded` says so — once: that launch writes an
  empty, non-pending ledger, so from then on the verdict is read back from the file
  rather than re-derived from the audit log's existence at every start. A ledger that
  exists yet still owes a seed is a first run's own: every first run writes the file
  with `"seed_pending": true` (and `"inbox_seed_pending"`, in the resident posture —
  whether or not an `inboxURL` is configured yet: a launch with no inbox carries that
  flag through every rewrite instead of recomputing it, so the launch that first
  configures the inbox still owes, and draws, the inbox seed; *The inbox and the first
  run* below) the
  moment it starts, before any document is read, and rewrites it as each seed lands —
  so a restart in that window (stale URLs, a dead bucket, an inbox message applied
  while the directive URL was failing, then systemd's `Restart=always`) finds the file,
  audits `[s3] first run: resumed with the directive seed still pending`, and the seed
  lands when the document finally arrives instead of the document replaying. The
  write sits at the top of the launch, ahead of everything that can fail — the private
  key read in particular, so a key the daemon can't read (a path typo, wrong perms,
  cloud-init writing it after the unit started: a crash loop under `Restart=always`)
  still leaves the record for the fixed-key launch — and a launch with **no**
  `supervision` block writes the same record (both seeds owed), so adding freshly
  minted URLs to an install that ran unsupervised is a first run for the supervisor's
  history, not a replay of it. What the audit-log rule is therefore left to judge is
  exactly what it is for, plus the residue it can't tell apart: a 1.3.0 or 1.4.0
  install that never seeded or applied (both wrote the ledger only then); a 1.4.1 first
  run whose launch write failed (audited, below); and a ledger someone removed by hand.
  Every one of those replays rather than drops, which is the safe way to be wrong.

  *If the ledger can't be written* (1.4.1) — a state directory owned by another uid, a
  read-only mount, a full disk — the first run's launch write audits `[s3] first run:
  could not persist the pending ledger — <reason>` (supervised or not), the seed `[s3]
  first run: could not persist the seed — <reason>`, and every later write `[s3] ledger
  write failed — <reason>` (throttled like other failures). The process keeps working from memory, and
  the next launch is judged by the audit-log rule above: with the audit log there (a
  full disk that still let the empty log be created), it is not a first run — every
  unapplied directive is delivered, the 1.3.0 posture; with no audit log either (the
  whole state directory unwritable), it is a first run again — which seeds, and drops,
  whatever was written in between. Under 1.3.0 a lost ledger meant a replay (noisy,
  nothing lost); with the seed it can mean a silent drop unless it is said out loud, so
  it is.

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

  **The inbox and the first run (1.4.1).** On a first run the inbox is seeded like the
  directive document — every message already in it is history (`[s3] first run: N
  message(s) already in the inbox marked applied, not replayed`; an inbox object that
  doesn't exist yet is `[s3] first run: no inbox document yet (HTTP 404) — nothing to
  seed`; the ids go to the ledger's `inbox_seeded`, and a restart before the inbox
  could be read resumes with `[s3] first run: resumed with the inbox seed still
  pending`) — **unless** the config says `"inboxResetAtLaunch": true`: whatever
  launched this daemon emptied the inbox first, as the control plane's `POST /workers`
  does right before the instance launch, so anything in it by the daemon's first read
  arrived while the worker booted and must apply. Set it only when that is literally
  true: configs the control plane provisions carry it (the Lambda sets it); a
  hand-provisioned config launched through `POST /workers` needs it added; a resident
  install, or a worker launched with `launch.sh` (which does not reset the inbox),
  leaves it off. 1.4.0 exempted the inbox unconditionally on the strength of the
  control plane's reset — which only the control plane's launch path performs, while
  the app only ever appends — so a resident install's first run replayed the phone's
  whole backlog, one model turn each, before the first heartbeat.

  *An inbox configured later.* `inboxURL` is its own optional field, so supervision
  first and the inbox later is a normal rollout. A launch with no inbox cannot draw the
  inbox seed, and `inbox_seeded: []` reads the same whether the inbox was seeded empty
  or never seeded at all — so the flag is what is kept: a first run records
  `"inbox_seed_pending": true` even with no inbox configured (the unsupervised record
  does too), and every rewrite of the ledger by an inbox-less life (the directive seed,
  each apply) carries it unchanged. The launch that first configures the inbox audits
  `[s3] first run: resumed with the inbox seed still pending` and seeds the backlog
  rather than delivering it. A ledger that predates the inbox keys (1.4.0 wrote no
  `inbox_seed_pending`) decodes as owing no inbox seed — it cannot say whether a 1.4.0
  inbox was already being read, and seeding one that was would drop whatever arrived
  while the daemon was down — so an inbox first configured on such a box delivers its
  backlog: a replay, never a drop, the same direction the audit-log rule errs in.

  *The launcher's word outranks the ledger.* A ledger owing the inbox seed with no
  launcher to ask (the unsupervised record; a resident first life whose inbox was never
  read) can meet a launch that says `"inboxResetAtLaunch": true` — a box enrolled
  through `POST /workers`, which emptied the inbox moments earlier. Anything in the
  inbox by then arrived after the reset and is live; resuming the seed would stamp it
  history and drop it, with the audit count as the only trace. So the flag on the
  *current* launch wins: the seed is not resumed, `[s3] first run: inbox seed still
  pending, but the launcher emptied the inbox at launch — not resumed` is audited, the
  verdict is written to the ledger at once (so a later launch without the flag does not
  resume a seed this one ruled out), and the message is delivered.

- **Status** — after every poll and every finished turn the daemon PUTs:

  ```json
  {"schema": 1, "device": "fin-agentd", "device_id8": "cloud001",
   "daemon_version": "1.4.1", "agent": "fin-agentd-1", "state": "idle",
   "last_applied_id": "d-1", "last_turn_at": "…", "last_assistant_preview": "…",
   "last_error": null, "updated_at": "…"}
  ```

  (`last_assistant_preview` is capped at 200 characters; `last_error` carries the most
  recent turn failure, including a directive-injected turn that failed after its id was
  consumed. After a first-run seed, `last_applied_id` is the *last id in the directive
  document* as seeded — document order, never sorted, so it is the high-water mark
  exactly when the supervisor appends, which is the document's contract; an inbox seed
  never shows here — until the daemon applies something itself. `daemon_version` tells
  a supervisor which harness features exist; 1.4.0 = the always-on `LC_FIN_AGENT`
  session marker and the first-run directive high-water; 1.4.1 = the absent-document
  and prior-run first-run rules, the inbox seed with `inboxResetAtLaunch`, audited
  ledger writes, and a tolerant ledger decode.)

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
  seed deferred to the next poll` (and its `inbox document` twin) when the launch fetch
  failed; `[s3] first run: resumed with the directive seed still pending` (or `inbox
  seed`) when a restart finds a ledger the previous life wrote before its seed landed;
  `[s3] first run: no supervision directive document yet (HTTP 404) — nothing to seed`
  (or `no inbox document yet`) when the object doesn't exist; `[s3] first run: N
  message(s) already in the inbox marked applied, not replayed` for a seeded inbox
  backlog; `[s3] first run: could not persist the pending ledger — <reason>` when the
  launch write that records the seeds as owed failed, and `[s3] first run: could not
  persist the seed — <reason>` when the seed's own did (later writes: `[s3] ledger
  write failed — <reason>`, throttled); `[s3] first run: inbox seed still pending, but
  the launcher emptied the inbox at launch — not resumed` when a launch that says
  `inboxResetAtLaunch` finds a ledger owing the inbox seed (the verdict is written
  down, and the inbox delivers). And
  once, at startup, `[s3] no directive ledger, but the audit log predates this launch —
  not a first run, nothing seeded` on a 1.3.0 box that never applied a directive — the
  launch that also writes that box its empty ledger. A 403 on either URL is only ever
  `[s3] poll failed: HTTP 403` / `[s3] inbox poll failed: HTTP 403`, first run included.

## Site (one Fin, many bodies)

```json
"site": {
  "id": "a4a1d987-0000-4000-8000-000000000000",   // from POST /sites/enroll
  "kind": "resident",                              // ec2 | resident | byo | app
  "displayName": "Levi's iMac",                    // the only name the app ever shows
  "token": "<siteToken>",                          // the SITE token, not the operator bearer
  "heartbeatSeconds": 20                           // optional
}
```

With the block, `DaemonSiteClient` (an actor, on its own task so a long turn
never goes silent) heartbeats `POST /sites/{id}/heartbeat` with `state`
(`working` while a turn runs, `needs-input` while waiting on the user, else
`idle`/`task-complete`), the ids it holds and has not yet acked, and its
capabilities — daemon version, brain, and `tmux_sessions`: every session on the
DEFAULT tmux socket with each pane's **title** (coding agents set it to their
current task), command, and cwd's last component, rescanned at most once a
minute so the heartbeat never spends an exec channel per beat. The registry's
task vocabulary and activity note ride along when the session is registered.

Messages the heartbeat offers are claimed at receipt and held in
`fin-agentd-site.json` (`held` / `unacked`). The run loop pops the oldest held
message between turns, moves it to `unacked` in one atomic write, submits it,
acks `applied`, and acks `answered` with a redacted preview when the turn ends.
A restart sends `unacked` on its first beat so the control plane finishes those
acks before any other body can be offered the same message. Commands: `restart`
and `stop` exit 0 (launchd respawns); `drain` stops claiming and drops the
primary bid.

Transcript lines gain `site_id8`, `site_name`, and — on a user line the daemon
applied from the queue — `in_reply_to`, which is how the app collapses a message
two bodies both applied.

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
contract, the stayResident gates, classifier guards). `DaemonLaunchOrderTests` drives
the real `Daemon.launch()` — the pre-connect phase `run()` executes — through the
daemon's own seams (`supervisionFetch`, `makeSession`, `terminate`), pinning that the
seed is on disk before any session object exists and that the session `run()` opens
carries the marker. The live integration tests (real sshd + tmux on 127.0.0.1, LM
Studio at `localhost:1234`, and `DaemonSessionMarkerLiveTests` asking a real login
shell whether the marker arrived) skip cleanly when the dev-machine prerequisites are
missing. The marker test also skips where the login shell has no tmux auto-attach to
guard (a green run there would be vacuous), fails *without connecting* where the
auto-attach ignores the marker (connecting would be the hijack), and — where it does
connect — types exactly one line, after the shell has spoken and gone quiet, and
disconnects the instant an answer shows a non-empty `$TMUX`.
