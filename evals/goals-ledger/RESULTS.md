# Results

## Deterministic baseline (`tick_baseline.py`)

```
goals-ledger evals: 24/35 passed (69%)  [offline]
  core (gates): 21/21   hard (benchmark): 3/14
  clarify  4/4
  drive    5/6
  idle     4/5
  ingest   6/12
  report   5/8
```

Core is fully green — the taxonomy and priority rules are implementable with
plain rules. The hard tier is where the benchmark bites, by construction:

- **Paraphrase/typo attach (h01, h02, h05, h11):** messages about tracked
  work with zero tag overlap; the baseline mints duplicate goals.
- **Ordinary-word traps (h06, h09, h10):** "review" of a grant vs the app
  review; a two-word unblock; a status paraphrase — tag matching either
  over-attaches or gives up and re-asks what the ledger knows.
- **Ball-in-your-court (h03):** a nudge on a goal blocked on the user should
  be answered with the blocker, not ingested as motion.
- **Judgment over clocks (h04, h07, h08):** a stated deadline outranking
  ledger order; an explained wait that is not a stall; fresh-but-identical
  failures that are.

The three hard passes (h12, h13, h14) are model traps the baseline clears by
being simple — labeled as such in the corpus.

A model-backed tick adapter scored on this same corpus goes here next, as in
`evals/tmux-routing/RESULTS.md`.
