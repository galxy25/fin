# Live session inventory + coding-agent activity summaries — evals

Fin's daemon can (opt-in — see `daemon/README.md` and
`DaemonConfig.SessionActivityConfig`'s doc comment) periodically scan the
machine's live tmux panes, classify each session as a plain shell or a
running coding agent, and write short "what is this working on" notes into
the routing registry. This directory scores that feature's two production
responsibilities OFFLINE — no tmux, no network — mirroring
`evals/tmux-routing`'s scenario+baseline+`run_evals.py` shape exactly.

## What's scored

| responsibility | production Swift | baseline spec here |
|---|---|---|
| classify panes into sessions (`shell` vs `coding-agent`) | `TmuxSessionInventory.groupBySession` (`daemon/Sources/FinAgentCore/TmuxSessionInventory.swift`) | `inventory_baseline.py` |
| never clobber a hand-edited registry entry | `SessionRoutingRegistry.observeDiscoveredSession` (`daemon/Sources/FinAgentCore/SessionRouting.swift`) | `registry_merge_baseline.py` |
| reject a leaky model-written activity note | `SessionActivitySummarizer.acceptableNote` (`daemon/Sources/fin-agentd/SessionActivitySummarizer.swift`) | `note_acceptance_baseline.py` |
| full pipeline: raw capture → redact → model → accept/reject | (composition of `MemoryRedactor` + the above) | `run_evals.py`'s own small redaction port, scored against the `redaction-leak-rate` scenarios |

The baselines here are the SPEC, the same relationship `router_baseline.py`
has to the Swift router in `evals/tmux-routing`: change a rule here first, get
the corpus green, then mirror the change in the Swift port and its own
XCTest (`daemon/Tests/FinAgentCoreTests/TmuxSessionInventoryTests.swift`,
`SessionRoutingTests.swift`'s `observeDiscoveredSession`/`setActivityNote`
cases, and `daemon/Tests/FinAgentDaemonTests/SessionActivitySummarizerTests.swift`).
Those XCTests are what proves the Swift matches this spec decision-for-decision
— this harness only pins the spec itself.

## Scenario corpus (`scenarios.json`)

Four families in one file:

- **`inventory`** — pane lists → session snapshots. Covers a single shell
  pane, a single agent pane, a mixed shell+agent session (kind/cwd/target
  must come from the agent pane), two sessions sharing a `cwd` (must not
  merge), an empty `current_command` (never matches an agent), and a custom
  `known_agents` override.
- **`registry_merge`** — `observeDiscoveredSession`'s three branches: a brand
  new session registers `created_by_fin: true`; a hand-registered
  (`created_by_fin: false`) entry is untouched except additive vocabulary; a
  Fin-created entry gets its kind/cwd/agent/pane-target rewritten and its
  `tasks` unioned, never replaced.
- **`note-acceptance`** — `acceptableNote`'s leak backstop: a clean note
  (accept), too short (reject), a `/Users/...` path (reject), an IPv4
  literal (reject), a literal `ssh ...` invocation (reject), a `~/...` path
  (reject), a URL (reject), and — the one case where the LEAK-shaped word
  "idle" is exactly the desired signal, not a leak — a plain "session looks
  idle" observation (accept).
- **`redaction-leak-rate`** — the full-pipeline quality bar: a synthetic pane
  capture holding a real secret (an AWS-shaped key, a bearer token, a PEM
  private key body) must have that secret redacted out of what would reach
  the model, and a canned model completion run through `acceptableNote` must
  never let anything in `must_not_appear` survive into a note that actually
  gets accepted and written.

Note what this family is deliberately NOT testing: `MemoryRedactor` strips
secret-*shaped* text (credential assignments, AWS keys, long hex/base64
runs) — never plain file paths or IP literals, which are ordinary and useful
context for the model to see in a terminal capture. The path/IP/hostname
backstop is `acceptableNote`, scored by the `note-acceptance` family above;
a capture containing a path is expected to reach the model unredacted, and
this harness never asserts otherwise.

## Running

```sh
python3 evals/session-activity/run_evals.py
```

Exit status: 0 if every scenario in every family passes, 1 otherwise — so
this gates CI the same way `evals/tmux-routing/run_evals.py` does.

## Acceptance bar

100% on all four families, zero tolerance. `inventory` and `registry_merge`
are pure classification code — same standard as tmux-routing's core
route/start/clarify/refuse scoring. `note-acceptance` and
`redaction-leak-rate` are the leak guardrail: treated like tmux-routing's
`refuse` scenarios, a single miss here is a hard failure, not a percentage
to trend upward.

No live-mode/hermetic-tmux equivalent is warranted for v1 (unlike
tmux-routing's `--live` mode, which verifies actual `send-keys` delivery) —
there is no "delivery" step to verify here; the production risk is entirely
leak-shape and merge-correctness, both fully offline-scorable. A future pass
that wants to verify the REAL Swift `TmuxSessionInventory.listPanesArguments()`
/`groupBySession` against this same corpus decision-for-decision (the way
`router_baseline.py` is checked against the Swift router) is a
`daemon/Tests/FinAgentCoreTests/TmuxSessionInventoryTests.swift` unit-test
concern, not this harness's — this harness's job is to pin the spec, the
Swift port's own XCTest is what proves the Swift matches it.
