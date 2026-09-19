# Talking to Fin — voice examples

Fin's voice surface is Siri. Two App Shortcuts (`fin/Intents/SendToFinIntent.swift`):

- **"Ask Fin" / "Ask Fin a question"** — Siri asks *"What should I tell Fin?"*, you
  dictate, and Siri reads Fin's reply back.
- **"Talk to Fin" / "Have Fin…" / "Get Fin to…" / "Hey Fin"** — same dictation, but
  fire-and-forget: *"Sent to Fin. It'll reply in the app."* The reply arrives as a
  notification on whichever device you're holding, and the whole exchange lands in the
  agent's Conversation.

Every request below is written the way it is actually said out loud — imperative,
naming the machine when it matters. They are **synthetic**: no real hostnames, paths, or
people. They are the seed content for the App Store screenshots
(`fin/Support/ScreenshotFixtures.swift`) and the reference register for copy.

## What Fin is for, in the user's words

| Said to Siri | What Fin does |
|---|---|
| "Have Fin check whether the overnight build on the build box finished, and tell me if anything failed." | Reads the build session's terminal, finds the summary line, reports the count and the one failing test, offers to rerun it. |
| "Get Fin to tail the deploy log and let me know when it's done." | Proposes `tail -f` on the deploy log (waits for approval in manual mode), watches it, and notifies when the final line lands. |
| "Ask Fin what's running on my studio Mac right now." | Lists the tmux sessions and what each pane is doing — from the last heartbeat, no connection needed. |
| "Have Fin restart the dev server in the fin session and confirm it's serving." | Types the restart, waits for the "listening on" line, replies with the port. |
| "Hey Fin, summarize what the cloud worker did overnight." | Distills its transcript into three lines and what it's waiting on. |
| "Get Fin to run the test suite and only tell me if something's red." | Runs it, stays quiet on green, pushes a notification with the failing names on red. |
| "Ask Fin if the disk on the build box is getting full." | Runs `df -h`, answers in one sentence with the number. |
| "Have Fin remember that releases go out on Thursdays after the eval run." | Writes a memory; it shows up in the profile it injects into every conversation. |
| "Talk to Fin — when the archive finishes, tell me the build number." | Monitors the archive session, reports the build number when the upload succeeds. |
| "Get Fin to open the deploy runbook and follow it, step by step, asking me before each destructive step." | Reads the markdown runbook, executes step by step, requests input before anything that deletes or pushes. |

## What a reply sounds like

> **You:** Have Fin check whether the overnight build on the build box finished, and tell me if anything failed.
>
> **Fin:** The overnight run finished at 03:12 — 412 tests, 1 failure: `PaywallDisclosureTests.testRenewalTermsVerbatim`. Everything else is green. Want me to rerun just that one and paste the diff?

> **You:** Get Fin to tail the deploy log and let me know when it's done.
>
> **Fin:** Tailing `deploy.log` on the build box now. I'll notify you the moment it prints the final "deploy complete" line — currently at step 4 of 6, syncing assets.

## Feature set, as the screenshots tell it

1. **Servers** — the machines Fin can reach, and Fin's own computers (the bodies it runs
   in) with what each is doing right now.
2. **A live terminal** — the real session, on the real machine, with the agent's console
   beside it: every command it wants to type waits for approval in manual mode.
3. **The agent** — provider (Apple on-device or your own model server), model, limits,
   mode, and what it can see.
4. **Memory** — the distilled profile Fin carries into every conversation, and what its
   computers are seeing right now.
5. **Logs & traces** — every run, every tool call, the tokens and latency it cost, and
   the human's approve/deny on each gated action.
6. **Fin Pro** — one paywall, terms disclosed before purchase, 14-day trial first.
