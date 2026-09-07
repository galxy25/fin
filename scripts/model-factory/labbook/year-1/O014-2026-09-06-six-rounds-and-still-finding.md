---
id: O014
date: 2026-09-06
occurred: 2026-09-06
kind: OBSERVATION
title: Six correction rounds, each smaller and none empty — the book is closed with its remaining findings listed, not fixed
status: standing
tags: [corrections, provenance, audit, convergence, append-only]
sources:
  - "the seventh audit's findings, read 2026-09-06 21:57:39 PDT; every one is reproduced verbatim in the table below rather than summarised"
  - f6b186e — the commit this entry is appended to; its own audit is the one being recorded
  - "check_citations.py --verify-lines at f6b186e: scanned 33 files; 0 findings, 39 waived — clean"
corrects: []
related: [O008, O010, O013]
---

## What happened

Six rounds of correction were run on this book in one day. Each round fixed every
finding it was given. Each round's audit then found more, and no round's audit
came back empty:

| round | findings closed | findings the next audit raised |
|---|---|---|
| 1 (audit pass) | 43 | 5 |
| 2 (consolidation) | 5 | 5 |
| 3 (run at every revision) | 2 | 5 |
| 4 (pin the revisions) | 44 citations | 3 |
| 5 (run-1 entries) | 3 | 11 |
| 6 (E009 close) | 11 | 7 |

The findings shrink — round 6's audit raised one process finding, two
overstatements, and four arithmetic slips, against round 1's forty-three — but
the sequence does not reach zero, and there is no reason from the data to think a
seventh round would be the one that does. **The rate at which a correction pass
introduces new claims is close to the rate at which it removes bad ones**, which
is [[O010]]'s thesis measured over six iterations instead of three.

So this book is closed for the day with its remaining findings **listed and
unfixed**, which is the honest disposition and the one its own conventions
prefer: an open item recorded is evidence; an open item repaired in silence is
not.

## The findings that remain open at f6b186e

| severity | site | what is wrong |
|---|---|---|
| high | E009:40 | The round's method — ten in-place rewrites of published entries — is licensed as "the README's draft-phase rule" using a criterion the README does not state. The rewrites may well be defensible; the justification as written is not, and it licenses exactly the silent-edit behaviour [[O008]] exists to prevent. |
| medium | E009:486 | The replacement headline still overstates the half the audit did not re-derive: "propagates completely on the tier the labels are strong on" rests on a ONE-scenario effect (core 25/26 -> 26/26). |
| medium | E009:31 | The summary says eleven findings and enumerates twelve; six of the eleven were against E009, not seven. |
| low | E009:287 | One null-model probability is 0.35, not 0.36. |
| low | E009:337 | "H004 supported on both halves" omits checkpoint 1000's core 22/26 — a three-scenario regression below the base, which is the core-tier regression H004 says it would be refuted by. |
| low | O012:45 | A pasted `git log` output added by this commit is falsified by this commit: it lists two commits, and the command now returns three because this commit's own message contains the search term. The self-referential-count defect ([[O005]]) in a new costume. |
| low | README:201 | A command and its numbers disagree threefold: the bare grep returns 74 hits, not 25; the 25 requires the exclude path the sentence omits. |

## What this does not show

It does not show that the book is wrong in any way that matters to the factory —
every gate number in [[E009]] was checked against `models/gate-sweep/results.tsv`
and the eval logs, and the promotion verdict does not move. It shows that the
prose *about* those numbers keeps acquiring small errors faster than review
removes them, and that six rounds is where the returns stopped justifying the
next one. It also does not show that a seventh round would find seven more; the
sequence is short and the counts are not a trend ([[O012]]).

## What to do next

Fix these when the entries are next touched for another reason, not as a
dedicated pass. Prefer, for any future entry, the two habits that actually held
all day: a number that is a property rather than a reading (`save_every: 250`,
not "sixteen files"), and a command whose output is pasted from a run rather than
described.
