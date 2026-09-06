# fin-wake — keep this Mac reachable while Fin is working

This iMac is Fin's local LLM host. Cloud workers and on-device agents send their
inference turns over the Tailscale Funnel to the bearer shim in front of LM Studio
(`scripts/cloud-agent/lmstudio-auth-shim.py`). If the Mac sleeps, that route dies and
no turn can be served.

`fin-wake` is a per-user **LaunchAgent** (same install pattern as
`dev.levischoen.fin.llm-shim`) that runs a small polling loop as you. While it sees
Fin activity it holds a power assertion that keeps the machine awake; after ~10 min
with no activity it releases the assertion and lets the Mac sleep normally.

**Zero sudo** for everything above. The one optional root step (a scheduled wake) is
printed by `install.sh`, never run, and is genuinely coarse — see the limitations.

## Awake, but the display still sleeps

The assertion is a `caffeinate` child, not a hand-rolled IOKit assertion —
`caffeinate` is a thin CLI over the same `IOPMAssertionCreateWithName` calls, ships in
`/usr/bin`, needs no sudo and no signing. Exact invocation:

```
/usr/bin/caffeinate -i -m -s -w <poller-pid>
```

- `-i` — prevent idle **system** sleep. Keeps the network stack, tailscaled, the shim
  and LM Studio up and reachable. This is the one that matters.
- `-s` — prevent forced system sleep (man page: AC-only; this desktop is always AC).
- `-m` — prevent disk idle sleep (harmless belt-and-suspenders).
- **No `-d`** — the display is *not* kept awake. The screen goes dark on its normal
  timer while the machine stays up behind it. That is the whole point: **reachable
  without lighting the display.**
- **No `-u`** — never declares user activity (which could poke the display awake).
- `-w <poller-pid>` — dead-man switch: `caffeinate` self-exits when the poller's pid
  disappears, so the assertion can never outlive the daemon even on `SIGKILL`. On a
  graceful idle-release the poller also terminates the child itself.

IOKit assertions are reference-counted and additive: this one is independent of
anyone else's, and releasing ours never touches theirs.

## What counts as "Fin is working"

Every ~30s the poller checks three signals; **any** one keeps the Mac awake:

1. **A live cloud worker** — a row with `status = "live"` in the control-plane
   DynamoDB table (`fin-cloud-workers`). A live worker routes its turns here.
2. **A non-empty inbox** — any `fin/inbox/*.json` whose `directives` array is
   non-empty. Queued work that is about to burn an LLM turn.
3. **A fresh status object** — any `fin/status*.json` (the app-wide
   `fin/status.json` or a per-agent `fin/status-<agent>.json`) whose S3
   `LastModified` is within the freshness window (default 5 min). Agents PUT status
   every poll, so an advancing timestamp is a live heartbeat — read from one cheap
   `list` call, no object download, no content parsing.

Once none of the three has been true for the idle timeout (default 10 min), the
assertion is released and the Mac may sleep.

Transient AWS/network errors are caught and logged, never fatal. A failed check
counts as "inactive for that signal" but does not force a release on its own — the
idle timer keeps running, so a persistent outage (the whole channel is down anyway)
eventually lets the Mac sleep. **No secrets are logged**: only booleans, counts and
object keys — never inbox/directive content, never config, never a token.

## Install

```
scripts/mac-wake-for-fin/install.sh
```

It renders the plist's script path to this checkout, copies it to
`~/Library/LaunchAgents/dev.levischoen.fin.wake.plist`, and bootstraps it into your
GUI domain (`launchctl bootstrap gui/$UID …`). Idempotent — re-run it after editing
the script or moving the checkout.

Requirements: the interpreter the plist uses (`/usr/bin/python3`) must have `boto3`
importable (it does on this Mac — user-site for the Command Line Tools python 3.9),
and AWS profile `levi` in `~/.aws/config` (region `us-west-2`).

## Logs

- State transitions (one line per assert/release) → `~/Library/Logs/fin-wake.log`
- launchd stdout/stderr → `/tmp/fin-wake.out` / `/tmp/fin-wake.err`

```
tail -f ~/Library/Logs/fin-wake.log
```

## Configuration

All env-overridable (set in the plist's `EnvironmentVariables` or your shell for a
manual run); defaults are tuned for this iMac:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FIN_WAKE_PROFILE` | `levi` | AWS profile |
| `FIN_WAKE_REGION` | `us-west-2` | AWS region |
| `FIN_WAKE_BUCKET` | `fin-agent-directives-011183829623` | supervision bucket |
| `FIN_WAKE_TABLE` | `fin-cloud-workers` | control-plane table |
| `FIN_WAKE_POLL_SECONDS` | `30` | poll cadence |
| `FIN_WAKE_IDLE_SECONDS` | `600` | release after this much idle (10 min) |
| `FIN_WAKE_STATUS_FRESH_SECONDS` | `300` | status "fresh" window (5 min) |
| `FIN_WAKE_LOG` | `~/Library/Logs/fin-wake.log` | transition logfile |

## Stop / uninstall

```
launchctl bootout gui/$(id -u)/dev.levischoen.fin.wake
rm -f ~/Library/LaunchAgents/dev.levischoen.fin.wake.plist
```

The `bootout` immediately releases the assertion (the poller's `SIGTERM` handler
terminates the `caffeinate` child; `-w` would drop it anyway).

## Optional: close the cold-sleep gap (root, coarse)

`fin-wake` keeps the Mac awake while Fin is active and lets it sleep when idle. But
**once the Mac is asleep, nothing runs** — the poller is frozen, so a request that
lands during sleep is invisible until the Mac next wakes on its own.

A scheduled `pmset` wake bounds that latency, but honestly:

```
sudo pmset repeat wake MTWRFSU 08:00:00      # undo: sudo pmset repeat cancel
```

`pmset repeat` supports **one time-of-day per weekday set** — it is *not* a
cron-style "every N minutes." So this buys at best a **daily** wake window:
worst-case latency for a message that lands just after the wake is ~24h. A tighter
cadence would mean the poller re-arming the next wake each cycle, which needs
standing `NOPASSWD` sudo for `pmset` — a much bigger ask, deliberately not done here.
`install.sh` prints this line but never runs it.

Paths **not** taken, and why:

- **"Wake for network access" (`pmset womp` / `tcpkeepalive`).** Not viable for LLM
  serving. Dark wake is CPU/GPU-throttled (built for Bonjour/Power-Nap chores, not
  multi-second inference — the Mac can drop back to sleep mid-request), and the
  trigger is a WoL magic packet on the LAN. Fin's request arrives over the WAN
  through userspace `tailscaled` — not a magic packet — so it would not reliably wake
  the Mac, and even if it did, dark wake could not reliably serve the turn.

## Honest limitations

- **A truly-sleeping Mac cannot serve an LLM turn or poll S3.** This daemon minimizes
  sleep while Fin is active; it does not, and cannot, make a sleeping Mac reachable.
- **Logged-out / locked matters.** The agent runs in your GUI domain; it survives
  screen lock but a full log-out tears down the per-user domain and stops it.
- This daemon **never** modifies power state (`pmset`) or wakes the display. The one
  power-state change offered is the printed, opt-in `pmset repeat` line above.
