# Fin on any Mac — a resident site with no sshd

*Design document. Repo state: `main @ 3acd90b` (daemon 1.6.6, control plane post-`DELETE /account`). Extends [`docs/SITES.md`](SITES.md) — its principle, vocabulary and claim protocol are unchanged and assumed here. Scope: make the **resident** site kind installable on a managed work laptop that has no `sshd`, then run three Macs at once (iMac, MacBook Neo, work laptop).*

## 1. What the answer turns out to be

Almost everything a site does is already HTTP-out-only, and none of it needs revisiting. Verified against the current tree:

| lane | how it travels today | file |
|---|---|---|
| enrollment | `POST /sites/enroll` with a one-time token, no AWS creds, no bearer | `lambda.py:enroll_with_token`, `install.sh --enroll` |
| heartbeat, lease, commands | `POST /sites/{id}/heartbeat`, site token | `DaemonSiteClient.swift` |
| message claim / ack | `POST /messages/{id}/{claim,ack}` | `DaemonSiteClient.swift` |
| directives, status, transcript object | presigned S3 URLs **delivered on the heartbeat**, re-signed at 20 min to expiry | `_site_refresh_urls`, `DaemonDirectiveClient.updateURLs` |
| transcript chunks | `PUT /transcript-chunk` | `DaemonTranscriptUplink.swift` |
| memory, goals, notify | `POST /memory`, `PUT /agents/{a}/goals`, `POST /notify` | `DaemonMemoryClient`, `DaemonGoalsSync`, `DaemonNotifyClient` |
| self-update | `POST /presign {"kinds":["agentdBinary"]}` → GET + sha256 verify → atomic rename | `DaemonSiteClient.swift:372` |

A site dials out; the control plane never needs inbound access to it. A laptop that sleeps, roams, and sits behind a corporate NAT is already a first-class body by construction.

**The single hard blocker is the transport to the site's own tmux.** `HeadlessTerminalSession` is a Citadel/NIOSSH client: the resident daemon reaches its *own* machine by SSHing to `127.0.0.1:22` with a loopback-pinned key (`restrict,pty,from="127.0.0.1,::1"`), types its `connectCommand` into the PTY, and runs `read_session` over a **second SSH exec channel**. With Remote Login off and un-enableable, that loop cannot close. Everything in §2 follows from that one fact.

Two smaller things follow from running three of them: the brain (§3) and primary election (§5).

## 2. `server.transport: "local"` — a PTY instead of a socket

### 2.1 Config

Additive, defaulted, so every existing config keeps its meaning:

```json
"server": {
  "transport": "local",
  "connectCommand": "exec tmux -L fin new-session -A -s fin \\; set status off"
}
```

`transport` is `"ssh"` when absent. Under `"local"`, `host` / `port` / `username` / `privateKeyPath` / `passphrase` become optional in `DaemonConfig.ServerConfig` (they are non-optional `String` today, `Daemon.swift:55`) and are ignored; `connectCommand` keeps its exact meaning and its exact text, which matters because `TmuxCommandGuard` parses Fin's own socket label out of it (`Daemon.swift:1150`) and rule R1 rests on that.

### 2.2 `LocalTerminalSession`

A new `FinAgentCore` type conforming to `AgentSessionDriving`, sibling to `HeadlessTerminalSession`, mirroring its structure (generation counter, serialized write chain, short-life backoff) with the SSH layer replaced:

- **Spawn.** `openpty(3)`, then `posix_spawn` of the connect command **as an argv, not through a login shell** — `/opt/homebrew/bin/tmux -L fin new-session -A -s fin \; set status off` — with `setsid` + `TIOCSCTTY` so the child owns the terminal, the slave fd as stdin/stdout/stderr, and a fixed 120×40 winsize (`TIOCSWINSZ`). The `LC_FIN_AGENT` marker still goes into the child environment; it costs nothing and the shell tmux spawns inside the pane still reads it.
- **Read.** `DispatchSource.makeReadSource` on the master fd → the same `TerminalEventLog` the engine reads. Byte-accumulating, not per-chunk decoding (the UTF-8 boundary lesson from `collect`).
- **Write.** `write(2)` on the master fd, chained exactly as `send(bytes:)` chains today, resolving to whether the bytes actually left — the engine checks that outcome.
- **`probeEnvironment` / `waitForShellReady`.** Unchanged in behaviour: they type `echo FIN_READY_<n>` into the PTY and read the answer back. Port the bodies verbatim.
- **Respawn.** A child that exits is respawned with the same `consecutiveShortLives` backoff. `new-session -A` re-attaches the same tmux session, so nothing is lost — the same property `exec` gives the SSH path.
- **`runFixedCommand`.** `Process` with **separate stdout/stderr pipes**, the same 64 KB / 400-line caps, the same `FixedCommandTruncation` distinction, the same timeout. This one gets strictly *simpler*: the abandoned-exec-stream counter, the `abandonedExecStreamLimit`, and `recycleConnectionForAbandonedExecStreams` exist only because Citadel cannot close a channel whose command has not exited. A timed-out `Process` is killed and every fd is reclaimed, so none of that machinery is ported.

### 2.3 The seam

`runFixedCommand` is called from three places (`Daemon.swift:363`, `Daemon.swift:2240`, `SessionInventoryScanner.swift:41`, `SessionActivitySummarizer.swift:65`) on a concrete `HeadlessTerminalSession?`. Add it to a small protocol — `AgentFixedCommandRunning`, or `AgentSessionDriving` itself with a default that throws `notSupported` — and widen `Daemon.session` and the `makeSession` test seam (`Daemon.swift:283`) to the protocol. That is the only invasive edit outside the new file; the turn engine already never learns which session it is driving.

### 2.4 What this does to the security model

**Kept, unchanged:** the private tmux socket (`-L fin`) as a *topological* boundary — Fin's server is a different process with a different socket file from the one hosting Levi's `main`; `TmuxCommandGuard` R1–R7; `read_session`'s fixed argv against the default socket; `MemoryRedactor` on everything leaving the machine.

**Deleted, and good riddance:** the site key, the `authorized_keys` line, the `from="127.0.0.1,::1"` pin, the sshd requirement, `AcceptEnv`, and — this is the big one — **the login-shell auto-attach hazard**. The 2026-09-05 incident (`~/.config/fish/config.fish` losing its `LC_FIN_AGENT` guard, every keystroke landing in Levi's live `main`) is structurally impossible when the daemon `posix_spawn`s tmux by argv: there is no login shell in the path to auto-attach anything. `launch-agentd.sh`'s check 3 — the interactive-SSH probe, the one that took two rounds to stop being vacuous — is replaced under `transport: local` by the assertion the daemon already makes at launch: after the connect command, `$TMUX` must name Fin's own socket (`Daemon.swift:1169`).

**Made harder, stated honestly:** SITES.md §9 names a **dedicated UNIX user** as the airtight hardening — a different uid cannot open a `0700` `/tmp/tmux-<uid>` at all. Over SSH that is one `sudo` step and an `authorized_keys` line for the other user. With a local PTY the agent runs as whoever the *daemon* runs as, so the airtight version would mean running `fin-agentd` itself as that user (a second LaunchAgent in a second user's `gui/` domain, or a LaunchDaemon). That is a real regression in the *reachability* of the hardening, not in today's posture, and the residual list is otherwise identical (`TMUX_TMPDIR`, a symlink dropped over Fin's own socket path, non-tmux damage). On a work laptop it deserves a second look, because the blast radius there is an employer's machine.

## 3. The brain: the iMac's LM Studio over Tailscale Funnel

Chosen: `agent.endpointURL = https://levis-imac.tail2e2bdf.ts.net:8443/llm/v1`, `agent.apiKey = <shim bearer>` — the same path EC2 workers already use through `lmstudio-auth-shim.py`. **Zero daemon code.** The shim is bearer-gated, streams SSE unbuffered, and `AgentEndpointClient` sends `Authorization: Bearer` and accepts a base URL ending in `/v1` (`AgentEndpoint.swift:149,185`).

Three things must be verified on the actual work network before this is real, and each has a named fallback:

1. **Port 8443.** Funnel offers 443, 8443 and 10000; a corporate egress policy that allows only 443 kills 8443 silently. → Move the Funnel mount to 443.
2. **Tailscale itself.** MDM may forbid the client, or DNS/DERP may be blocked. → Local LM Studio on the laptop (the iMac's exact config, `127.0.0.1:1234`).
3. **TLS interception.** A MITM proxy breaks Funnel's Let's Encrypt chain. URLSession uses the system trust store, so a properly MDM-installed root CA works and this is a non-issue — but it is a non-issue *only if* the CA is in the System keychain, which is worth confirming rather than assuming. → Hosted OpenAI-compatible endpoint with a Bearer key, last resort, with the data caveat that work terminal text then reaches a third party.

A control-plane `/llm` proxy route (site-token authenticated, forwarding to the shim) remains the clean "one HTTPS origin for everything" answer and stays **unbuilt** until one of the above actually fails.

**New coupling worth surfacing in the UI:** the laptop's brain is the iMac. If the iMac sleeps or LM Studio closes, the laptop site is alive and brainless. `launch-agentd.sh` check 2 already refuses to start without a brain that serves the configured model id; add `capabilities.brain.reachable` to the heartbeat so "Fin's computers" can say *thinking on the iMac — unreachable* instead of showing a green site that fails every turn.

## 4. Installing it: curl, an enroll token, and tmux

`install.sh --enroll <token> --endpoint <url>` already needs **no AWS credentials and no operator bearer**. What it still needs and shouldn't: a repo checkout, `ssh-keygen`, an `authorized_keys` append, and a loopback SSH probe. Add `--transport local`:

- skips key generation, the `authorized_keys` line, and the SSH probe entirely;
- `enroll-config.py` writes `server: {"transport":"local","connectCommand":"exec tmux -L fin …"}` instead of the `127.0.0.1` block;
- `launch-agentd.sh` runs checks 1, 2 and 4, and skips 3 (see §2.4);
- **the binary comes over HTTP.** After enroll the installer holds a site token, so it can `POST /presign {"kinds":["agentdBinary"]}` and fetch `fin/agentd/fin-agentd-macos-arm64` + its `.sha256` sidecar — the identical path `DaemonSiteClient`'s `update` command already walks. That makes the installer self-contained: `curl … | bash -s -- --enroll <token>`, no checkout on the work machine.

Two managed-Mac gates to clear:

- **Signing.** `publish-binary.sh` publishes a bare local `swift build -c release` product. On a managed Mac, Gatekeeper and any MDM binary allow-list will object. Add `codesign --options runtime` + notarization + staple to `publish-binary.sh`, and verify `spctl -a -vv` on the laptop. Treat this as blocking until proven otherwise.
- **`tmux`.** Homebrew is available (confirmed). `launch-agentd.sh` should check `tmux` on `PATH` before starting rather than discovering it as a shell that exits instantly.

No `pmset -a sleep 0` on a laptop — it is *supposed* to sleep. The consequence is correct by design: the lease lapses, the sweep marks it `stale` after three leases and never terminates it, the iMac keeps primary, and messages pinned to the laptop sit `queued` until it wakes.

## 5. Three Macs at once

### 5.1 Phase 1: fixed order — iMac, Neo, work laptop

`_elect_primary`'s condition is `primaryPriority < :p`, **strictly**. Equal-priority residents therefore never preempt each other: whichever heartbeats first holds primary until its lease lapses. Three sites all at the `resident` default of 100 would make "which Mac answers an unaddressed message" an accident of boot order. Distinct numbers are what make *iMac always wins* a fact rather than a habit:

| site | priority |
|---|---|
| iMac | 100 |
| MacBook Neo | 90 |
| work laptop | 80 |
| cloud (EC2) | 10 |
| app installs | 1 |

**No Lambda change is needed.** `enroll_with_token` does `filled = dict(body)` and `enroll_site` reads `body.get("priority")` (0–1000), so the installer only needs a `--priority` flag to pass through.

**One sharp edge:** on re-enroll, a body that omits `priority` is reset to `SITE_DEFAULT_PRIORITY[kind]` — 100. Re-running the installer on the laptop would silently promote it above Neo and tie the iMac. Fix: the installer persists the chosen priority in `provision-state.json` and **always** resends it, defaulting from that file rather than from the kind.

Display names must be distinct and human ("Work laptop", "MacBook Neo") — rule 1 of SITES.md still holds: ids never reach the conversation.

Routing gets *better* with three Macs almost for free: `_pin_for` matches the message text and `activeSessionNames` whole-word against every live site's `capabilities.tmux_sessions[].session|tasks`, so distinct session names on the work laptop send "what's the deploy doing" to the right body, and ambiguity already falls into the `clarify` lane rather than guessing.

### 5.2 Phase 2 (built dark, flipped after Phase 1 is verified): follow where I am

The missing primitive is **co-location**: the control plane cannot currently tell that the app site on the work laptop and the resident site on the work laptop are the same physical machine. Both are separate rows with unrelated ids.

Proposal: both the macOS app and `fin-agentd` report `capabilities.hostId` — a stable per-machine value (HMAC of the hardware UUID under a per-account salt, so it is opaque server-side and stable across reinstalls). Co-location then becomes an equality test, not a heuristic.

With that, the app site adds `capabilities.presence: {frontmost: bool, lastInputSecondsAgo: int}` to its heartbeat (`AppSiteClient` heartbeats every 20 s while active), and `_pin_for` gains one rule, inserted **after** `siteHint` and **before** the session-name match: if exactly one live app site reported input within N seconds (60 is the obvious starting number) and a live resident site shares its `hostId`, pin there. Everything else is unchanged, so an unaddressed message with no recent presence still goes to the primary — the Phase 1 behaviour, intact underneath.

Ship it behind a per-account `routing: "presence"` flag, default off. Verify against real `routedBy` values in `GET /messages` for a week before flipping. This is SITES.md §12 open question 3, answered.

## 6. Data boundary — parity, said out loud once

Chosen: the work laptop behaves exactly like the iMac. Redacted transcripts land in Levi's S3, the shared memory store takes entries from it, and the goals ledger mixes work and personal items. `sessionActivity` (which reads live pane content into an LLM call) is off by default in every shipped config and stays a deliberate opt-in. If the employer's policy turns out to forbid this, the lever is a per-site containment posture — `sessionActivity` off, transcript uplink local-only, memory writes suppressed, goals read-only — which is config surface plus gating in `DaemonTranscriptUplink` / `DaemonMemoryClient`, not new architecture. Not built now.

## 7. Phasing

- **A — local transport.** `LocalTerminalSession`, the protocol seam, `transport` in config, installer `--transport local`, `launch-agentd.sh` branch, unit tests. Prove it **on the iMac first** by flipping that machine's config to `transport: "local"` — it is the box with a working sshd, so the two transports can be A/B'd against the same tmux server, the same guard, the same `read_session` calls, with the SSH config one `launchctl kickstart` away.
- **B — the laptop.** Notarized binary, curl installer, enroll at priority 80, Funnel brain, one voice round-trip from the phone, one `read_session` against a real work pane, one `/notify`.
- **C — three-way.** iMac 100 / Neo 90 / laptop 80, distinct display names, `brain.reachable` in the heartbeat and in "Fin's computers".
- **D — presence routing, dark.** `hostId`, `presence`, the `_pin_for` rule, flag off. Flip after a week of observed `routedBy`.

Neo needs no new code once A–C land: it is a resident site with sshd available, so it can use either transport.

## 8. Must-verify on the actual work laptop

These change nothing about the design but can each cost a week if discovered late:

1. Is Tailscale installable/allowed, and is Funnel's port reachable outbound (8443, else 443)?
2. Is there a TLS-intercepting proxy, and is its root CA in the **System** keychain?
3. Will Gatekeeper / the MDM binary policy run a notarized-but-non-App-Store `fin-agentd`?
4. Are per-user LaunchAgents permitted (`launchctl bootstrap gui/$UID`)?
5. Does an EDR agent object to a process that `openpty`s and spawns tmux repeatedly?
6. Is `~/Library/Application Support/fin-agentd/` excluded from anything that would scan or sync it — the config there holds the site token.

## 9. What this design does not touch

The claim protocol, exactly-once application, threads, the goals ledger, notify dedupe, the transcript schema, the app's site directory, the tvOS/visionOS surfaces, and `TmuxCommandGuard`'s rules. One new transport, one new brain URL, three numbers, and a flag.
