# mac-fin-agentd — Fin as a resident site on this Mac

## What a resident site is

The user talks to **Fin**: one name, one conversation, one voice. Where Fin's hands
are at any moment — an EC2 worker the control plane launched, the daemon on Levi's
iMac, the runtime inside the app on a phone — is a **site**: an interchangeable body
for one agent, never a separate agent. One Fin, many bodies. The design, the S3 key
scheme, the migration order and the rollout phases are in
[`docs/SITES.md`](../../docs/SITES.md); this directory is its section 9 made
runnable for the **resident** kind: `fin-agentd` running as a per-user LaunchAgent on
the owner's own Mac, driving a real tmux session on the same box and thinking with
the LM Studio brain on the same box (`http://127.0.0.1:1234/v1`, no Funnel, no shim).

Same daemon as the cloud (`daemon/`, **1.4.1** — `install.sh` refuses anything older,
see "The version floor"), same config shape as the cloud worker, same S3 supervision
channel — only the *where* changes:

| | cloud body (EC2) | resident body (this Mac) |
|---|---|---|
| tmux | `fin` on the instance | `fin` on this Mac; **`main` is Levi's and off-limits** |
| brain | Funnel → shim → LM Studio | `127.0.0.1:1234` directly |
| status | `fin/status-fin.json` | `fin/sites/fin/<site8>/status.json` (outside fin-wake's `fin/status*` glob) |
| inbox / transcript / directives | legacy keys | the same legacy keys — **this site is their sole consumer** |
| SSH identity | Fin's Key from Secrets Manager | a dedicated loopback-only site key |

Phase 0 (`docs/SITES.md` section 11) is a **hand-over, not a coexistence**: the iMac
inherits the legacy inbox and transcript keys and the cloud body is paused. Two daemons
named Fin on the same keys would both apply every message. Phase 0 also has three known
sharp edges that this package cannot fix from here — read "What Phase 0 leaves broken"
before you start it.

## Layout

| file | role |
|---|---|
| `install.sh` | idempotent, zero-sudo installer; `--start` to also load |
| `uninstall.sh` | bootout + remove plists; `--purge` also removes key/config/logs and the site's authorized_keys line |
| `provision-config.sh` | mints SITE8 once, presigns the four S3 URLs, writes `config.json` (0600) and `routing-registry.json`; `--refresh` re-signs in place |
| `refresh.sh` | what the calendar agent runs: `provision-config.sh --refresh`, rotate, `launchctl kickstart -k`; pushes a `/notify` if it fails |
| `launch-agentd.sh` | what the daemon LaunchAgent actually execs: preflight (brain, model id, login-shell guard, URL expiry) then `exec fin-agentd` |
| `rotate-logs.sh` | caps `agentd.{out,err}.log`, `refresh.{out,err}.log` and `audit.jsonl` at 8 MiB × 2 generations |
| `dev.levischoen.fin.agentd.plist` | the daemon LaunchAgent (rendered by `install.sh`) |
| `dev.levischoen.fin.agentd.refresh.plist` | the calendar agent that keeps presigned URLs fresh |

`install.sh` **copies** `refresh.sh`, `provision-config.sh`, `rotate-logs.sh` and
`launch-agentd.sh` into `…/fin-agentd/bin/` and points both LaunchAgents at those copies.
Nothing launchd runs may reference this checkout: `scripts/mac-fin-agentd` exists only on
an unmerged branch, and continuous merge in this same worktree is standing policy
(`CLAUDE.md`) — a plist pointing here would become a silent `ENOENT` the first time
someone ran `git checkout main`.

Everything the site owns lives under `~/Library/Application Support/fin-agentd/`:

```
bin/fin-agentd              the daemon binary (copied, never built here)
bin/*.sh                    the four runtime scripts, copied out of the checkout
site8                       this site's identity, minted once
site_ed25519 / .pub         the dedicated site key
config.json                 0600 — presigned URLs and the control-plane token live here
provision-state.json        when the URLs were signed / expire; keys; NO urls, NO token
audit.jsonl                 the daemon's local JSONL trail
fin-agentd-directives.json  applied-id ledger (written by the daemon)
routing-registry.json       the tmux sessions Fin may act on (just "fin")
transcripts/*.jsonl         local snapshots of fin/transcripts/fin.jsonl, newest 8
```

Logs: `~/Library/Logs/fin-agentd/agentd.{out,err}.log` and `refresh.{out,err}.log`.
Nothing under here is ever committed.

## Install

Build the daemon first — on this machine **only through the guard**, never bare:

```sh
scripts/dev/one-at-a-time.sh swift build -c release --package-path "$PWD/daemon"
scripts/mac-fin-agentd/install.sh          # installs, renders, does NOT load
scripts/mac-fin-agentd/install.sh --start  # …and bootstraps into gui/$UID
```

Requirements: Remote Login on (sshd on `127.0.0.1:22`), `tmux` on `PATH`, a
`/usr/bin/python3` (or Xcode's) with `boto3`, AWS profile `levi` with **long-lived**
operator credentials (temporary creds make the presigned URLs die with the session,
not at day 7 — the script warns), `~/.fin-control-plane-token`, and LM Studio serving
the configured model on `127.0.0.1:1234` before `--start`.

### The version floor

`install.sh` asks the binary `--version` and refuses anything below **1.4.1**. Below that
the first supervised run seeds only the directive document, so every message sitting in
`fin/inbox/fin.json` — up to 200 accumulated app messages, some weeks old — is injected as
one model turn each on the resident first run. 1.4.1 seeds the inbox as history unless the
launcher emptied it first; the resident config deliberately omits `inboxResetAtLaunch`
(the cloud's `create_worker` sets it because it *does* empty the inbox), and that
correctness is inert on an older body. `strings | grep 1.4.1` is **not** a substitute:
`daemonVersion` is a five-byte Swift string and lives as a small-string immediate in the
instruction stream, so it never appears in `strings(1)` output even in a 1.4.1 binary. The
version that was installed is recorded in `provision-state.json` as `daemon_version`.

### Nothing starts itself

Without `--start`, `install.sh` renders both plists **and `launchctl disable`s both
labels**. Rendering alone is not "not loaded": `RunAtLoad` is true and the plists sit in
`~/Library/LaunchAgents`, so the next login or reboot would start the daemon with no
checks at all. The `disable` override is per-user and survives reboots; `--start` re-enables
before it bootstraps.

The second half of that fix is `launch-agentd.sh`, which the daemon LaunchAgent execs
instead of the daemon. It runs at *every* launch, not once at install time, and refuses
(sleeps, exits 0 — no crash loop, no pushes, no inbox consumed) unless:

1. `config.json` parses;
2. the brain answers `-f` **and** serves the configured model id — a listening LM Studio
   with no model loaded is not a brain, and `curl` without `-f` exits 0 on its 404;
3. an `LC_FIN_AGENT`-marked loopback SSH lands in a **plain shell**, `TMUX=[]`;
4. and it warns (does not refuse) when the presigned URLs are inside 48 hours of expiry.

Check 3 is the one worth understanding: the marker only helps if the login shell honours
it, and that lives in `~/.config/fish/config.fish` — a file this package neither owns nor
installs, and one Fin itself can write. Lose that line to a dotfile restore and the
daemon's `FIN_READY_*` probe and every keystroke of every turn land in Levi's live `main`
session. That is the 2026-09-05 incident the marker exists to prevent, so it is asserted
on every start.

### Re-running it

Re-running `install.sh` is safe at any time: the binary is replaced only if it differs
(copy + rename, so a running daemon keeps its old inode), the key and SITE8 are reused,
and the `authorized_keys` line is appended at most once. An existing `config.json` whose
`deviceToken8` matches this site is **refreshed in place** — only the four URLs change, so
a hand-tuned model, task, heartbeat or `notifyCommand` survives; `--reprovision` forces the
full default rewrite. If the daemon is loaded, the summary says so and prints the
`kickstart` line, because a rename swap leaves the *old* process on the *old* config.

A same-key `authorized_keys` line with different options is now **fatal**, not a warning:
without `restrict,pty,from="127.0.0.1,::1"` the site key is not pinned to loopback, and
`sshd` here listens on `*:22`.

Optional and root, printed but never run: `sudo pmset -a sleep 0` — a resident site
is only as always-on as its Mac.

## Refresh

Presigned URLs are SigV4 with the 7-day ceiling. `dev.levischoen.fin.agentd.refresh`
runs the **installed copy** of `refresh.sh` on a calendar — **Sunday and Wednesday at
04:00** — which re-signs the four URLs in place (`provision-config.sh --refresh` keeps
every other field of `config.json` verbatim), rotates the logs, and then
`launchctl kickstart -k gui/<uid>/dev.levischoen.fin.agentd` so the daemon, which reads its
config once at launch, picks them up.

Two slots rather than one because a single weekly run against 7-day URLs has zero slack:
sign Sunday 04:00 and the URLs die the following Sunday 04:00, the very minute of the next
run. With a mid-week slot every URL is renewed with ~3.5 days left on it.

**A missed run has no slack, in either arrangement.** Each run signs for exactly 7 days,
so if Sunday's slot is missed — the Mac was off; launchd does not replay slots missed while
powered off — the next attempt is Wednesday 04:00, which is precisely when the previous
Wednesday's signature expires. The two slots halve the *exposure window*; they do not
survive a miss. That is why a failed refresh pushes through the daemon's own `/notify`
channel, and why `launch-agentd.sh` warns when `expires_at` is inside 48 hours. If the URLs
do lapse, the failure is silent by design: the daemon treats every 403 as a poll failure
and keeps running (`daemon/README.md`, "403 is never absent"), so `launchctl print` shows a
healthy service that receives nothing and publishes nothing.

`refresh.sh` is safe when the daemon is not loaded: the config is refreshed on disk and
nothing is started — a deliberately stopped site is never turned back on by the
refresher. Run it by hand any time (either copy works; the installed one is what launchd
uses):

```sh
"$HOME/Library/Application Support/fin-agentd/bin/refresh.sh"
scripts/mac-fin-agentd/refresh.sh    # same script, from the checkout
```

launchd runs a missed `StartCalendarInterval` slot at the next wake; it does not run
slots missed while the Mac was powered off.

**The restart truncates the app-visible transcript.** `DaemonTranscriptUplink` starts each
run with an empty ring and PUTs the *whole* document without ever GETting the existing
object, so `fin/transcripts/fin.jsonl` ends up holding only what happened after the
restart — twice a week at 04:00, and on every `KeepAlive` respawn. `docs/SITES.md` section
7 names this "the restart-overwrites-history bug" and fixes it structurally in 1.5.0 with
per-run keys. Until then `provision-config.sh` saves a local snapshot of the object under
`…/fin-agentd/transcripts/` (newest 8) immediately before the restart, so the history is
recoverable from the Mac even though the app's timeline is not.

## Uninstall

```sh
scripts/mac-fin-agentd/uninstall.sh          # bootout + remove plists; keeps key/config/site8
scripts/mac-fin-agentd/uninstall.sh --purge  # …and the state dir, logs, and the authorized_keys line
```

Without `--purge` a later `install.sh` brings back the *same* site (same SITE8, same
key). With `--purge` the identity is gone and the next install mints a new one; the
old `fin/sites/fin/<site8>/status.json` in S3 is left for the operator.

## Security model

- **Dedicated, restricted key — not Fin's Key.** Fin's Key (`fins-key` in
  `authorized_keys`) is the identity Fin uses to reach *other* computers; its private
  half never lands on disk. The resident site only ever attaches a tmux session on its
  own box, so `install.sh` generates `site_ed25519` (`-C fin-site-<site8>`) and
  authorizes it as

  ```
  restrict,pty,from="127.0.0.1,::1" ssh-ed25519 … fin-site-<site8>
  ```

  `restrict` turns off agent/port/X11 forwarding and pty; `pty` turns the terminal
  back on (the harness needs it); `from=` pins the key to loopback — it is useless
  from any other host even if the private half leaks. Distinct comments make either
  revocation a one-line `grep -v`.
- **`LC_FIN_AGENT` marker + shell guard.** Every SSH session the daemon opens requests
  `LC_FIN_AGENT=1` (unremovable, `daemon/README.md` "The session marker"); macOS sshd
  forwards `LC_*` by default. `~/.config/fish/config.fish` skips its
  `exec tmux new-session -A -s main` auto-attach when the marker is set, so the daemon
  lands in a plain shell and types its own `connectCommand`
  (`tmux new-session -A -s fin \; set status off`). Levi's `main` session is never
  named in any file here.
- **`LC_FIN_AGENT` is checked at every launch**, not once at install: `launch-agentd.sh`
  refuses to start unless a marked loopback SSH lands in a plain shell (`TMUX=[]`). The
  guard itself lives in a file this package does not own and Fin can write.
- **Routing registry + the tmux send-keys guard — read anything, write only what is
  registered.** `routing-registry.json` registers the daemon's own `fin` session, and the
  router renders that into the system prompt as *"Live but not registered → OFF-LIMITS:
  never send keys to it"* (`SessionRouting.promptSection`). That paragraph is no longer the
  entire guardrail: `TmuxCommandGuard` (`daemon/Sources/FinAgentCore/TmuxCommandGuard.swift`)
  parses every `send_input` string before it reaches the PTY and refuses a **mutating** tmux
  command — `send-keys`, `paste-buffer`, `kill-session`/`-window`/`-pane`, `kill-server`,
  `new-window`, `split-window`, `respawn-*`, `rename-*`, `set-option`, `attach`,
  `switch-client`, `run-shell`, `if-shell`, `source-file`, `bind-key`, a `-L`/`-S` pointed
  at another server — whose target is not the daemon's own session, a registered one, or a
  session in Fin's own `fin-` namespace. It handles `;`/`&&`/`||`/newline chaining,
  `sudo`/`env`/full-path prefixes, tmux's own `\;` form **and its quoted twins `';'`/`";"`**
  (the shell removes quotes before tmux sees argv, so all three separate commands),
  getopt-clustered flags (`-lt main`, `-at fin`, `-As main`), a quoted flag (`"-t" main`),
  spellings the shell assembles (`TMUX`, `t\mux`, `tm"u"x`), abbreviations of names *and*
  aliases (`send`, `kill-ses`, `showe`), `$(…)`/backticks, and one level of `sh -c '…'`
  nesting. Three flags get refused before any target check because they make the target
  lie: `kill-session -a` (kills every session *except* the one named), and `send-keys -c`/
  `-K` (address a client, so the keys land in whatever session the human is attached to).
  `xargs tmux …` is refused whole — its argv comes from stdin — and so is a line ending in
  `\` or an open quote, because the PTY concatenates sends and the shell would join it with
  the next one. **Reading is deliberately unrestricted** — `capture-pane`,
  `list-sessions`, `list-windows`, `has-session`, `display-message -p` work against `main`
  and every other session, because seeing the iMac's real work is the whole point of a
  resident site. Refusals are honest tool results (they name the session and hand back the
  read commands) and land in the audit log as failures. Coverage:
  `daemon/Tests/FinAgentCoreTests/TmuxCommandGuardTests.swift`.

  **The allow-list is read once, at launch.** `routing-registry.json` lives in the same home
  directory as the shell the guard constrains, so a per-send re-read would let the model
  widen its own allow-list with two commands the guard never inspects (append a session with
  `python3 -c …`, then send keys to it). Registering a session is therefore a *user* action
  on this Mac that applies at the next launch — and the refusal text deliberately does not
  name the file. What keeps the router's `start` action working is a namespace instead of a
  file: sessions named `fin-…` are Fin's own, so `tmux new-session -d -s fin-build` then
  `tmux send-keys -t fin-build …` works end to end. Don't name your own sessions `fin-`.

  **This is defense in depth, not a sandbox — say so out loud.** The daemon's shell still
  runs inside `tmux new-session -A -s fin` on the user's **default tmux socket**, the same
  server that hosts Levi's live `main` session, and a byte-level guard over a
  natural-language channel cannot close indirection: `T=tmux; $T send-keys …`, a
  base64/`eval` reconstruction, a helper script or Makefile target that runs tmux, an alias
  or shell function, writing `~/.tmux.conf` and having tmux read it later, `ssh <remote>
  tmux …` (out of scope by policy — a remote box's session names are not in this registry's
  namespace), a command split across two sends whose halves never spell the word, or plain
  non-tmux damage (`pkill -f mlx_lm`, `launchctl bootout`, an `rm` shape
  `DestructiveCommandHeuristic` misses — its patterns still match **nothing** in a tmux
  verb). The guard closes the direct path a model actually takes; treat `main` as protected
  against the obvious, not isolated. The structural fix is a dedicated socket
  (`connectCommand: "tmux -L fin new-session -A -s fin"`), which removes `main` from the
  daemon's namespace entirely and costs exactly the read capability above —
  `tmux capture-pane -t main -p` stops working, and Fin stops being able to see the iMac's
  real work. That is Levi's call, not the code's; `docs/SITES.md` records a forced-command
  variant as the Phase 2 option.
- **`config.json` is 0600** from its first byte (`mkstemp` + atomic rename). It holds
  the four presigned URLs and the control-plane bearer. No script here prints a URL or
  the token; `provision-state.json` carries only key names and timestamps.
- **The operator token is an unscoped control-plane bearer.** The daemon only ever *calls*
  `/notify` (`controlPlane` block → `DaemonNotifyClient` → APNs) — but that is a statement
  about the code path, not about the credential. `lambda.py`'s `_authorize` compares one
  shared `FIN_CP_TOKEN` with no per-route scoping, and the same check gates
  `POST /workers`, `DELETE /workers/<id>`, `POST /presign`, `GET /secrets` and
  `PUT /secrets/<service>` (Secrets Manager writes). That credential now sits in
  `config.json` on a Mac whose resident agent holds an unrestricted shell as the same
  user: the state dir is 0700 against *other* users, not against the agent, which can
  `cat` its own config. Combined with the prompt-level routing guard above, a single
  injected instruction in terminal output turns "push a notification" into terminating the
  cloud worker or overwriting a Secrets Manager entry. **This exposure is real today and
  closes in Phase 1**, which issues a per-site token.
- **Zero sudo.** The only root step (`pmset`) is printed, never run.

## What Phase 0 leaves broken

Three things this package cannot fix from inside itself. All three are Phase 1/1.5.0 work;
they are listed here so nobody discovers them as a surprise.

1. **`main` is off-limits by policy, not by isolation.** See the routing-registry bullet
   above. `TmuxCommandGuard` now refuses mutating tmux commands aimed at unregistered
   sessions before they reach the PTY, so a prompt paragraph is no longer the only thing
   standing there — but the daemon still shares a tmux socket with Levi's live session on
   the box where the fine-tune runs, and a byte-level guard cannot stop indirection
   (`$T send-keys`, `eval`, a helper script, an alias). Isolation is the dedicated-socket
   change, and it trades away Fin's ability to read `main`.
2. **The Mac stops idle-sleeping.** This site's inbox URL is signed `get_object` only, and
   `DaemonDirectiveClient` never writes the inbox back — it dedupes in its own ledger and
   leaves the object alone. The one writer that ever emptied `fin/inbox/fin.json` was the
   control plane's `create_worker`, and nobody may tap *Start Worker* until Phase 1; the
   app only appends, trimming at 200. So after the first message the `directives` array is
   non-empty **forever**, `wake-for-fin.py`'s `any_inbox_nonempty` returns true on every
   30 s poll, and fin-wake holds its `caffeinate` assertion — its 10-minute idle release
   can never fire again. `docs/SITES.md` section 6.5 records the same fact and fixes it in
   Phase 1 by making the legacy inbox pending-only. `provision-config.sh` prints a `note:`
   with the pending count (never the content) whenever it sees a non-empty inbox.
3. **Every restart truncates the app-visible transcript.** See "Refresh". Local snapshots
   under `…/fin-agentd/transcripts/` are the interim mitigation; 1.5.0's per-run keys are
   the fix.

And one credential caveat: the control-plane bearer in `config.json` is unscoped (security
model, last bullet).

## Do not Start Worker for Fin (until Phase 1)

`docs/SITES.md` step 13. Today's control plane `create_worker` still **resets
`fin/inbox/fin.json`** and boots a second consumer on the same legacy keys. With
the resident site live, tapping *Start Worker* for Fin in the app (or `POST /workers`)
would give Fin two bodies applying every message and two writers on
`fin/transcripts/fin.jsonl`. Nobody taps it until Phase 1 lands site enrollment,
per-site keys and the claim/ack lane. The cloud body is *paused* (its worker
terminated, its row `terminated`), not deleted: `POST /workers` re-summons it once
coexistence is real.

## Verifying without starting

```sh
K="$HOME/Library/Application Support/fin-agentd/site_ed25519"
LC_FIN_AGENT=1 ssh -i "$K" -o IdentitiesOnly=yes -o SendEnv=LC_FIN_AGENT -o BatchMode=yes \
    "$USER@127.0.0.1" 'printf "SITEKEY_OK LC=%s TMUX=[%s]\n" "$LC_FIN_AGENT" "$TMUX"'
#  → SITEKEY_OK LC=1 TMUX=[]        (plain shell, no auto-attach)
#  printf, not echo: the login shell here is fish, where an unset variable inside an
#  unquoted word (…TMUX=[$TMUX]) makes the whole word vanish rather than print "[]".
python3 -c 'import json,os; json.load(open(os.path.expanduser("~/Library/Application Support/fin-agentd/config.json")))'
plutil -lint ~/Library/LaunchAgents/dev.levischoen.fin.agentd*.plist
launchctl print gui/$(id -u)/dev.levischoen.fin.agentd   # "Could not find service" until --start
launchctl print-disabled gui/$(id -u) | grep fin.agentd  # => "disabled" until --start
"$HOME/Library/Application Support/fin-agentd/bin/fin-agentd" --version   # => fin-agentd 1.4.1
"$HOME/Library/Application Support/fin-agentd/bin/fin-agentd"             # usage line, exit 64
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/fin-agentd/provision-state.json")))["daemon_version"])'
```

Do **not** run the same `ssh` without `LC_FIN_AGENT` — the login shell would attach
Levi's `main` tmux session.

## Ops

```sh
tail -f ~/Library/Logs/fin-agentd/agentd.err.log
tail -f "$HOME/Library/Application Support/fin-agentd/audit.jsonl"
launchctl print gui/$(id -u)/dev.levischoen.fin.agentd | grep -E 'state|pid'
launchctl kickstart -k gui/$(id -u)/dev.levischoen.fin.agentd   # restart
launchctl bootout gui/$(id -u)/dev.levischoen.fin.agentd        # stop (KeepAlive off with it)
"$HOME/Library/Application Support/fin-agentd/bin/rotate-logs.sh" --force   # rotate now
```

`agentd.out.log` is a second, **unredacted** copy of every directive, inbox message and
model reply: `Daemon.swift`'s `log()` writes them to stdout, and `MemoryRedactor` runs only
on the way *off* the machine (transcript uplink, `/notify`). The log directory is 0700, so
this is retention rather than access — `rotate-logs.sh` caps it, `agentd.err.log` and
`audit.jsonl` at 8 MiB with two generations, and `refresh.sh` runs it before every restart
(rotation is by rename, so it only takes effect when launchd reopens the file on the next
spawn).
