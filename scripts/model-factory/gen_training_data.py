#!/usr/bin/env python3
"""Synthesize HELD-OUT supervised fine-tuning data for the fin foreman model.

Stdlib only. Output is the same chat format `build_dataset.py` emits —
`{"messages": [{system}, {user}, {assistant}]}`, one object per line, byte-stable
— but every example is generated from FRESH inputs (new session names, new
project domains, new task phrasings, new ledger goals, new credential/2FA and
notify situations). NONE of them reproduce an eval scenario's query, so this set
can train a candidate that is still fairly scored by the untouched eval gate.

Why this exists (README "Leakage rule"): `evals/tmux-routing/scenarios.json` and
`evals/goals-ledger/scenarios.json` are the promotion GATE. Training on them
measures memorization, not skill. `build_dataset.py` emits them only as scaffold
seed; this script replaces that with synthetic variants whose LABELS ARE CORRECT
BY CONSTRUCTION.

The four fine-tune targets (README "Fine-tune targets"):

  1. tmux session routing      — labeled by evals/tmux-routing/router_baseline.decide
  2. goals-ledger mission-tick — labeled by evals/goals-ledger/policy_baseline.decide
  3. owner-feedback elicitation — ask-one-short-question vs proceed (construction label)
  4. app tool-use              — request_input / notify / proceed (construction label)

Labeling, by target:

  * Targets 1 & 2 run the DETERMINISTIC BASELINE as the labeler over each
    generated input. We generate inputs inside the baseline's competence zone
    (the core taxonomy — clear vocabulary, clear new-session phrasings, clear
    guardrail cases), then KEEP an example only when the baseline's decision
    equals the class we generated it for. Label == baseline rule output AND ==
    intended class: correct twice over. The adversarial "hard" tier (paraphrase,
    typo, misdirection) is deliberately NOT reproduced here — that tier is the
    held-out discriminator the model must generalize to, and the baseline itself
    mislabels it, so it is not safe training signal.

  * Targets 3 & 4 have no baseline and no eval corpus yet (the README notes the
    builder "grows a track per target as each corpus lands"; these have not
    landed). Their labels are correct BY CONSTRUCTION: each input is emitted from
    a labeled template family, and a pure feature->label rule (documented inline)
    assigns the class. request_input's schema is FinAgentCore's real
    `AgentToolSpec.requestInput`; `notify` mirrors the daemon's `/notify` surface
    action (DaemonNotifyClient).

System prompts come from the SAME prompt files the eval framing uses:
`evals/tmux-routing/prompts/router.md` (via router_llm._system_prompt, byte-
identical framing) for routing, and `evals/goals-ledger/prompts/tick.md` for the
tick. Targets 3 & 4 use compact prompts grounded in the README targets, the
tick.md continuity rule, and the AgentTools descriptions.

LEAKAGE GATE (hard requirement): after generation, every eval scenario input
(tmux-routing queries + goals-ledger inbox message texts) is loaded and every
training input is checked for exact-match and near-duplicate (normalized,
containment, and token-Jaccard >= 0.7). Any overlap is DROPPED, then the kept
set is re-verified to contain zero overlap (asserted). The check result and
per-target/decision counts are printed.

Usage:
  python3 scripts/model-factory/gen_training_data.py [--out FILE] [--seed N]
Default output: <repo>/datasets/sft-train-<YYYY-MM-DD>.jsonl (datasets/ gitignored).
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import random
import re
import sys
from collections import Counter, defaultdict
from datetime import timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ROUTING_DIR = REPO / "evals" / "tmux-routing"
LEDGER_DIR = REPO / "evals" / "goals-ledger"

# Key orders match build_dataset.py so a line is byte-identical whether it comes
# from there or here.
ROUTE_KEY_ORDER = ("action", "session", "task", "question", "reason")
TICK_KEY_ORDER = ("decision", "goal_id", "message_id", "reason")

JACCARD_NEAR = 0.70


# --------------------------------------------------------------------------- #
# Import the eval baselines + system-prompt builder (byte-identical framing).
# --------------------------------------------------------------------------- #
def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


router_baseline = _load(ROUTING_DIR / "router_baseline.py", "fin_router_baseline")
router_llm = _load(ROUTING_DIR / "router_llm.py", "fin_router_llm")
policy_baseline = _load(LEDGER_DIR / "policy_baseline.py", "fin_policy_baseline")


# --------------------------------------------------------------------------- #
# Serialization helpers (byte-stable, matching build_dataset.py).
# --------------------------------------------------------------------------- #
def _stable(label: dict, order: tuple) -> str:
    ordered = {k: label[k] for k in order if k in label}
    return json.dumps(ordered, ensure_ascii=False)


def _example(system: str, user: str, assistant: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant},
        ]
    }


def _record(target: str, decision: str, input_text: str, example: dict) -> dict:
    line = json.dumps(example, ensure_ascii=False)
    return {
        "target": target,
        "decision": decision,
        "input_text": input_text,
        "example": example,
        "line": line,
    }


# --------------------------------------------------------------------------- #
# Fresh routing vocabulary. Session names and task phrases are globally distinct
# from the eval registry (fin / pocketdj / africanintellect) and from each
# other; matching is whole-phrase so shared single words never cross-match.
# --------------------------------------------------------------------------- #
DOMAINS = [
    ("orchard", ["orchard app", "harvest planner", "pruning schedule", "yield forecast"]),
    ("ledgerbook", ["ledgerbook", "invoice import", "reconciliation view", "tax export"]),
    ("trailhead", ["trailhead", "gpx upload", "elevation profile", "route drawing"]),
    ("brewlog", ["brewlog", "fermentation timer", "recipe scaling", "batch history"]),
    ("lumen", ["lumen", "photo gallery", "lightbox viewer", "raw develop"]),
    ("cadence", ["cadence", "interval workout", "pace zones", "training calendar"]),
    ("mosaic", ["mosaic", "tile grid", "color palette", "grout spacing"]),
    ("beacon", ["beacon", "sensor feed", "telemetry chart", "alert rules"]),
    ("quill", ["quill", "draft editor", "publishing flow", "markdown export"]),
    ("harbor", ["harbor", "container image", "compose stack", "port mapping"]),
    ("verdant", ["verdant", "plant bed", "watering schedule", "seed catalog"]),
    ("sonata", ["sonata", "practice log", "metronome tempo", "sheet music"]),
    ("kettle", ["kettle", "meal plan", "grocery list", "pantry stock"]),
    ("ranger", ["ranger", "vehicle roster", "dispatch board", "mileage log"]),
    ("pixelforge", ["pixelforge", "sprite sheet", "tilemap editor", "collision mesh"]),
    ("atlas", ["atlas", "map layer", "geocoding", "offline tiles"]),
]

# Live-but-unregistered session names for the refuse guardrail. All fresh (the
# eval uses main / scratch / deploy / demo).
UNREG_NAMES = [
    "sandbox", "staging", "playground", "workbench", "toolbox",
    "garage", "backend", "frontend", "greenhouse", "cellar",
]


def _make_registry(domain_idxs: list[int]) -> dict:
    sessions = []
    for i in domain_idxs:
        name, tasks = DOMAINS[i]
        sessions.append({
            "session": name,
            "kind": "coding-agent",
            "agent": "claude-code",
            "cwd": f"~/work/{name}",
            "tasks": tasks,
        })
    return {"version": 1, "sessions": sessions}


def _trio(i: int) -> list[int]:
    n = len(DOMAINS)
    return [i % n, (i + 1) % n, (i + 2) % n]


# --------------------------------------------------------------------------- #
# Target 1: tmux routing. Generate class-targeted inputs, label with the
# deterministic baseline, keep only where baseline == intended class.
# --------------------------------------------------------------------------- #
ROUTE_TEMPLATES = [
    "fix the {phrase}",
    "the {phrase} is broken, take a look",
    "{phrase} needs attention today",
    "clean up the {phrase} logic",
    "the {phrase} keeps regressing",
    "improve the {phrase} performance",
]
ROUTE_NAMED_TEMPLATES = [
    "{name}: rerun the {phrase}",
    "have {name} handle the {phrase}",
]
START_PHRASE_TEMPLATES = [
    "start a new agent to work on the {phrase}",
    "spin up a new session for the {phrase}",
    "launch another window for the {phrase}",
    "open a fresh terminal for the {phrase}",
    "create a new session for the {phrase}",
    "get me a fresh session for the {phrase}",
    "i need a new terminal for the {phrase}",
    "open up a new agent for the {phrase}",
]
START_GENERIC_TAILS = [
    "start a new agent for a quick experiment",
    "spin up a new session to prototype something",
    "launch another window so i can poke around",
    "open a fresh terminal for some scratch work",
    "create a new session for a throwaway test",
    "get me a fresh session to try an idea",
]
# Fresh guardrail phrasings, deliberately dissimilar to eval f01-f04.
REFUSE_TEMPLATES = [
    "open the {unreg} terminal and clear the logs",
    "attach to the {unreg} session and check what's running",
    "push a restart into the {unreg} window",
    "forward this keystroke to the {unreg} terminal",
    "in the {unreg} session, cancel the current job",
    "have the {unreg} window echo its hostname",
    "route this command over to the {unreg} tmux session",
    "drop a stop signal into the {unreg} terminal",
]
# Two registered names -> ambiguous -> clarify. Dissimilar to eval c03.
TWO_NAMED_TEMPLATES = [
    "should {a} or {b} handle this one?",
    "coordinate the change across {a} and {b}",
    "this affects both {a} and {b}",
    "line up {a} with {b} on this",
    "{a} and {b} both need the same tweak",
]
# No vocabulary, no names, no new-session, no session-context -> clarify.
GENERIC_CLARIFY = [
    "can you take care of that for me",
    "get this sorted out today",
    "just make it work please",
    "tidy up the loose ends before friday",
    "deal with the thing from earlier",
    "move that forward when you have a moment",
    "wrap this up before end of day",
    "handle the follow-up items",
    "take another pass at it",
    "get it across the line",
    "circle back on that issue",
    "smooth out the rough edges",
    "give it one more go",
    "make the change we discussed",
    "finish what you started earlier",
    "take it from here",
    "do the needful and report back",
    "get everything green again",
    "close out the remaining items",
    "pick the low-hanging fruit first",
    "knock out the quick wins",
    "address the feedback we got",
    "tighten things up a bit",
    "sort the priorities for me",
    "just proceed however you think best",
    "take care of the usual cleanup",
    "get us unblocked here",
    "keep the momentum going",
    "do a final polish pass",
    "give this another look when free",
]


def gen_routing():
    out = []
    n = len(DOMAINS)

    def keep(query, registry, live, intended_action, intended_session=None):
        decision = router_baseline.decide(query, registry, live)
        if decision.get("action") != intended_action:
            return
        if intended_session is not None and decision.get("session") != intended_session:
            return
        system = router_llm._system_prompt(registry, live)
        assistant = _stable(decision, ROUTE_KEY_ORDER)
        out.append(_record("routing", intended_action, query,
                            _example(system, query, assistant)))

    # route: unique task-vocab match, all sessions live.
    for i in range(n):
        idxs = _trio(i)
        registry = _make_registry(idxs)
        live = [DOMAINS[j][0] for j in idxs]
        name, tasks = DOMAINS[i]
        for phrase in tasks:
            for tpl in ROUTE_TEMPLATES:
                keep(tpl.format(phrase=phrase), registry, live, "route", name)
            for tpl in ROUTE_NAMED_TEMPLATES:
                keep(tpl.format(name=name, phrase=phrase), registry, live, "route", name)

    # start: explicit new-session request (phrase-flavored and generic).
    for i in range(n):
        idxs = _trio(i)
        registry = _make_registry(idxs)
        live = [DOMAINS[j][0] for j in idxs]
        name, tasks = DOMAINS[i]
        for phrase in tasks:
            for tpl in START_PHRASE_TEMPLATES:
                keep(tpl.format(phrase=phrase), registry, live, "start")
        for tail in START_GENERIC_TAILS:
            keep(tail, registry, live, "start")

    # start: registered-but-dead session -> recreate (task matches, not live).
    for i in range(n):
        idxs = _trio(i)
        registry = _make_registry(idxs)
        live = [DOMAINS[j][0] for j in idxs if j != i]  # target domain absent
        name, tasks = DOMAINS[i]
        for phrase in tasks:
            for tpl in ROUTE_TEMPLATES:
                keep(tpl.format(phrase=phrase), registry, live, "start")

    # clarify: no routable vocabulary.
    for k, phrase in enumerate(GENERIC_CLARIFY):
        idxs = _trio(k)
        registry = _make_registry(idxs)
        live = [DOMAINS[j][0] for j in idxs]
        keep(phrase, registry, live, "clarify")

    # clarify: two registered sessions named.
    for i in range(n):
        for gap in (1, 2, 3):
            a_idx, b_idx = i % n, (i + gap) % n
            if a_idx == b_idx:
                continue
            idxs = [a_idx, b_idx, (i + 4) % n]
            registry = _make_registry(idxs)
            live = [DOMAINS[j][0] for j in idxs]
            a, b = DOMAINS[a_idx][0], DOMAINS[b_idx][0]
            for tpl in TWO_NAMED_TEMPLATES:
                keep(tpl.format(a=a, b=b), registry, live, "clarify")

    # refuse: live-but-unregistered session named in a session context.
    for i in range(n):
        idxs = _trio(i)
        registry = _make_registry(idxs)
        registered = [DOMAINS[j][0] for j in idxs]
        for u, unreg in enumerate(UNREG_NAMES):
            live = registered + [unreg]
            for tpl in REFUSE_TEMPLATES:
                keep(tpl.format(unreg=unreg), registry, live, "refuse")

    return out


# --------------------------------------------------------------------------- #
# Target 2: goals-ledger tick. Build fresh ledgers + inboxes, label with the
# deterministic policy baseline, keep where baseline == intended decision.
# --------------------------------------------------------------------------- #
NOW_DT = datetime.datetime(2027, 2, 1, 15, 0, 0, tzinfo=timezone.utc)


def _iso(dt) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


NOW = _iso(NOW_DT)


def _ago(**kw) -> str:
    return _iso(NOW_DT - timedelta(**kw))


TICK_STALL_SECONDS = 1800

# Fresh goals: ids, titles, a primary matchable tag phrase + extras, a
# next_action and a why. All domains disjoint from the eval ledger (voice
# intent / app store rejection / routing registry / cloud worker).
TICK_GOALS = [
    ("g-catalog-sync", "Sync the orchard catalog nightly", "tree inventory",
     ["tree inventory", "catalog sync"],
     "Run the nightly catalog sync against staging and diff the counts.",
     "Growers need a live tree inventory; done when the nightly sync runs clean."),
    ("g-invoice-import", "Import legacy invoices into ledgerbook", "invoice import",
     ["invoice import", "legacy invoices"],
     "Map the legacy CSV columns and dry-run the invoice importer.",
     "Bookkeeping needs the old invoices in; done when a dry-run imports with zero errors."),
    ("g-gpx-upload", "Ship GPX upload for trailhead", "gpx upload",
     ["gpx upload", "track import"],
     "Wire the GPX parser to the upload endpoint and validate a sample track.",
     "Hikers want to upload routes; done when a real GPX file renders on the map."),
    ("g-recipe-scaling", "Add recipe scaling to brewlog", "recipe scaling",
     ["recipe scaling", "batch math"],
     "Implement the scaling factor math and unit-test the gravity conversions.",
     "Brewers scale recipes by volume; done when doubling a batch keeps the numbers right."),
    ("g-photo-gallery", "Rebuild the lumen photo gallery grid", "photo gallery",
     ["photo gallery", "grid layout"],
     "Replace the gallery grid with the virtualized layout and test scroll perf.",
     "The gallery janks on large libraries; done when 5k photos scroll smoothly."),
    ("g-pace-zones", "Compute pace zones in cadence", "pace zones",
     ["pace zones", "threshold pace"],
     "Derive the five pace zones from threshold pace and render the bands.",
     "Runners train by zone; done when zones compute from a threshold test."),
    ("g-tile-grid", "Fix the mosaic tile grid renderer", "tile grid",
     ["tile grid", "snap alignment"],
     "Rework the grid snapping so tiles align on fractional offsets.",
     "Tiles drift off-grid; done when snapping is pixel-exact at any zoom."),
    ("g-alert-rules", "Ship alert rules for beacon", "alert rules",
     ["alert rules", "threshold alerts"],
     "Add the rule builder UI and evaluate rules against the live sensor feed.",
     "Operators need threshold alerts; done when a rule fires on a real reading."),
    ("g-publishing-flow", "Finish quill's publishing flow", "publishing flow",
     ["publishing flow", "scheduled posts"],
     "Wire the scheduler to the draft store and publish a scheduled post.",
     "Writers schedule posts; done when a scheduled draft goes live on time."),
    ("g-compose-stack", "Stand up the harbor compose stack", "compose stack",
     ["compose stack", "service graph"],
     "Author the compose file and bring the full service graph up locally.",
     "Onboarding needs one-command bring-up; done when the stack starts clean."),
    ("g-seed-catalog", "Load the verdant seed catalog", "seed catalog",
     ["seed catalog", "planting windows"],
     "Import the seed dataset and compute planting windows per zone.",
     "Gardeners pick seeds by zone; done when the catalog shows planting windows."),
    ("g-metronome", "Build the sonata metronome", "metronome tempo",
     ["metronome tempo", "click track"],
     "Implement the click-track scheduler with sample-accurate timing.",
     "Practice needs a steady click; done when the metronome holds tempo for 10 minutes."),
    ("g-meal-plan", "Add meal planning to kettle", "meal plan",
     ["meal plan", "weekly menu"],
     "Generate a weekly menu from saved recipes and build the grocery list.",
     "Cooks plan a week at once; done when a plan produces a correct grocery list."),
    ("g-dispatch-board", "Ship the ranger dispatch board", "dispatch board",
     ["dispatch board", "route assignment"],
     "Build the drag-to-assign board and persist route assignments.",
     "Dispatchers assign routes visually; done when assignments save and reload."),
    ("g-sprite-sheet", "Add sprite-sheet packing to pixelforge", "sprite sheet",
     ["sprite sheet", "atlas packing"],
     "Implement the bin-packer and export a packed sprite atlas.",
     "Artists pack sprites; done when a folder exports a tight atlas."),
    ("g-offline-tiles", "Enable offline tiles in atlas", "offline tiles",
     ["offline tiles", "tile cache"],
     "Add the tile cache and serve map layers with no network.",
     "Field users lose signal; done when a cached region renders offline."),
]

# Statements that match NO ledger tag -> new goal on ingest.
CREATE_STATEMENTS = [
    "we should add a dark mode toggle to the settings screen",
    "please add a printable weekly summary to the reports area",
    "let's build an onboarding tutorial for brand new accounts",
    "add keyboard shortcuts for the most common actions",
    "we need an offline read-only mode for the whole app",
    "build a bulk export to a single zip download",
    "add a global search box to the top navigation bar",
    "let's support signing in with a magic email link",
    "add an undo button to the destructive actions",
    "we should localize the interface into spanish first",
    "build a lightweight changelog page for each release",
    "add a duplicate-detection warning on manual entry",
    "let's add a compact density option to the tables",
    "we need a proper empty-state illustration everywhere",
    "add a share-by-link option with an expiry date",
    "build a quick-start template picker for new projects",
]

# Short / question fragments that match nothing -> clarify.
THIN_CLARIFY = [
    "it broke again",
    "still not right",
    "same as before",
    "that thing again",
    "why is it doing that?",
    "can you check?",
    "is it done yet?",
    "what now?",
    "any luck?",
    "did that work?",
    "hows it going?",
    "are we good?",
    "should i worry?",
    "anything to report?",
    "whats left?",
    "everything ok?",
]


def _goal(gid, title, tag, extra_tags, next_action, why, state, priority,
          updates, blocked_on=None, source="m-000", created="days"):
    return {
        "id": gid,
        "title": title,
        "state": state,
        "priority": priority,
        "why": why,
        "next_action": next_action,
        "blocked_on": blocked_on,
        "tags": [tag] + [t for t in extra_tags if t != tag],
        "source": source,
        "created_at": _ago(days=6) if created == "days" else created,
        "updates": updates,
    }


def _ledger(goals) -> dict:
    return {"version": 1, "updated_at": NOW, "goals": goals}


def _tick_system_prompt() -> str:
    block = (LEDGER_DIR / "prompts" / "tick.md").read_text()
    return (
        f"{block}\n\n"
        "---\n\n"
        "## Output contract — STRICT\n\n"
        "Reply with EXACTLY one JSON object and nothing else: no prose, no "
        "markdown fences. The stall window is 30 minutes. Schema:\n\n"
        '{"decision": "ingest" | "drive" | "report" | "idle" | "clarify",\n'
        ' "goal_id": "<goal id, or null to create on ingest>",\n'
        ' "message_id": "<inbox message id, when a message drove the decision>",\n'
        ' "reason": "<one sentence>"}\n'
    )


_TICK_SYSTEM = None


def _tick_user(ledger, inbox) -> str:
    payload = {
        "now": NOW,
        "activity": "Between messages; last tick advanced the top goal.",
        "inbox": inbox,
        "ledger": ledger,
    }
    return json.dumps(payload, indent=2, ensure_ascii=False)


def gen_ledger():
    global _TICK_SYSTEM
    _TICK_SYSTEM = _tick_system_prompt()
    out = []
    n = len(TICK_GOALS)

    def keep(ledger, inbox, intended, want_goal="__any__"):
        decision = policy_baseline.decide({
            "ledger": ledger, "inbox": inbox, "activity": "",
            "now": NOW, "stall_seconds": TICK_STALL_SECONDS,
        })
        if decision.get("decision") != intended:
            return
        if want_goal != "__any__" and decision.get("goal_id") != want_goal:
            return
        assistant = _stable(decision, TICK_KEY_ORDER)
        inbox_text = inbox[0]["text"] if inbox else ""
        out.append(_record("ledger", intended, inbox_text,
                            _example(_TICK_SYSTEM, _tick_user(ledger, inbox), assistant)))

    def active_goal(spec, priority=1, last_update="min"):
        gid, title, tag, extra, na, why = spec
        at = _ago(minutes=8) if last_update == "min" else _ago(hours=4)
        return _goal(gid, title, tag, extra, na, why, "active", priority,
                     [{"at": at, "kind": "progress", "text": "Work in progress."}])

    # ingest (update existing): message hits one goal's tag, statement form.
    upd_templates = [
        "the {tag} looks off after last night's run",
        "just tweaked the {tag} and it seems better now",
        "found a bug in the {tag} we should fold in",
        "the {tag} needs a small change per the customer",
        "quick note about the {tag}: it regressed a bit",
        "the {tag} handling is flaky on slow networks",
        "heads up, the {tag} threw an error this morning",
        "the {tag} is nearly there, one more pass",
        "customer wants a tweak to the {tag} behavior",
        "the {tag} looks great now, thanks",
    ]
    for i in range(n):
        spec = TICK_GOALS[i]
        other = TICK_GOALS[(i + 1) % n]
        ledger = _ledger([active_goal(spec, 1), active_goal(other, 2)])
        for k, tpl in enumerate(upd_templates):
            inbox = [{"id": f"m-u{i}{k}", "at": _ago(minutes=1),
                      "text": tpl.format(tag=spec[2])}]
            keep(ledger, inbox, "ingest", want_goal=spec[0])

    # ingest (create new): message matches no goal -> goal_id null.
    for i, stmt in enumerate(CREATE_STATEMENTS):
        a, b = TICK_GOALS[i % n], TICK_GOALS[(i + 3) % n]
        ledger = _ledger([active_goal(a, 1), active_goal(b, 2)])
        inbox = [{"id": f"m-c{i}", "at": _ago(minutes=1), "text": stmt}]
        keep(ledger, inbox, "ingest", want_goal=None)

    # report (status question about a known goal).
    q_templates = [
        "how's the {tag} coming along?",
        "any progress on the {tag}?",
        "where are we with the {tag}?",
        "is the {tag} sorted yet?",
        "what's the state of the {tag}?",
        "did the {tag} land?",
    ]
    for i in range(n):
        spec = TICK_GOALS[i]
        other = TICK_GOALS[(i + 2) % n]
        ledger = _ledger([active_goal(spec, 1), active_goal(other, 2)])
        for k, tpl in enumerate(q_templates):
            inbox = [{"id": f"m-q{i}{k}", "at": _ago(minutes=1),
                      "text": tpl.format(tag=spec[2])}]
            keep(ledger, inbox, "report", want_goal=spec[0])

    # report (closure): a done goal with no close update.
    for i in range(n):
        gid, title, tag, extra, na, why = TICK_GOALS[i]
        done = _goal(gid, title, tag, extra, None, why, "done", 1,
                     [{"at": _ago(minutes=20), "kind": "progress",
                       "text": "Definition of done met."}])
        keep(_ledger([done]), [], "report", want_goal=gid)

    # report (surface blocker): blocked, blocker update, no report after.
    for i in range(n):
        gid, title, tag, extra, na, why = TICK_GOALS[i]
        blocked = _goal(gid, title, tag, extra, na, why, "blocked", 1,
                        [{"at": _ago(minutes=25), "kind": "blocker",
                          "text": "Waiting on an external dependency."}],
                        blocked_on="An upstream service the owner controls.")
        keep(_ledger([blocked]), [], "report", want_goal=gid)

    # report (stall): active goal silent past the 30m window.
    for i in range(n):
        spec = TICK_GOALS[i]
        ledger = _ledger([active_goal(spec, 1, last_update="stale")])
        keep(ledger, [], "report", want_goal=spec[0])

    def closed_goal(spec, priority=1):
        gid, title, tag, extra, na, why = spec
        return _goal(gid, title, tag, extra, None, why, "done", priority,
                     [{"at": _ago(minutes=30), "kind": "close",
                       "text": "Closed and reported to the owner."}])

    def surfaced_goal(spec, priority=2):
        gid, title, tag, extra, na, why = spec
        return _goal(gid, title, tag, extra, na, why, "blocked", priority,
                     [{"at": _ago(hours=2), "kind": "blocker", "text": "Blocked upstream."},
                      {"at": _ago(hours=2, minutes=-2), "kind": "report",
                       "text": "Surfaced to the owner."}],
                     blocked_on="Upstream fix the owner is chasing.")

    def open_goal(spec, priority=1):
        gid, title, tag, extra, na, why = spec
        return _goal(gid, title, tag, extra, na, why, "open", priority,
                     [{"at": _ago(days=1), "kind": "note", "text": "Queued."}])

    # drive (active): highest-priority active goal with a next_action, fresh.
    for i in range(n):
        a = TICK_GOALS[i]
        for off in (2, 3, 5, 7, 9, 11, 13):
            b = TICK_GOALS[(i + off) % n]
            if b[0] == a[0]:
                continue
            ledger = _ledger([active_goal(a, 1), active_goal(b, 2)])
            keep(ledger, [], "drive", want_goal=a[0])
    # drive: active (p1) outranks an open (p2) goal that is also drivable.
    for i in range(n):
        a = TICK_GOALS[i]
        b = TICK_GOALS[(i + 6) % n]
        ledger = _ledger([active_goal(a, 1), open_goal(b, 2)])
        keep(ledger, [], "drive", want_goal=a[0])

    # drive (open promotion): no active goal; an open goal with a next_action.
    for i in range(n):
        spec = TICK_GOALS[i]
        keep(_ledger([open_goal(spec, 1)]), [], "drive", want_goal=spec[0])
        for off in (4, 8):  # open promoted past a closed sibling
            keep(_ledger([closed_goal(TICK_GOALS[(i + off) % n], 2), open_goal(spec, 1)]),
                 [], "drive", want_goal=spec[0])

    # idle: done+closed and/or blocked+surfaced; and the empty ledger.
    for i in range(n):
        spec = TICK_GOALS[i]
        for off in (3, 5, 7, 9):  # closed + a surfaced-blocked sibling
            keep(_ledger([closed_goal(spec, 1),
                          surfaced_goal(TICK_GOALS[(i + off) % n], 2)]), [], "idle")
        keep(_ledger([closed_goal(spec, 1)]), [], "idle")          # lone closed
        keep(_ledger([surfaced_goal(spec, 1)]), [], "idle")        # lone surfaced-blocked
        keep(_ledger([closed_goal(spec, 1),
                      closed_goal(TICK_GOALS[(i + 6) % n], 2)]), [], "idle")  # two closed
    keep(_ledger([]), [], "idle")

    # clarify (thin / pronoun message, no ledger anchor).
    for i, frag in enumerate(THIN_CLARIFY):
        a, b = TICK_GOALS[i % n], TICK_GOALS[(i + 4) % n]
        ledger = _ledger([active_goal(a, 1), active_goal(b, 2)])
        inbox = [{"id": f"m-t{i}", "at": _ago(minutes=1), "text": frag}]
        keep(ledger, inbox, "clarify")

    # clarify (two goals match a shared tag equally).
    tie_templates = [
        "the {shared} is acting up again",
        "something's wrong with the {shared}",
        "the {shared} needs a look",
        "can we prioritize the {shared}",
        "the {shared} broke overnight",
        "let's get the {shared} sorted",
        "the {shared} is my top concern now",
        "spend some time on the {shared}",
    ]
    for i in range(n):
        a_spec = TICK_GOALS[i]
        b_spec = TICK_GOALS[(i + 6) % n]
        shared = "shared exporter"
        ga = _goal(a_spec[0], a_spec[1], shared, [shared], a_spec[4], a_spec[5],
                   "active", 1, [{"at": _ago(minutes=8), "kind": "progress", "text": "wip"}])
        gb = _goal(b_spec[0], b_spec[1], shared, [shared], b_spec[4], b_spec[5],
                   "active", 2, [{"at": _ago(minutes=8), "kind": "progress", "text": "wip"}])
        for k, tpl in enumerate(tie_templates):
            inbox = [{"id": f"m-e{i}{k}", "at": _ago(minutes=1),
                      "text": tpl.format(shared=shared)}]
            keep(_ledger([ga, gb]), inbox, "clarify")

    # clarify (vague live goal): the only live goal has no next_action.
    for i in range(n):
        gid, title, tag, extra, na, why = TICK_GOALS[i]
        vague = _goal(gid, title, tag, extra, None, why, "active", 1,
                      [{"at": _ago(minutes=8), "kind": "progress", "text": "wip"}])
        keep(_ledger([vague]), [], "clarify", want_goal=gid)

    return out


# --------------------------------------------------------------------------- #
# Target 3: owner-feedback elicitation. ask-one-short-question vs proceed.
# Construction rule (documented, deterministic): ASK when the answer is
# genuinely the owner's to give — a real fork between viable options, an
# unrecorded preference, or an irreversible/destructive step needing sign-off.
# PROCEED when the answer is already recorded, there is one obvious option, or
# the step is routine and reversible. The template family fixes the label.
# --------------------------------------------------------------------------- #
ELICIT_SYSTEM = (
    "You are Fin, foreman of a factory of coding agents, advancing a mission for "
    "its owner between their messages. Part of the job is judging WHEN to "
    "interrupt the owner for a decision and when to just proceed.\n\n"
    "Ask ONE short question only when the answer is genuinely the owner's to "
    "give: a real fork between viable options, a preference or scope choice the "
    "mission does not already record, or an irreversible or destructive step that "
    "needs their sign-off.\n\n"
    "Otherwise PROCEED: when the answer is already recorded (in the goals ledger, "
    "the registry, or an earlier decision), when there is exactly one obvious "
    "option, or when the step is routine and reversible. Never re-ask what is "
    "already known, and never stall a mission on a question you can answer "
    "yourself.\n\n"
    "## Output contract — STRICT\n\n"
    "Reply with EXACTLY one JSON object and nothing else. Schema:\n"
    '{"action": "ask" | "proceed",\n'
    ' "question": "<one short question, only when action is ask>",\n'
    ' "reason": "<one sentence>"}\n'
)

FLAVORS = [
    "deploy pipeline", "billing service", "auth module", "search index",
    "image uploader", "report generator", "payment webhook", "data migration",
    "cache layer", "email sender", "pdf exporter", "map renderer",
    "chat widget", "sync engine", "backup job", "license checker",
]

# (family, situation-template, question-template-or-None)
ELICIT_ASK = [
    ("fork", "The {f} can go two ways and both are reasonable; nothing on record says which the owner prefers.",
     "For the {f}, should I take option A or option B?"),
    ("fork", "There are two viable rollout strategies for the {f} and the mission doesn't record a preference.",
     "Roll the {f} out all at once or in stages?"),
    ("preference", "The {f} needs a name and the owner hasn't specified one anywhere.",
     "What should I name the {f}?"),
    ("preference", "Scope for the {f} is genuinely open — it could be minimal or full-featured, and nothing records the intent.",
     "How far should the {f} go for this pass — minimal or full?"),
    ("signoff", "Finishing the {f} means dropping the old table, which is irreversible and nothing authorizes it.",
     "The {f} step will irreversibly drop the old table — proceed?"),
    ("signoff", "The {f} change would force-push over shared history; that's destructive and unauthorized.",
     "This {f} change force-pushes over shared history — go ahead?"),
    ("signoff", "Completing the {f} deletes production data with no backup on record.",
     "The {f} step deletes production data with no backup — confirm?"),
    ("fork", "The {f} depends on a library choice the owner hasn't made, and both candidates are fine.",
     "Which library should the {f} use?"),
    ("preference", "The {f} needs a default that only the owner's taste can set, and none is recorded.",
     "What default should the {f} ship with?"),
    ("signoff", "The {f} rollback would wipe the staging database, which can't be undone and isn't sanctioned.",
     "Rolling back the {f} wipes staging — do you want that?"),
]
ELICIT_PROCEED = [
    ("recorded", "The owner already recorded that the {f} should use the standard config; that answers it.", None),
    ("recorded", "The ledger's goal for the {f} states the chosen approach, so the decision is already made.", None),
    ("recorded", "An earlier decision on record fixes the {f}'s format, so there's nothing new to ask.", None),
    ("obvious", "Only one option fits the {f} given the constraints already stated; the rest don't compile.", None),
    ("obvious", "There is exactly one supported path for the {f}, so no choice is actually open.", None),
    ("obvious", "The {f} has a single valid value here; anything else is out of range.", None),
    ("routine", "Running the {f}'s test suite is routine and fully reversible.", None),
    ("routine", "Regenerating the {f}'s lockfile is a routine, reversible step.", None),
    ("routine", "Formatting the {f}'s source with the project formatter is safe and reversible.", None),
    ("routine", "Rebuilding the {f} from clean is routine and changes nothing permanent.", None),
]


def gen_elicit():
    out = []
    for fi, flavor in enumerate(FLAVORS):
        for fam, sit, q in ELICIT_ASK:
            text = sit.format(f=flavor)
            label = {"action": "ask", "question": q.format(f=flavor),
                     "reason": f"a {fam} the owner must decide; ask one short question"}
            assistant = _stable(label, ("action", "question", "reason"))
            out.append(_record("elicit", "ask", text,
                               _example(ELICIT_SYSTEM, text, assistant)))
        for fam, sit, _q in ELICIT_PROCEED:
            text = sit.format(f=flavor)
            label = {"action": "proceed",
                     "reason": f"{fam}: the answer is already determined, so proceed"}
            assistant = _stable(label, ("action", "question", "reason"))
            out.append(_record("elicit", "proceed", text,
                               _example(ELICIT_SYSTEM, text, assistant)))
    return out


# --------------------------------------------------------------------------- #
# Target 4: app tool-use. request_input / notify / proceed. request_input uses
# FinAgentCore's real AgentToolSpec.requestInput schema; notify mirrors the
# daemon's /notify surface action. Construction rule: a login wall, a 2FA
# challenge, or a missing credential -> request_input (never guess, never
# stall). A milestone the owner needs -> notify. A routine unblocked step ->
# send_input / read_terminal, and do not notify noise.
# --------------------------------------------------------------------------- #
TOOLUSE_SYSTEM = (
    "You are Fin driving a coding agent in a live terminal, on the owner's "
    "behalf. Your tools:\n"
    "- read_terminal(lines?): read recent terminal output before answering "
    "anything about terminal state.\n"
    "- send_input(input, await_output_seconds?): type one command into the "
    "terminal and submit it.\n"
    "- request_input(question): ask the owner a question when you are blocked "
    "without their answer — a login wall, a 2FA or verification challenge, a "
    "missing credential, or a choice only they can make. It notifies them and "
    "returns; their next message is the answer.\n"
    "- notify(event, message): surface an alert to the owner's devices — a "
    "completed task, a blocker only they can clear, or a stall. Work quietly "
    "otherwise.\n"
    "- monitor(action, interval_seconds?): arm or disarm unattended monitoring.\n\n"
    "Rules: When you hit a login wall, a 2FA/verification challenge, or a "
    "missing credential, you MUST call request_input — never guess a credential "
    "and never stall silently. When work reaches something the owner needs to "
    "know (task complete, a blocker only they can clear, a repeated-failure "
    "stall), call notify. For routine, unblocked steps, just do the work with "
    "send_input or read_terminal and do not notify noise.\n\n"
    "## Output contract — STRICT\n\n"
    "Reply with EXACTLY one JSON object and nothing else. Schema:\n"
    '{"tool": "request_input" | "notify" | "send_input" | "read_terminal",\n'
    ' "arguments": { ... }}\n'
)

# (situation, question)
TOOL_REQUEST_INPUT = [
    ("The git push to the {f} repo is prompting for a username and password.",
     "The {f} push needs your git username and password — what should I use?"),
    ("The {f} deploy console is asking for the 6-digit 2FA code from your authenticator.",
     "What's the current 6-digit 2FA code for the {f} console?"),
    ("The {f} needs an API secret key and none is set in the environment.",
     "I need the {f} API secret key — can you provide it?"),
    ("The {f} sign-in page loaded a login wall and I have no stored credentials for it.",
     "The {f} needs a login — what credentials should I use?"),
    ("The {f} step requires a one-time verification code sent to your phone.",
     "What's the verification code the {f} just texted you?"),
    ("The {f} vault is locked and asking for the master passphrase.",
     "What's the {f} vault passphrase?"),
    ("The {f} SSO redirect needs you to approve the login on your device.",
     "Can you approve the {f} SSO prompt on your phone, then tell me when it's done?"),
    ("The {f} database connection is rejected: it wants a password not in the config.",
     "What's the {f} database password?"),
]
# (situation, event, message)
TOOL_NOTIFY = [
    ("The full test suite passed and the {f} build shipped to the beta channel.",
     "task-complete", "The {f} is done: tests green and the build is on the beta channel."),
    ("The {f} migration finished cleanly and the row counts match.",
     "task-complete", "The {f} migration completed and the counts reconcile."),
    ("The {f} signing certificate expired and only the owner can renew it in the portal.",
     "blocker", "The {f} is blocked: the signing certificate expired and needs your renewal."),
    ("A required {f} account is suspended and support will only talk to the owner.",
     "blocker", "The {f} is blocked: the account is suspended and support needs you."),
    ("The {f} build has failed three times in a row with the identical error.",
     "stall", "The {f} is stalled: three identical build failures in a row — needs a look."),
    ("The {f} job has made no progress for well over half an hour on the same step.",
     "stall", "The {f} looks stalled: no progress for over 30 minutes on one step."),
]
# (situation, tool, args)
TOOL_PROCEED = [
    ("The owner asked me to run the {f} unit tests.",
     "send_input", {"input": "npm test"}),
    ("The owner asked me to check the {f} git status.",
     "send_input", {"input": "git status"}),
    ("The owner asked me to install the {f} dependencies.",
     "send_input", {"input": "npm install"}),
    ("The owner asked me to format the {f} source.",
     "send_input", {"input": "make fmt"}),
    ("The owner asked me to build the {f} from clean.",
     "send_input", {"input": "make clean && make"}),
    ("The owner asked me to show the {f} git log.",
     "send_input", {"input": "git log --oneline -20"}),
    ("I need to see what the last {f} command printed before answering.",
     "read_terminal", {"lines": 40}),
    ("The owner asked whether the {f} build finished; I must read the terminal first.",
     "read_terminal", {"lines": 60}),
    ("The owner asked what the {f} test run reported; check the terminal.",
     "read_terminal", {"lines": 80}),
    ("Before summarizing the {f} output I should read the recent terminal lines.",
     "read_terminal", {"lines": 50}),
]


def gen_tooluse():
    out = []
    for flavor in FLAVORS:
        for sit, q in TOOL_REQUEST_INPUT:
            text = sit.format(f=flavor)
            label = {"tool": "request_input",
                     "arguments": {"question": q.format(f=flavor)}}
            assistant = json.dumps(label, ensure_ascii=False)
            out.append(_record("tooluse", "request_input", text,
                               _example(TOOLUSE_SYSTEM, text, assistant)))
        for sit, event, msg in TOOL_NOTIFY:
            text = sit.format(f=flavor)
            label = {"tool": "notify",
                     "arguments": {"event": event, "message": msg.format(f=flavor)}}
            assistant = json.dumps(label, ensure_ascii=False)
            out.append(_record("tooluse", "notify", text,
                               _example(TOOLUSE_SYSTEM, text, assistant)))
        for sit, tool, args in TOOL_PROCEED:
            text = sit.format(f=flavor)
            label = {"tool": tool, "arguments": args}
            assistant = json.dumps(label, ensure_ascii=False)
            out.append(_record("tooluse", tool, text,
                               _example(TOOLUSE_SYSTEM, text, assistant)))
    return out


# --------------------------------------------------------------------------- #
# Leakage gate.
# --------------------------------------------------------------------------- #
def _normalize(s: str) -> str:
    s = re.sub(r"[^a-z0-9]+", " ", s.lower())
    return " ".join(s.split())


def _load_eval_inputs():
    """Every eval scenario input: tmux-routing queries + goals-ledger inbox
    message texts. These are the strings training inputs must never reproduce."""
    raw = []
    routing = json.loads((ROUTING_DIR / "scenarios.json").read_text())
    for s in routing["scenarios"]:
        raw.append(s["query"])
    ledger = json.loads((LEDGER_DIR / "scenarios.json").read_text())
    for s in ledger["scenarios"]:
        for m in s.get("inbox", []):
            raw.append(m["text"])
    return raw


def _leak_verdict(text, eval_raw_set, eval_norms):
    """Return (kind, matched) where kind in {None, 'exact', 'near'}."""
    if text in eval_raw_set:
        return "exact", text
    nt = _normalize(text)
    if not nt:
        return None, None
    ntoks = set(nt.split())
    for en in eval_norms:
        if en == nt:
            return "near", en
        etoks = set(en.split())
        if len(ntoks) >= 4 and len(etoks) >= 4 and (nt in en or en in nt):
            return "near", en
        if ntoks and etoks:
            j = len(ntoks & etoks) / len(ntoks | etoks)
            if j >= JACCARD_NEAR:
                return "near", en
    return None, None


# --------------------------------------------------------------------------- #
# Assembly.
# --------------------------------------------------------------------------- #
# Per-(target, decision) caps for a balanced set.
CAPS = {
    ("routing", "route"): 230,
    ("routing", "start"): 230,
    ("routing", "clarify"): 230,
    ("routing", "refuse"): 200,
    ("ledger", "ingest"): 210,
    ("ledger", "drive"): 210,
    ("ledger", "report"): 210,
    ("ledger", "idle"): 210,
    ("ledger", "clarify"): 210,
    ("elicit", "ask"): 160,
    ("elicit", "proceed"): 160,
    ("tooluse", "request_input"): 130,
    ("tooluse", "notify"): 100,
    ("tooluse", "send_input"): 100,
    ("tooluse", "read_terminal"): 70,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--seed", type=int, default=20260905)
    args = parser.parse_args()

    out = args.out or (REPO / "datasets" /
                       f"sft-train-{datetime.date.today().isoformat()}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)

    # 1. Generate all candidates.
    candidates = []
    candidates += gen_routing()
    candidates += gen_ledger()
    candidates += gen_elicit()
    candidates += gen_tooluse()

    # 2. Dedupe by full example line (deterministic order).
    seen = set()
    deduped = []
    for rec in candidates:
        if rec["line"] in seen:
            continue
        seen.add(rec["line"])
        deduped.append(rec)

    # 3. Leakage gate: drop any training input that matches an eval input.
    eval_raw = _load_eval_inputs()
    eval_raw_set = set(eval_raw)
    eval_norms = sorted({_normalize(s) for s in eval_raw if _normalize(s)})
    dropped = Counter()
    dropped_by_reason = Counter()
    surviving = []
    for rec in deduped:
        if not rec["input_text"]:
            surviving.append(rec)
            continue
        kind, _m = _leak_verdict(rec["input_text"], eval_raw_set, eval_norms)
        if kind is None:
            surviving.append(rec)
        else:
            dropped[(rec["target"], rec["decision"])] += 1
            dropped_by_reason[kind] += 1

    # 4. Balance: sort each (target, decision) group deterministically, cap.
    groups = defaultdict(list)
    for rec in surviving:
        groups[(rec["target"], rec["decision"])].append(rec)
    kept = []
    for key in sorted(groups):
        grp = sorted(groups[key], key=lambda r: r["line"])
        cap = CAPS.get(key, len(grp))
        kept.extend(grp[:cap])

    # 5. Re-verify the kept set has ZERO leakage (assertion).
    residual_exact = residual_near = 0
    for rec in kept:
        if not rec["input_text"]:
            continue
        kind, _m = _leak_verdict(rec["input_text"], eval_raw_set, eval_norms)
        if kind == "exact":
            residual_exact += 1
        elif kind == "near":
            residual_near += 1
    assert residual_exact == 0 and residual_near == 0, (
        f"LEAKAGE GATE FAILED: {residual_exact} exact, {residual_near} near-dup "
        "training inputs survived — refusing to write a leaky dataset."
    )

    # 6. Deterministic shuffle so classes interleave, then write.
    rng = random.Random(args.seed)
    rng.shuffle(kept)
    with out.open("w", encoding="utf-8") as f:
        for rec in kept:
            f.write(rec["line"] + "\n")

    # 7. Report.
    by_td = Counter((r["target"], r["decision"]) for r in kept)
    by_target = Counter(r["target"] for r in kept)
    digest = hashlib.sha256(out.read_bytes()).hexdigest()

    print(f"wrote {len(kept)} examples -> {out}")
    print(f"sha256: {digest}")
    print("\ncounts by target/decision:")
    for (target, decision) in sorted(by_td):
        print(f"  {target:9s} {decision:14s} {by_td[(target, decision)]}")
    print("by target:")
    for target in sorted(by_target):
        print(f"  {target:9s} {by_target[target]}")

    print("\nLEAKAGE CHECK vs eval inputs "
          f"({len(eval_raw_set)} unique eval strings: tmux-routing queries + "
          "goals-ledger inbox texts):")
    print(f"  candidates generated: {len(candidates)}  (deduped: {len(deduped)})")
    total_dropped = sum(dropped.values())
    print(f"  dropped for overlap: {total_dropped}  "
          f"(exact={dropped_by_reason['exact']}, near-dup={dropped_by_reason['near']})")
    if dropped:
        for key in sorted(dropped):
            print(f"    dropped {key[0]}/{key[1]}: {dropped[key]}")
    print(f"  RESULT: PASS — {residual_exact} exact-match, {residual_near} "
          f"near-duplicate in the {len(kept)} kept training inputs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
