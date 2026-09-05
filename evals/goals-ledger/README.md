# Goals ledger — heartbeat as a goal-driving tick, design + hermetic evals

Fin's heartbeat today is a per-agent periodic tick (default 60s) that asks a
reflective question and pokes the terminal. Levi's directive is bigger:

> "monitoring the stream of my requests using the heartbeat questions and
> driving my goals to completion... like a copilot"
>
> "I don't care about conversation restored, I care about never having to
> start the conversation from scratch as a user."

So the heartbeat becomes a **goal-driving tick over a persisted goals
ledger**. The ledger — not the transcript — is the durable record of what the
user wants; it reloads into every turn, on every device, after every restart.
This directory is the verifiable, low-stakes framework for getting the tick's
*decision* right before any of it touches `AgentRuntime` — the same house
pattern as `evals/tmux-routing/`: schema, taxonomy, labeled corpus,
deterministic baseline, tiered scoring.

## The goals ledger

A first-class persisted artifact, not prompt text (`ledger.example.json` is
the schema). It lives in agent working memory like the routing registry —
synced across devices the way `AgentMemory` records are — and is what every
tick reads first.

```json
{
  "version": 1,
  "goals": [
    {
      "id": "g-voice-intent",
      "title": "Ship the voice intent flow",
      "state": "active",            // open | active | blocked | done
      "priority": 1,                 // 1 = highest; ties broken by ledger order
      "why": "… and how we know it is done",
      "next_action": "the single concrete next step",
      "blocked_on": null,            // named waiter when state == blocked
      "tags": ["voice intent", "siri"],  // matching vocabulary, as in tmux-routing
      "source": "m-101",            // user-message id that created the goal
      "created_at": "…",
      "updates": [
        { "at": "…", "kind": "progress", "text": "…" }
      ]
    }
  ]
}
```

- `updates[]` kinds: `progress` (work happened), `blocker` (why it stopped),
  `report` (the user was told something), `close` (done goal closed out with
  its report), `note` (anything else). The update log is what makes the tick
  idempotent-ish: "was this blocker already surfaced?", "was this done goal
  already closed?" are ledger questions, never memory-of-the-conversation
  questions.
- `tags` is the routing vocabulary (house pattern from the tmux registry):
  phrases the user is likely to use for this goal. The baseline matches on
  them; a model reads the whole goal.
- `why` doubles as the definition of done — the tick can recognize a user
  message announcing that a goal's `why` came true.

## Tick contract

A tick policy is any module exposing `decide(tick_input)` (the baseline is
`policy_baseline.py`; the production tick is fin's model + `prompts/tick.md`,
which must emit the same JSON):

```
input:  { "ledger": {…}, "inbox": [ {"id", "at", "text"}, … ],
          "activity": str, "now": iso8601, "stall_seconds"?: int }
output: { "decision": "ingest|drive|report|idle|clarify",
          "goal_id"?: str|null, "message_id"?: str, "reason": str }
```

`inbox` is the stream of user messages not yet folded into the ledger (in
production: the app's message queue / the daemon's S3 inbox channel).
`activity` is a short summary of what the agent did recently. `"goal_id":
null` on an ingest means *create a new goal*; an id means *update that one*.
One decision per tick — the cheapest correct one.

### Decision taxonomy (the classification the evals score)

| decision  | meaning                                                            | fields |
|-----------|--------------------------------------------------------------------|--------|
| `ingest`  | a new user message creates a goal or updates an existing one       | `goal_id` (null = create), `message_id` |
| `drive`   | pick the most important drivable goal and execute its `next_action`| `goal_id` |
| `report`  | progress, blocker, stall, or closure worth surfacing to the user   | `goal_id` |
| `idle`    | nothing to do — say so cheaply, spend nothing                      |        |
| `clarify` | message or goal genuinely ambiguous — ask, don't guess             | `goal_id`?, `message_id`? |

### Prioritization rules

1. **User messages preempt.** Any unprocessed inbox message is handled
   (ingest / report-answer / clarify) before anything is driven, FIFO.
2. **Done goals close with a report.** A goal in `done` without a `close`
   update owes the user its closing report before new work starts.
3. **Blocked goals surface, don't spin.** An unsurfaced blocker is reported
   once; a surfaced one sits quiet — never driven, never re-nagged. When the
   user pushes on a goal blocked on *them*, the answer is the blocker, not
   fake motion.
4. **Stalls surface.** An active goal with no update inside the stall window
   (default 1800s ≈ 30 ticks) is reported, once — the `report` update resets
   the clock and the next tick goes back to driving. (Judgment beats the
   clock: an update that *explains* a longer wait isn't a stall; fresh but
   identical failure updates *are* — see h07/h08.)
5. **Drive by priority.** Highest-priority `active` goal with a
   `next_action`; if none, promote the best `open` goal. A stated deadline
   outranks ledger order. A goal without a `next_action` never stalls the
   tick — drive what is drivable, and only when nothing is, `clarify` it.
6. **Otherwise idle.** An empty ledger, or everything closed/surfaced, is a
   one-line idle, not an error and not a chat.

### Continuity requirement

**The ledger reloads into every turn = the user never starts from scratch.**
Every material step becomes an `update`; states and blockers live in the
ledger, not in conversation memory. Consequences the corpus enforces: a
status question is answered from the ledger (`report`), never re-asked
(r04/h10); new information about tracked work updates the existing goal
instead of minting a duplicate (i01/i03/i04, h01/h02/h05); and a fresh
process on any device resumes mid-mission because nothing it needs was ever
only in the transcript.

## Eval harness

Pure offline classification — the tick decision is a function of
`{ledger, inbox, activity, now}`, so there is no server to boot. Each
scenario in `scenarios.json` starts from `ledger.example.json` and applies
overrides (`goal_overrides` patches by id, `extra_goals` appends, `goals`
replaces outright), plus its own `inbox`/`now`/`activity`, against a labeled
expected decision.

Two tiers, exactly as in tmux-routing: **core** (no marker) gates the exit
code — any policy must pass all of them — while `"hard": true` scenarios are
the discriminative benchmark (paraphrases, transcription typos, ordinary-word
traps, deadline judgment, explained waits, activity-vs-progress) that exist
to separate a model tick from the deterministic floor; they report but never
fail the run. Baseline numbers live in `RESULTS.md`.

Run (no tmux, no network, no display — pure classification, safe any time):

```sh
python3 evals/goals-ledger/run_evals.py                        # baseline
python3 evals/goals-ledger/run_evals.py --policy my_tick.py    # any policy
python3 evals/goals-ledger/run_evals.py --corpus other.json    # other corpus
```

Output is tiered like tmux-routing: overall pass count, core vs hard split,
a per-decision breakdown, and every miss printed with its expected/actual
JSON and the scenario's note. Exit status is 0 iff **core** is fully green
(hard misses never fail the run), so the command gates CI as-is.

Corpus coverage: new message → ingest-create; message updates existing goal
(incl. delivering a `blocked_on` item and announcing the `why` came true);
FIFO multi-message inbox; active goal with clear `next_action` → drive; open
promotion after closure; competing-priority drive; blocked-on-user → report;
stalled goal → report; done-goal closure → report; status questions →
report; idle ledger / empty ledger / all-blocked-and-surfaced → idle;
pronoun-only and two-goal-ambiguous messages → clarify; vague live goal →
clarify.

## Prompt expansion (production tick)

The block fin's system prompt gains lives in `prompts/tick.md`: the ledger,
the taxonomy, the priority rules, and copilot conduct (drive between
messages, surface blockers once, never re-ask what the ledger knows, close
the loop on done goals). It replaces the current reflective
`AgentRuntime.heartbeatPrompt` — the tick keeps riding the existing loop
(`startHeartbeat`'s beat → `runHeartbeatTurn`), it just stops being a bare
question and starts being a ledger-driven decision.

## Implementation notes (where this lands)

- **Ledger store:** FinAgentCore (shared app + daemon), beside the routing
  `RegistryStore` plan — load/persist JSON in agent working memory; the app
  syncs it like `AgentMemory` (episodic/cumulative records already cross
  devices via CloudKit), the daemon keeps it on disk beside its ledger of
  record. Redact through `MemoryRedactor` before any synced write.
- **Inbox:** the daemon already polls a user-message inbox
  (`DaemonDirectiveClient`, directives-then-inbox order) — that stream is the
  tick's `inbox` input; in the app it is the queued-prompts path. Ingest is
  what finally *consumes* a message into durable state.
- **Beat mechanics stay:** user prompts already outrank beats absolutely in
  `startHeartbeat`'s loop (queue drains first) — that is rule 1 for free.
  `TASK COMPLETE` handling maps onto done→close. `AgentTurnLogic` is where
  the pure decision helpers (stall window, closure checks) belong, so app and
  daemon can never drift.

## Status

- [x] Ledger schema + example (`ledger.example.json`)
- [x] Tick decision taxonomy + priority rules
- [x] Baseline tick policy (deterministic rules, `policy_baseline.py`)
- [x] Scenario corpus v1 (35 scenarios: 21 core, 14 hard — `scenarios.json`)
- [x] Offline scorer with tiered core/hard scoring (`run_evals.py`)
- [x] Core fully green on the baseline (21/21; hard 3/14 by design — `RESULTS.md`)
- [x] Prompt block draft (`prompts/tick.md`)
- [ ] Model-backed tick adapter scored on the same corpus
- [ ] Ledger read/write in FinAgentCore (agent working memory + daemon disk)
- [ ] Prompt block wired into AgentRuntime's heartbeat turn
