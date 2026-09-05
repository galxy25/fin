# tmux session routing — design + hermetic evals

Fin's agent must be able to manage tmux sessions on the machine it controls:
create new windows/terminals, **discriminate** between starting a NEW
coding-agent session and working with an ALREADY-RUNNING one, and route the
user's queries to the correct session. This directory is the verifiable,
low-stakes framework for getting that right *before* any of it touches a real
terminal.

## The routing problem

Levi runs several long-lived Claude/coding-agent tmux windows at once (e.g.
`fin`, `pocketdj`, `africanintellect`). When he says "fix the fin widget
build", the message must land in the **fin** session — not pocketdj's window,
not a fresh session. When he says "spin up a new agent to try X", that IS a
new session. When it's genuinely ambiguous, the right move is to ask, not
guess.

### Decision taxonomy (the classification the evals score)

Every routing decision is one of four actions, emitted as JSON:

| action    | meaning                                                        | fields |
|-----------|----------------------------------------------------------------|--------|
| `route`   | deliver to an existing, registered session                     | `session` |
| `start`   | create a new coding-agent session for this task                | `task` |
| `clarify` | ambiguous — ask the user instead of guessing                   | `question` |
| `refuse`  | target exists but is NOT registered/fin-created — off-limits   | `reason` |

`refuse` is the guardrail made visible: **fin only ever send-keys into
sessions it created or that Levi explicitly registered.** A session that
merely *exists* on the server (someone's live `main` window) is untouchable,
even when the user's phrasing seems to point at it — surface it and ask for
registration instead.

## The task→session registry

Fin keeps a persistent mapping of tasks → terminal sessions in its working
memory (`registry.example.json` is the schema). This is a first-class
artifact, not prompt text: it survives restarts, syncs like other agent
memory, and is what both the router and the guardrail consult.

```json
{
  "version": 1,
  "sessions": [
    {
      "session": "fin",
      "kind": "coding-agent",
      "agent": "claude-code",
      "cwd": "~/forges/levi/fin",
      "tasks": ["fin", "ios app", "tvos", "widget", "testflight", "voice intent"],
      "registered_by": "levi",
      "created_by_fin": false
    }
  ]
}
```

- `tasks` is the routing vocabulary: lowercase phrases the user is likely to
  use for work belonging to this session. One session may serve many tasks;
  one task key should belong to exactly one session (collisions → `clarify`).
- `created_by_fin: true` marks sessions fin itself spawned (auto-registered).
- Anything not in the registry is invisible to `route` and forbidden to
  send-keys — existence on the tmux server grants nothing.

## Router contract

A router is any function with this signature (the baseline is
`router_baseline.py`; the production router is fin's model + prompt, which
must emit the same JSON):

```
input:  { "query": str, "registry": {...}, "live_sessions": [str] }
output: { "action": "route|start|clarify|refuse",
          "session"?: str, "task"?: str, "question"?: str, "reason": str }
```

`live_sessions` is what `tmux list-sessions` actually shows — the router must
handle registry entries whose sessions died (route → start or clarify) and
live sessions the registry has never heard of (never route to them).

## Hermetic eval harness

**Never touches real tmux.** Everything runs on a dedicated detached server on
a private socket (`tmux -L fin-eval-<pid> -f /dev/null`), populated with fake
coding agents (`fake_agent.sh` — a REPL that acks every line with a
capture-pane-greppable marker). The harness kills the whole server on exit.

Two modes:

- **Offline (default):** pure classification. Each scenario in
  `scenarios.json` supplies a query + registry + live-session list and a
  labeled expected decision; `run_evals.py` scores the router and reports
  overall + per-action accuracy and every miss.
- **Live (`--live`):** additionally boots the private-socket server, creates
  the scenario's sessions running `fake_agent.sh`, executes `route` decisions
  through the guarded executor, and verifies with `capture-pane` that the
  message reached exactly the expected fake agent — and that the guardrail
  blocks delivery to unregistered sessions (a `refuse` scenario failing open
  is a test failure).

Run:

```sh
python3 evals/tmux-routing/run_evals.py            # offline classification
python3 evals/tmux-routing/run_evals.py --live     # + hermetic tmux delivery
```

Both are safe to run any time: no default-socket tmux, no display, no real
agents.

## Prompt expansion (production router)

The block fin's system prompt gains lives in `prompts/router.md`: it teaches
the model the taxonomy, the registry, the guardrail, and how to talk to a
coding agent it drives (send one instruction at a time, wait for the ack
marker/prompt, prefer asking over guessing). Wiring it into
`AgentRuntime`/FinAgentCore happens only after the baseline + corpus are
green here — the corpus then becomes the regression suite for the model
router by swapping `router_baseline.py` for a model-backed adapter with the
same contract.

## Status

- [x] Decision taxonomy + registry schema
- [x] Baseline router (deterministic keyword/rules)
- [x] Scenario corpus v1 (see `scenarios.json`)
- [x] Offline scorer + hermetic live mode + guardrail executor
- [ ] Model-backed router adapter scored on the same corpus
- [ ] Registry read/write in FinAgentCore (agent working memory)
- [ ] Prompt block wired into AgentRuntime
