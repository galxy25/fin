# Session-activity eval results

Corpus: `scenarios.json` — 6 `inventory` + 3 `registry_merge` + 8
`note-acceptance` + 4 `redaction-leak-rate` = 21 scenarios.

Scored offline with:

```sh
python3 evals/session-activity/run_evals.py
```

## Result (2026-09-11, initial corpus)

```
Corpus: scenarios.json
  inventory: 6/6 [OK]
  registry_merge: 3/3 [OK]
  note-acceptance: 8/8 [OK]
  redaction-leak-rate: 4/4 [OK]
PASS
```

All four families at 100%, as the acceptance bar requires (see README.md —
`inventory`/`registry_merge` are zero-tolerance classification, `note-
acceptance`/`redaction-leak-rate` are the zero-tolerance leak guardrail).

This is the baseline-vs-corpus run only — the baselines here are ports of
the production Swift written in this same change, not an independently
authored spec the Swift was later fit to. The corpus's real job starts now:
it is what the Swift port (`daemon/Tests/FinAgentCoreTests/
TmuxSessionInventoryTests.swift`, `SessionRoutingTests.swift`'s merge cases,
`daemon/Tests/FinAgentDaemonTests/SessionActivitySummarizerTests.swift`) is
checked against on every future change to either the rules here or the
Swift that ports them — see README.md's "change the rule here first" note.
