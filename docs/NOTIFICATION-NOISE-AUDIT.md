# Notification noise audit

Window: 2026-09-14T00:00Z → 2026-09-20T21:41Z (the last week).
Source: the iMac daemon's audit trail, `~/Library/Application Support/fin-agentd/audit.jsonl`
(9,987 lines, 2026-09-16T11:00:11Z → 2026-09-20T21:41:06Z) plus the rotated
`audit.jsonl.1` (13,946 lines, 2026-09-07T19:59:34Z → 2026-09-16T11:00:06Z).
Written 2026-09-21.

---

## 1. Verdict

**The hypothesis holds. 53 of 59 pushes (89.8%) were the daemon reporting on its own
health, and the remaining 6 were one question re-asked six times — a question Levi had
already answered. By subject, 0 of 59 pushes in the last week told him something new that
he could act on.**

The denominator is 59 pushes, reconstructed for the iMac daemon only, 2026-09-14 →
2026-09-20:

| class | count | how counted |
|---|---:|---|
| `agent-stalled` (5 consecutive turn failures) | 27 | replayed gate, marker-validated (below) |
| `agent-recovered` ("Fin is answering again") | 26 | MEASURED — `[stall] recovered` audit notices |
| `request-input` | 6 | MEASURED — 6 `request_input` toolCalls |
| `task-complete` | 0 | MEASURED — zero `[monitor] task complete` notices since 2026-09-12T23:26:28Z |
| model-authored `notify` tool | 0 | MEASURED — zero `notify` toolCalls in the window |
| goal follow-up page | 0 | MEASURED — zero `[goals] follow-up recorded` lines |
| brain-outage page (401/402/403) | 0 | MEASURED — `[brain]` appears 0 times in 23,933 events |

So >90% is right to within rounding for the health-chatter classes alone, and the honest
number is worse than Levi's: **in the last week Fin sent him nothing at all about work it
had done.** Every push was either "I am broken", "I am no longer broken", or a repeat of
a question from the week before.

Two caveats that cut in opposite directions, both stated plainly:

- **The count is a floor.** This is the iMac daemon only. The work laptop's daemon log is
  unreachable (its daemon is stopped, and that Mac has no sshd by design). Any pushes it
  sent are not in these numbers.
- **The count is of daemon-side sends, not phone banners.** `lambda.py:2046`
  `_push_to_user` fans one logical notification out to every registered alert token, so
  59 sends became some multiple of 59 banners. There are no APNs delivery receipts, so
  nothing here distinguishes sent from delivered from seen.

**Method note.** `notify(event:)` (`daemon/Sources/fin-agentd/Daemon.swift:2712`) writes no
audit record, so pushes are not directly logged anywhere. The 27 stall pages are a replay
of `StallNotifyGate`'s pure logic over the observed event sequence. The replay's terminal
state matches the live on-disk marker byte-for-byte —
`fin-agentd-stall-notify.json` = `{"pageCount":1,"active":false,"lastNotifiedAt":"2026-09-20T21:07:26Z","failureKey":"couldn't reach the endpoint: the request timed out."}`
— so I treat the 27 as measured rather than estimated. Every other row above is a direct
count of an audited side-effect.

---

## 2. The classes

| class | occurrences | verdict | could the harness have handled it? |
|---|---:|---|---|
| `agent-stalled` — 5 consecutive turn failures | 27 | **noise**: median 4.3 min from page to self-recovery (n=26, min 3.0, max 15.8; 24/26 under 10 min). The daemon restarted itself before a human could read the banner. It is also time-sensitive (`lambda.py:1996`, `:2023`), so all 27 broke through Focus. | Yes — waiting would have resolved 26 of 27. But see §3: the underlying fault is real and unfixed, so the correct handling is to *fix* it, not to mute it. |
| `agent-recovered` — "fin-agentd is answering again" | 26 | **noise by construction**: a string literal (`Daemon.swift:1253`), byte-identical every time, reporting that nothing needs doing. Its only information content is that the page four minutes earlier should not have been sent. | Yes, entirely. |
| `request-input` | 6 | **actionable class, noise firings**: all six are the same Blackstreet prioritisation question (first asked 2026-09-13T10:42:25Z, outside the window), re-asked across 8 days with a different threadId each time. Levi answered it — `2026-09-16T02:31:36Z userMessage "neither, drop it"` — and Fin dropped the answer (`02:35:07Z "I don't see a message from you in our current turn"`), then re-asked at 02:56:43Z and again at 12:14:41Z, 9h43m after being told to drop it. | Yes for the 5 re-asks. No for the class: only Levi can answer a blocked question. Do not suppress the class. |
| `task-complete` | 0 | **did not fire.** Not part of this week's problem. Historic risk is real: of 21 firings 2026-09-07 → 2026-09-12, at least 11 were not achievements — 4 idle decisions pushed as completions (`2026-09-12T23:26:28Z "The goals ledger is empty (all 20 goals are closed)"`) and 7 status narration (`2026-09-09T02:45:59Z "I am ready."`). `taskCompleteIsTrustworthy` (`Daemon.swift:2360`) is satisfied vacuously by an empty ledger. | n/a this week |
| model `notify` tool | 0 | **did not fire.** The structural irony: this is the only channel with a dedupe (`NotifyDedupe`, `Daemon.swift:3211`) and it is the channel that went unused, while the four that fired have none. Historic risk: 10 "Audit Complete" restatements in under 4 hours on 2026-09-13, which the 2h / 0.6-Jaccard window walked straight past by rewording. | n/a this week |
| brain-outage page | 0 | **did not fire, and it is the one class that would have been worth waking up for.** `BrainOutage.forStatus` (`BrainOutage.swift:29-36`) is deliberately narrow — 401/403 credentials, 402 payment: conditions no retry can fix. It shares the event name `agent-stalled` with the 27 noisy pages, so any per-event suppression silently degrades it too. | No — by construction. |
| goal follow-up page | 0 | **did not fire.** `GoalsLedger.swift:283` still instructs "call notify NOW with that outcome", and nothing expires a follow-up goal, so a goal whose pane never shows a clean finish is re-read by every one of the ~15 mission ticks per hour. Unrealised. | n/a this week |
| app-side banners (`AgentNotificationService`, `AgentWatchdog`, CloudKit signals) | **not measurable** | The app writes no JSONL audit; `~/Library/Containers/dev.levischoen.fin/.../Application Support/` holds only SwiftData stores. 0 here means "not instrumented", never "did not fire". | unknown |

---

## 3. The mechanism behind the biggest noise source

53 of the 59 pushes are one loop. It runs like this:

1. The prompt grows monotonically, about +580 tokens per heartbeat tick, from ~7.4k after
   a restart. `[context] prompt 21611/32768 (65%)` at 2026-09-20T12:00:39Z →
   `22203/32768 (67%)` at 12:02:59Z → `22795/32768 (69%)` at 12:05:22Z.
2. Around 22.9k the endpoint starts returning
   `Engine protocol predict request returned 500: {"error":{"code":500,"message":"Context size has been exceeded."}}`.
   **174 such errors on 09-19 and 09-20 alone** (92 + 82). The last prompt line logged
   before each is ~22.8k, not 32k.
3. Five consecutive failures → `Daemon.swift:2077`. The gate passes, the page goes out
   (`:2090`), and then `fail()` is called **unconditionally** at `:2101` — suppressing
   the page never suppresses the exit. `launchd` restarts the daemon.
4. The restart resets the transcript. `[context] prompt 7395/32768 (22%)` at 12:56:45Z,
   the turn succeeds, `noteStallRecovered()` (`Daemon.swift:1241-1253`) fires a **second**
   push: "fin-agentd is answering again; the earlier stall is over."
5. (32768 − 7400) / 580 ≈ 44 ticks at ~2.3 min ≈ 100 min. Measured median inter-page gap:
   **125.9 min.** A metronome. 21 of the 27 pages landed on 09-19 and 09-20.

### Why the window is really ~23k and compaction never saves it

`contextBudget` (`AgentTurnEngine.swift:284`) = `effectiveContextWindow − maxOutputTokens − 512`
= 32768 − 640 − 512 = **31,616**. `compactIfNeeded` (`AgentTranscript.swift:229`) only
trims when the estimate exceeds that. Max prompt observed on 09-19 was 22,933 and on
09-20 was 22,941 — so compaction correctly did not fire, and the audit shows **zero**
`Trimmed older turns to fit the context window` notices on either day.

That is not a compaction bug. It is the endpoint lying about its window: `models_api`
reports 32768 (`[context] endpoint serves 32768 tokens (models_api, of 262144 available)`,
2026-09-20T12:52:31Z) while the loaded model actually fails around 23k. This is the same
family as the known 32768-vs-8192 context-window lie. Compaction *does* work when the
budget is right — it fired 963 times across the two logs, including 216 times on 09-18
and 196 on 09-17 — it simply has a ceiling 8,700 tokens too high to ever engage here.

*(Correction to an earlier read of this data: a grep for `context trimmed` returns 0, but
that string is the transcript note's prefix, not the audit text. The audit text is
`Trimmed older turns to fit the context window`, and it is there 963 times. Compaction has
not "never fired".)*

### Does a stall page that later recovers reset the gate?

**Yes, and that is the whole reason the backoff never engages.**

- `StallNotifyGate.statePaged` (`StallNotifyGate.swift:79-85`) increments `pageCount` only
  `if let previous, previous.active, sameFailure(...)`. Otherwise it returns
  `pageCount: 1`.
- `stateRecovered` (`:88-95`) sets `active = false`.
- So the recovery push is exactly what clears the flag that the escalation depends on.
  Every self-healing episode re-enters at `pageCount: 1`, and the cooldown is permanently
  the 30-minute base. The 30m→1h→2h→4h ladder (`:98-102`) is structurally unreachable
  against a failure that recovers between episodes.

Proof: 26 of the 27 recovery notices in the window read **"after 1 page"**. The only line
in either log reading "after 4 pages" is 2026-09-13T20:46:35Z, during a *sustained*
failure — which is the regime the ladder was written for, and where it does work (it
collapsed 24 failure events into 4 pages that day).

There is a second, independent defeat. `shouldNotify` treats a different failure text as
news needing only the base 30 minutes (`:68-72`). One root cause emits at least three
rotating keys — `predict request returned 500 … Context size has been exceeded`,
`predict stream returned an error … Context size has been exceeded`, and
`Couldn't reach the endpoint: The request timed out.` The 21:07:26Z incident contains all
three inside one five-failure run. So even a fixed ladder would be bypassed by the
alternation roughly a third of the time.

The gate is not inert, though: replaying it over all 107 five-strike events in both logs,
it allowed 39 and suppressed 68 (63.6%). It suppressed 2 in the last week. It works
against storms and is blind to metronomes.

---

## 4. Tuning, in priority order

Each item gives the site, the expected reduction, and what it costs.

**Regression test for every item below: the 2026-09-17/18 work-laptop outage — 12 hours
invisible — must still surface within an hour.** Note what that incident actually was:
that daemon exited at `Daemon.swift:1437`, `fail("shell never became ready: …")`, on the
readiness probe *before* the run loop. `consecutiveFailures >= 5` at `:2077` was never
reached, so the stall page was already silent for all 12 hours. What surfaced it was the
separate `unavailable` site state plus `capabilities.launch_stage` / `launch_failure`
shipped in 1.10.1. None of the changes below touch that path — but item 2 would, if it
were built wrong, and that is called out.

### 1. Fix the context window. Not a notification change.
`AgentTurnEngine.swift:284` / `:292`. The endpoint reports 32768 and dies at ~23k, so the
budget never bites and the transcript walks into a wall every ~100 minutes.
Clamp `effectiveContextWindowTokens` to what the model *actually* accepts — learn the real
ceiling from the first "Context size has been exceeded" refusal the same way
`observedContextWindowTokens` already learns from a refusal at `:660-673`, and persist it
across the restart rather than re-learning 32768 from `models_api` every time.
**Expected reduction: 53 of 59 pushes, 89.8%, to roughly zero.** This is the only item that
removes the noise by removing the fault.
**Cost: none in signal.** It is a correctness fix. It is also the only item here that
makes Fin work better rather than talk less.

### 2. A dwell window before the stall page.
`Daemon.swift:2077-2101`, with a `pendingSince` field added to `StallNotifyState`
(`StallNotifyGate.swift:16-38`). At five failures, record `pendingSince` and keep retrying
silently; page only if failures are still unbroken 30 minutes later; clear `pendingSince`
where `noteStallRecovered` is called (`Daemon.swift:1241`).
**Expected reduction: 26 of 27 pages in this window** (max observed page-to-recovery gap
was 15.8 min).
**Cost, and this is where a skeptic flagged danger — the flag is upheld and the design is
changed accordingly:**
- `pendingSince` **must be persisted in the marker file, never held in the run loop.**
  `consecutiveFailures` is a local that dies with the process (the comment at
  `Daemon.swift:2078-2082` says so), and `fail()` exits. A daemon crash-looping every ~90
  seconds would never accumulate 30 unbroken minutes inside one process lifetime, so an
  in-memory dwell counter would page **never** — silencing exactly the 2026-09-09/10
  crash-loop class the gate was written for. This is the one way to turn this fix into a
  second work-laptop incident.
- A brain that flaps (4 failures, 1 success, 4 failures) never reaches five unbroken
  failures and never pages at all. The dwell must be paired with a failure-*rate* test
  (e.g. ≥80% of turns failed over 30 minutes), or Fin can be effectively dead in silence.
- A genuine hard outage is reported up to 30 minutes later than today.

### 3. Stop paging the all-clear.
`Daemon.swift:1253`. Keep the `log()` and `record()` at `:1251-1252`; send the push only
for an incident that actually crossed the dwell and paged a human — and read that decision
from the **same persisted `StallNotifyState` the page wrote** (`pageCount > 0 && active`),
never from a second independently-evaluated timer.
**Expected reduction: 26 of 26 recovery pushes** in this window, 25 of 26 even without
item 2.
**Cost: low, and it only ever removes reassurance.** The failure direction is false
calm, not a hidden outage. The invariant "a page always gets an all-clear" must hold; two
independent timers is how you break it. `stateRecovered` already returns nil unless
`active`, so it is enforceable in one place.

### 4. Do not re-ask a question that is already outstanding.
Two changes, and **the order matters**:
- (a) `Daemon.swift:2313-2321` `resumeHeartbeatAfterUserInput` lifts the request-input
  pause on *any* inbound message without binding it to the open question. That is how
  "neither, drop it" vanished at 02:35:07Z, and how the 12:14:41Z pause was later lifted
  by an unrelated voice question. Bind the arriving message to the pending question and
  close it. **This must land first.**
- (b) `Daemon.swift:1587` has no dedupe at all (`NotifyDedupe` guards only the model's
  `notify` tool). Key suppression on the goal id while a question on that goal is still
  unanswered. Between 02:41:15Z and 02:48:29Z the model itself said the blocker
  "has already been surfaced" — the ledger state was right there and `onRequestInput`
  never consults it.
**Expected reduction: 5 of 6, ~8% of the week.** It does not move the 90% figure.
**Cost:** a materially different second question about the same goal gets swallowed if the
key is too coarse. Never suppress a question whose text differs materially from the last,
and never suppress the first ask. If (b) lands before (a), the dedupe keys off a signal
that is already known to fire spuriously.

### 5. Split the actionable stall from the transient one.
`Daemon.swift:2062` emits `agent-stalled` for a `BrainOutage`, the same event name as the
27 transient pages. Emit `agent-blocked` instead, add it to `NOTIFY_INPUT_EVENTS`
(`lambda.py:1996`), and remove `agent-stalled` from that tuple so only questions and
credential/payment blocks keep time-sensitive level (`lambda.py:2023-2024`).
**Expected reduction: 0 pushes; it changes 27 of them from Focus-breaking to ordinary.**
**Cost, real:** a genuine long outage that is *not* 401/402/403 — upstream hard-down, disk
full, model file gone — then arrives at ordinary priority and can sit behind a Focus.
Check `fin/Agent/AgentNotificationService.swift` and `AgentRuntime.swift:1937` for
client-side handling keyed on `agent-stalled` before shipping.

### 6. Instrument the push path (do this with item 1, it is two lines).
`Daemon.swift:2712` — `record()` inside `notify()`. `Daemon.swift:2099` — the suppression
branch uses `log()` with no `record()`, so a page the gate blocked leaves no trace.
**Expected reduction: none. It is what makes the next audit honest.**
**Cost: log volume.**

### 7. Lower-priority, unrealised risk (nothing fired this week)
- `Daemon.swift:1991-1997` / `:2360` — require provenance for `task-complete`: at least one
  goal closed in this session with a human origin, and `goals == nil` / `goals.isEmpty`
  should return **false**, not true. Cost: a task started through a route that loses
  provenance finishes silently, and that is the push Levi says he *does* want.
- `AgentTools.swift:453-462` — "Be genuinely social and keep them in the loop" is a
  standing manufacturing order. Replace with Levi's bar: push what a human would act on or
  be glad to learn; never a status, never a self-test, never a restatement.
- `NotifyDedupe.swift:39-55` — widen from 2h to 24h and key on a normalised subject rather
  than title equality or 0.6 Jaccard, which the 09-13 "Audit Complete" run defeated by
  rewording. Cost: "grant uploaded" then "grant rejected" hours later collapse to one.
- `fin/Agent/AgentNotificationService.swift:196` — `recordSignal` runs *before*
  `guard !isAppActive`, so the device Levi is watching still pushes every other device.
  Move it inside the guard.
- `scripts/mac-fin-agentd/refresh.sh:48-54` posts `{agent, event, message}` with no
  `title` and no `body`; `lambda.py:2461-2466` 400s on that, and `|| true` swallows it.
  The one genuinely actionable unattended page in the system — presigned URLs not renewed,
  after which every poll 403s silently — **cannot be delivered**. This fix *adds* a
  notification, at most one per weekly launchd run.

---

## 5. What could not be measured

- **The work laptop.** Its daemon is stopped and that Mac has no sshd by design. Its
  audit log was not read. Every count here is the iMac site only; the real total is ≥59.
- **APNs.** No delivery receipts exist. Sent, delivered, and seen are indistinguishable,
  and the per-push fan-out to N device tokens (`lambda.py:2046`) is not visible from the
  daemon side.
- **Pushes themselves.** `notify()` (`Daemon.swift:2712`) writes no audit record; every
  count is reconstructed from a side-effect. Fixed by one `record()` call.
- **Suppressions.** `Daemon.swift:2099` uses `log()` not `record()`, so a blocked page
  leaves no trace. The 68 suppressions across both logs are a subtraction, not a count.
- **The app tier entirely.** `AgentNotificationService`, `AgentWatchdog`, and the CloudKit
  cross-device signals leave no readable artifact on this machine. The >90% figure is
  tested on the daemon tier only. Instrumentation that would fix this: an app-side audit
  sink mirroring the daemon's JSONL, or routing app banners through the control plane so
  they land in thread events.
- **Whether Levi acted on any push.** There is no read receipt and no correlation between
  a push and the next inbound message. "Actionable" in §2 is my classification from the
  push text plus the measured 4.3-minute median recovery, not a field in the data.
- **Control-plane corroboration.** `_thread_event` drops a notification with no thread, so
  the 27 stall pages and 26 recovery pushes are structurally absent from the recorded
  `notify.sent` events (7 rows, 09-13 → 09-16). Those 7 are not a denominator.
- **Anything before 2026-09-07T19:59:34Z** has rolled off the rotated log.
