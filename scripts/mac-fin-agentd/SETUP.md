# Fin on this Mac — setup

This folder is everything needed to make this Mac one of **Fin's computers** (a
*resident site*). No git checkout, no AWS credentials, no `sudo`, and — with the local
transport — **no Remote Login**. Fin runs as a per-user LaunchAgent, drives its **own**
tmux server on this machine, and talks to your account over HTTPS only.

What it needs from this machine:

- **`tmux` on `PATH`** — `brew install tmux`. Under the local transport tmux *is* the
  session, so this is not optional.
- **Outbound HTTPS.** Everything dials out: enrollment, heartbeat, your messages,
  transcripts, notifications, even the daemon's own updates. Nothing ever connects *in*,
  and nothing needs a listening port on this Mac.

`site.env` in this folder already carries this site's settings — its name, its dispatch
priority, which brain it thinks with, and which transport to use. You do not have to edit
it.

## 1. Unpack

```sh
cd ~/Downloads
tar -xpzf fin-agentd-site-*.tar.gz     # -p matters: it keeps site.env owner-only
cd fin-agentd-site
xattr -dr com.apple.quarantine .       # it arrived via iCloud; macOS flags that
chmod 600 site.env                     # belt and braces — install.sh refuses a loose one
./fin-agentd --version                 # => fin-agentd 1.6.6
```

## 2. Get a one-time enroll token

In the Fin app: **Agent → Fin → Key → "Let Fin Live on This Computer…"**. It prints a
command containing a token. **The token is good for 15 minutes and is consumed on first
use** — get it when you are ready to run step 3, not before.

(Or ask Fin on the iMac to mint one.)

## 3. Install

```sh
./install.sh --enroll <token> --start
```

That copies the binary and the runtime scripts into
`~/Library/Application Support/fin-agentd/`, writes a `0600` `config.json`, and loads two
LaunchAgents. Without `--start` it does everything except load them, leaves both labels
`launchctl`-disabled so nothing can start at the next login, and prints the exact command
to start them once you have looked it over.

## 4. Confirm

```sh
launchctl print gui/$(id -u)/dev.levischoen.fin.agentd | grep -E 'state|pid'
tail -f ~/Library/Logs/fin-agentd/agentd.err.log
```

The heartbeat interval is a function of where the brain is: a loopback LM Studio answers in
seconds, so 60 s has slack; the same model over a Funnel takes over a minute per turn, and a
turn longer than the interval leaves the daemon permanently mid-turn. An enrolled config
picks 60 s or 300 s accordingly (`agent.heartbeatSeconds`).

A healthy first start says, in this order: `local pty → <model>`, `connected; probing
until the shell answers`, `tmux confinement confirmed: the shell is inside -L fin`, and
`tmux guard armed`. Within about twenty seconds this Mac appears in **Fin's Computers** in
the app.

If it refuses to start, the reason is one line in `agentd.err.log` and it is one of three
things: the config did not parse, the brain did not answer, or `tmux` is not on `PATH`
(remember that launchd's `PATH` is the plist's, not your shell's). A refusal sleeps and
retries — it never crash-loops, and it never consumes a message it cannot answer.

## The two transports

`site.env` sets `FIN_TRANSPORT`. The default is `ssh`; this bundle may be configured for
`local`.

| | `ssh` | `local` |
|---|---|---|
| how it reaches tmux | loopback SSH to `127.0.0.1:22` | a PTY the daemon opens itself |
| needs Remote Login on | **yes** | no |
| site key + `authorized_keys` line | yes, pinned to loopback | none |
| login shell in the path | yes — hence the `LC_FIN_AGENT` guard | **no** |

The local transport exists for Macs where Remote Login cannot be turned on, and it is the
safer of the two for a reason worth knowing: over SSH the daemon is handed an
**interactive login shell**, and a login shell that auto-attaches your tmux does so before
the daemon can type anything. That is what the `LC_FIN_AGENT` marker defends against. The
local transport execs its connect command directly, non-interactively — there is no login
shell to exclude.

## What it will and will not touch

- Fin's shell lives on its **own tmux server** (`tmux -L fin`), a different socket and a
  different process from any tmux you are using. Nothing Fin types can reach your sessions
  — not because a filter forbids it, but because the server it would have to talk to is
  not the one it is attached to. The daemon asserts this at every launch and refuses to
  proceed quietly if it is not true.
- It can *read* a named session on the default socket through one fixed, capped, redacted
  command (`read_session`), and only when you ask it to.
- Reading your live panes continuously (`sessionActivity`) is **ON**: the installer writes
  that block, and the daemon periodically captures each coding-agent pane and summarizes it
  through the model. Remove the `sessionActivity` block from `config.json` and restart to
  turn it off — an empty `{}` does NOT turn it off, it turns it on with defaults.
- Everything that leaves this Mac goes through the redactor first.
- Fin's shell runs as **your** user. The boundary above is topological, not a kernel one;
  `daemon/README.md` has the full residual list.

## Turning it off

```sh
launchctl bootout gui/$(id -u)/dev.levischoen.fin.agentd    # stop, keep everything
./uninstall.sh                                              # unload + remove the plists
./uninstall.sh --purge                                      # …and the config, logs, state
```

Retiring the site from the app (**Fin's Computers → Retire**) destroys its token
server-side, which is the real revocation: after that this Mac cannot heartbeat, claim a
message, or read anything, whatever is left on disk.
