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

Same daemon as the cloud (`daemon/`, 1.4.0), same config shape as the cloud worker,
same S3 supervision channel — only the *where* changes:

| | cloud body (EC2) | resident body (this Mac) |
|---|---|---|
| tmux | `fin` on the instance | `fin` on this Mac; **`main` is Levi's and off-limits** |
| brain | Funnel → shim → LM Studio | `127.0.0.1:1234` directly |
| status | `fin/status-fin.json` | `fin/sites/fin/<site8>/status.json` (outside fin-wake's `fin/status*` glob) |
| inbox / transcript / directives | legacy keys | the same legacy keys — **this site is their sole consumer** |
| SSH identity | Fin's Key from Secrets Manager | a dedicated loopback-only site key |

Phase 0 (`docs/SITES.md` section 11) is a **hand-over, not a coexistence**: the iMac
inherits the legacy inbox and transcript keys and the cloud body is paused. Two 1.4.0
daemons named Fin on the same keys would both apply every message.

## Layout

| file | role |
|---|---|
| `install.sh` | idempotent, zero-sudo installer; `--start` to also load |
| `uninstall.sh` | bootout + remove plists; `--purge` also removes key/config/logs and the site's authorized_keys line |
| `provision-config.sh` | mints SITE8 once, presigns the four S3 URLs, writes `config.json` (0600) and `routing-registry.json`; `--refresh` re-signs in place |
| `refresh.sh` | what the weekly agent runs: `provision-config.sh --refresh` then `launchctl kickstart -k` |
| `dev.levischoen.fin.agentd.plist` | the daemon LaunchAgent (rendered by `install.sh`) |
| `dev.levischoen.fin.agentd.refresh.plist` | the calendar agent that keeps presigned URLs fresh |

Everything the site owns lives under `~/Library/Application Support/fin-agentd/`:

```
bin/fin-agentd              the daemon binary (copied, never built here)
site8                       this site's identity, minted once
site_ed25519 / .pub         the dedicated site key
config.json                 0600 — presigned URLs and the control-plane token live here
provision-state.json        when the URLs were signed / expire; keys; NO urls, NO token
audit.jsonl                 the daemon's local JSONL trail
fin-agentd-directives.json  applied-id ledger (written by the daemon)
routing-registry.json       the tmux sessions Fin may act on (just "fin")
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

`install.sh` without `--start` leaves nothing loaded and prints the exact start
command; `--start` first checks that something answers at the brain endpoint, because
a brainless daemon fail-loops under `KeepAlive` and pushes "giving up" notifications
to the owner's phone. Re-running `install.sh` is safe at any time: the binary is
replaced only if it differs (copy + rename, so a running daemon keeps its old inode),
the key and SITE8 are reused, the `authorized_keys` line is appended at most once,
and the config is rewritten with fresh URLs.

Optional and root, printed but never run: `sudo pmset -a sleep 0` — a resident site
is only as always-on as its Mac.

## Refresh

Presigned URLs are SigV4 with the 7-day ceiling. `dev.levischoen.fin.agentd.refresh`
runs `refresh.sh` on a calendar — **Sunday and Wednesday at 04:00** — which re-signs
the four URLs in place (`provision-config.sh --refresh` keeps every other field of
`config.json` verbatim) and then `launchctl kickstart -k gui/<uid>/dev.levischoen.fin.agentd`
so the daemon, which reads its config once at launch, picks them up. Two slots rather
than one: a single weekly run against 7-day URLs has zero slack — the URLs would
expire at the very minute of the next run, and one missed run (Mac off, AWS hiccup)
is a lapse. With a mid-week slot every URL is renewed with ~3.5 days to spare.

`refresh.sh` is safe when the daemon is not loaded: the config is refreshed on disk and
nothing is started — a deliberately stopped site is never turned back on by the
refresher. Run it by hand any time:

```sh
scripts/mac-fin-agentd/refresh.sh
```

launchd runs a missed `StartCalendarInterval` slot at the next wake; it does not run
slots missed while the Mac was powered off.

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
- **Routing registry.** `routing-registry.json` registers only the daemon's own `fin`
  session. The daemon's routing guardrail treats a session that is live but not
  registered as OFF-LIMITS, so `main` is untouchable by construction — not by
  instruction.
- **`config.json` is 0600** from its first byte (`mkstemp` + atomic rename). It holds
  the four presigned URLs and the control-plane bearer. No script here prints a URL or
  the token; `provision-state.json` carries only key names and timestamps.
- **The operator token is used for `/notify` only** (`controlPlane` block →
  `DaemonNotifyClient` → APNs). The daemon never calls `/workers` or any other route.
  Phase 1 replaces it with a per-site token.
- **Zero sudo.** The only root step (`pmset`) is printed, never run.

## Do not Start Worker for Fin (until Phase 1)

`docs/SITES.md` step 13. Today's control plane `create_worker` still **resets
`fin/inbox/fin.json`** and boots a second 1.4.0 consumer on the same legacy keys. With
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
    "$USER@127.0.0.1" 'echo SITEKEY_OK LC=$LC_FIN_AGENT TMUX=[$TMUX]'
#  → SITEKEY_OK LC=1 TMUX=[]        (plain shell, no auto-attach)
python3 -c 'import json,os; json.load(open(os.path.expanduser("~/Library/Application Support/fin-agentd/config.json")))'
plutil -lint ~/Library/LaunchAgents/dev.levischoen.fin.agentd*.plist
launchctl print gui/$(id -u)/dev.levischoen.fin.agentd   # "Could not find service" until --start
"$HOME/Library/Application Support/fin-agentd/bin/fin-agentd"  # usage line, exit 64
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
```
