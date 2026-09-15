# Fin on this Mac — setup

This folder is everything needed to make this Mac one of **Fin's computers** (a
*resident site*). No git checkout, no AWS credentials, no `sudo`. Fin will run as a
per-user LaunchAgent, drive its **own** tmux server on this machine, and talk to your
account over HTTPS only.

What it needs from this machine:

- **Remote Login on** (System Settings → General → Sharing → Remote Login). The daemon
  reaches its own tmux over a loopback SSH session with a dedicated key it generates here
  and pins to `127.0.0.1` — nothing from outside this Mac can use that key.
- **tmux on `PATH`** — `brew install tmux`.
- **Outbound HTTPS.** Everything else (enrollment, heartbeat, your messages, transcripts,
  notifications, even the daemon's own updates) dials out. Nothing ever connects *in*.

## 1. Unpack

```sh
cd ~/Downloads
tar -xpzf fin-agentd-site-*.tar.gz     # -p matters: it keeps site.env owner-only
cd fin-agentd-site
xattr -dr com.apple.quarantine .       # it arrived via iCloud; macOS flags that
chmod 600 site.env                     # belt and braces — install.sh refuses a loose one
```

Check the binary runs:

```sh
./fin-agentd --version                 # => fin-agentd 1.6.6
```

## 2. Get a one-time enroll token

In the Fin app: **Agent → Fin → Key → "Let Fin Live on This Computer…"**. It prints a
command containing a token. **The token is good for 15 minutes and is consumed on first
use** — mint it when you are ready to run step 3, not before.

(Or ask Fin on the iMac to mint you one.)

## 3. Install

```sh
./install.sh --enroll <token> --start
```

`site.env` supplies the rest — this site's display name, its dispatch priority, and which
brain it thinks with. The installer copies the binary and scripts into
`~/Library/Application Support/fin-agentd/`, generates the loopback key, appends one
restricted line to `~/.ssh/authorized_keys`, writes a `0600` `config.json`, and loads two
LaunchAgents.

Without `--start` it installs everything and leaves both LaunchAgents **disabled**, and
prints the exact command to start them later. That is the cautious order on a machine you
want to look over first.

## 4. Confirm

```sh
launchctl print gui/$(id -u)/dev.levischoen.fin.agentd | grep -E 'state|pid'
tail -f ~/Library/Logs/fin-agentd/agentd.err.log
```

Within about twenty seconds this Mac appears in **Fin's Computers** in the app. Send Fin a
message naming it and it should answer from here.

If the daemon refuses to start, the reason is one line in `agentd.err.log` and it is always
one of four things: the config did not parse, the brain did not answer, the loopback SSH
probe failed (Remote Login off, or the key not authorized), or `tmux` is not on `PATH`.
It sleeps and retries rather than crash-looping, so nothing is lost while you fix it.

## What it will and will not touch

- Fin's shell lives on its **own tmux server** (`tmux -L fin`), a different socket and a
  different process from any tmux you are using. Nothing Fin types can reach your sessions
  — not because a filter forbids it, but because the server it would have to talk to is
  not the one it is attached to.
- It can *read* a named session on the default socket through one fixed, capped, redacted
  command (`read_session`), and only when you ask it to.
- Reading your live panes continuously (`sessionActivity`) is **off** and stays off unless
  you add that block to `config.json` yourself.
- Everything Fin says and sees that leaves this Mac goes through the redactor first.

## Turning it off

```sh
launchctl bootout gui/$(id -u)/dev.levischoen.fin.agentd    # stop, keep everything
./uninstall.sh                                              # unload + remove the plists
./uninstall.sh --purge                                      # …and the key, config, logs,
                                                            #    and the authorized_keys line
```

Retiring the site from the app (**Fin's Computers → Retire**) destroys its token
server-side, which is the real revocation: after that this Mac cannot heartbeat, claim a
message, or read anything, whatever is left on disk.
