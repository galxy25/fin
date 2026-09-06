#!/usr/bin/env python3
"""Mechanical floor for content/ — the checks a human should never have to do by hand.

`content/README.md` §3 says the claim rule is "mechanical on purpose". Before this
file existed, every gate in the pipeline was a markdown checkbox an agent ticked
about its own work, and the seed draft shipped two ticked boxes that were false.
This is what makes the checkable half actually checked.

It walks BOTH directions:

  rows -> piece   every ledger row's exact sentence is present in the piece it names
  piece -> rows   every score in a piece is covered by a row it declares, every
                  results table names the rows that cover it, no sentence the
                  ledger *rejected* appears in a piece, and no banned phrase or
                  infrastructure name does either

The second direction is the one that enforces THE CLAIM RULE. It was missing
until 2026-09-06, and an injected `published/` piece asserting a fabricated
accuracy number, a ledger-rejected interlock sentence, two banned phrases and a
real tailnet name passed this checker with `claims: []` and exit 0.

What it still CANNOT do is open an artifact and read it — the part that matters
most. This is a floor, not the audit. It exits non-zero on any defect.

    python3 content/check-claims.py [--content-dir content] [--labbook-dir DIR]

No dependencies, no network, no repo history: it reads this directory (and, if
it exists, the lab-book directory, only to resolve `labbook:` ids).
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

STAGES = ("drafts", "review", "published")
STATUS_ORDER = ("proposed", "verified", "approved", "published", "stale", "retired", "rejected")
REVIEW_OK = {"verified", "approved", "published"}
KINDS = {"performance", "capability", "availability", "roadmap", "method", "framing"}
BUILD_RE = re.compile(r"\bbuild\b[^|]{0,40}?\d", re.I)
DATE_RE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
SPLIT_RE = re.compile(r"(?<!\\)\|")
SCORE_RE = re.compile(r"\b\d{1,4}/\d{1,4}\b|\b\d{1,3}(?:\.\d+)?%")
# Everything below this heading is process apparatus — the ledger echo and the
# pre-flight — not copy a reader receives. It is not scanned for uncovered
# numbers, and it must not carry a claim the body does not also make.
APPENDIX_RE = re.compile(r"^##\s+Claims in this piece", re.M)
TABLE_MARKER_RE = re.compile(r"<!--\s*table-claims:\s*([^>]*?)-->")
QUOTED_RE = re.compile(r'"([^"\n]{12,400})"')

# STYLE.md §2. A piece containing one of these is either sloppy or is quoting the
# rule; the window test below tells them apart.
BANNED_PHRASES = (
    "ai-powered", "ai-driven", "powered by ai", "blazing fast", "seamless",
    "effortless", "revolutionary", "magical", "world-class", "state of the art",
    "unmatched", "enterprise-grade",
)

# STYLE.md §2 and README.md §6. The one written exemption is the loopback
# endpoint and the model identifier in reproduction instructions, and neither
# matches anything here.
INFRA_PATTERNS = (
    (r"\b\d{12}\b", "an AWS account id"),
    (r"\b(?:AKIA|ASIA)[0-9A-Z]{8,}", "an AWS access key id"),
    (r"\barn:aws:", "an ARN"),
    (r"\bs3://", "an S3 URI"),
    (r"\b[a-z0-9][a-z0-9-]*\.ts\.net\b", "a tailnet hostname"),
    (r"\bfin-model-factory-\d+", "a bucket name"),
    (r"\bi-[0-9a-f]{8,}\b", "an EC2 instance id"),
    (r"\b(?:ec2|dynamodb|sqs)\b", "an infrastructure product name"),
)

# STYLE.md §3 names these as sentences never to write: they turn a decision into
# a mechanical guarantee. CB-1 and CB-7 are the rejected rows; these are the
# fragments, because the ledger's verbatim check misses a reworded paste.
INTERLOCK_PHRASES = (
    "only touches sessions you register",
    "cannot type into an unregistered",
    "can't type into an unregistered",
    "will never touch an unregistered",
    "will not touch an unregistered",
)

# An availability claim is the kind most often written by accident (ledger §2).
# A piece that says one of these and declares no `availability` row has skipped
# the build number.
AVAILABILITY_PHRASES = (
    "available today", "available now", "shipping today", "out now",
    "you can now", "ships today", "in the app today",
)

EXCUSE_WORDS = ("never", "bad:", "do not", "don't", "forbid", "rejected", "avoid", "banned", "not say")


def norm(text: str) -> str:
    """Whitespace-insensitive form, so a sentence wrapped across lines still matches."""
    return re.sub(r"\s+", " ", text.replace("\\|", "|")).strip()


def excused(haystack: str, at: int, span: int) -> bool:
    """True when a hit sits inside a clause telling the reader not to use it."""
    window = haystack[max(0, at - 220): at + span + 220].lower()
    return any(w in window for w in EXCUSE_WORDS)


def parse_front_matter(text: str) -> dict:
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    out: dict = {}
    for line in text[3:end].splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, raw = line.partition(":")
        raw = raw.strip()
        if raw.startswith("["):
            close = raw.find("]")
            body = raw[1:close] if close != -1 else raw[1:]
            out[key.strip()] = [v.strip().strip('"').strip("'") for v in body.split(",") if v.strip()]
        elif raw[:1] in ('"', "'"):
            quote = raw[0]
            close = raw.find(quote, 1)
            out[key.strip()] = raw[1:close] if close != -1 else raw[1:]
        else:
            out[key.strip()] = raw.split("  #")[0].split("\t#")[0].strip()
    return out


def body_lines(text: str) -> list[str]:
    """The piece minus its front matter and minus fenced code blocks.

    Reproduction commands are not prose and are not claims; the written
    exemption in `STYLE.md` §2 lives here, in code.
    """
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            text = text[end + 4:]
    out, in_fence = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return out


def parse_ledger(path: pathlib.Path) -> list[dict]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in SPLIT_RE.split(stripped)[1:-1]]
        if len(cells) != 9:
            continue
        if not re.fullmatch(r"[A-Z][A-Z0-9]*-[A-Za-z0-9-]+", cells[0]):
            continue
        rows.append(
            {
                "id": cells[0],
                "piece": cells[1],
                "claim": cells[2].strip().strip('"').strip("“”"),
                "kind": cells[3].strip("*` "),
                "evidence": cells[4],
                "verified_by": cells[5],
                "verified": cells[6],
                "status": cells[7].strip("*` ").lower(),
                "recheck": cells[8],
            }
        )
    return rows


def check_rows(rows: list[dict], problems: list[str]) -> dict[str, dict]:
    by_id: dict[str, dict] = {}
    for row in rows:
        if row["id"] in by_id:
            problems.append(f"claims-ledger.md: duplicate id {row['id']} — ids are never reused (§1)")
        by_id[row["id"]] = row

    for row in rows:
        rid, kind, status = row["id"], row["kind"], row["status"]
        if kind and kind not in KINDS and not row["piece"].startswith("*"):
            problems.append(f"{rid}: kind '{kind}' is not one of {sorted(KINDS)} (§2)")
        if status and status not in STATUS_ORDER:
            problems.append(f"{rid}: status '{status}' is not in the lifecycle (§3)")
        if kind == "performance" and status not in {"rejected", "retired"}:
            if not row["recheck"] or row["recheck"].strip().lower() in {"n/a", "-", "—", "none"}:
                problems.append(f"{rid}: performance row with no falsification condition is malformed (§2)")
        if kind == "availability" and status not in {"rejected", "retired"}:
            if not BUILD_RE.search(row["evidence"]):
                problems.append(f"{rid}: availability row's evidence names no build number (§2)")
        if kind == "framing" and status not in {"rejected", "retired"}:
            # A framing row records WHO directed the words and WHEN. It never
            # establishes a mechanism, so it must say which of its own words
            # would need a capability row before they can be asserted.
            if not DATE_RE.search(row["evidence"]):
                problems.append(f"{rid}: framing row's evidence names no dated directive (§2)")
            if "capability row" not in row["recheck"].lower():
                problems.append(
                    f"{rid}: framing row must name, in re-check, the words in it that "
                    f"have no capability row (§2) — a framing row is not evidence of a mechanism"
                )
        if status in {"verified", "approved", "published"}:
            if not DATE_RE.search(row["verified"]):
                problems.append(f"{rid}: status '{status}' with no ISO verification date (§1)")
            if not row["verified_by"] or row["verified_by"] in {"-", "—"}:
                problems.append(f"{rid}: status '{status}' with no verifier (§1)")
    return by_id


def check_approval(rel: str, stage: str, fm: dict, text: str, problems: list[str]) -> None:
    """README §4. Approval is the highest-stakes fact in the pipeline.

    An agent never fills `approved_by`. The checker cannot tell a real quote from
    a typed one — so it enforces the shape, refuses the field in `drafts/`, and
    refuses the contradiction of a piece that calls itself approved while its own
    pre-flight says the approval has not happened.
    """
    status = (fm.get("status") or "").strip()
    approved = (fm.get("approved_by") or "").strip()

    if stage == "drafts" and approved:
        problems.append(
            f"{rel}: a piece in drafts/ has approved_by filled in — an agent never fills "
            f"that field (README §4), and nothing in drafts/ has been approved"
        )

    if status in {"approved", "published"} or stage == "published":
        if not approved:
            problems.append(f"{rel}: status '{status}' with an empty approved_by (README §4)")
        elif not (DATE_RE.search(approved) and ('"' in approved or "'" in approved or "“" in approved)):
            problems.append(
                f"{rel}: approved_by must carry the quoted words, the date, and where they were said "
                f"(README §4); a bare name is treated as empty"
            )

    # The inverse of the ticked-false-box check: a piece cannot call itself
    # approved while carrying an UNTICKED box saying the approval has not happened.
    for box in re.findall(r"^\s*-\s*\[ \][^\n]*(?:\n(?!\s*-\s*\[)[^\n]*)*", text, re.M):
        flat = norm(box)
        if status in {"approved", "published"} and re.search(r"approv", flat, re.I):
            problems.append(
                f"{rel}: status '{status}' while an unticked pre-flight box says the approval "
                f"has not happened: {flat[:90]}"
            )
        if stage == "published":
            problems.append(
                f"{rel}: in published/ with an unticked pre-flight box — everything that had to "
                f"be true before it went out is either true or the piece should not have gone "
                f"out: {flat[:90]}"
            )


def check_piece_to_rows(
    rel: str, fm: dict, text: str, declared: list[str], by_id: dict[str, dict],
    rejected: list[dict], problems: list[str],
) -> None:
    """THE CLAIM RULE, in the direction the checker used to be blind in.

    Rows -> piece proves the audited sentence is the shipped one. It proves
    nothing about a sentence with no row. These are the claim shapes a machine
    can actually recognize: scores, results tables, sentences the ledger has
    already refused, banned phrasing, and infrastructure names.
    """
    lines = body_lines(text)
    covered = " ".join(norm(by_id[c]["claim"]) for c in declared if c in by_id)
    flat = norm("\n".join(lines))
    low = flat.lower()

    # The appendix (ledger echo + pre-flight) is process apparatus, not copy.
    joined = "\n".join(lines)
    cut = APPENDIX_RE.search(joined)
    if cut:
        lines = joined[: cut.start()].splitlines()

    # 1. Every score in prose is covered by a row this piece declares.
    for line in lines:
        if line.lstrip().startswith("|") or TABLE_MARKER_RE.search(line):
            continue
        for tok in SCORE_RE.findall(line):
            if tok not in covered:
                problems.append(
                    f"{rel}: the score {tok} appears in prose but in no ledger row this piece "
                    f"declares — THE CLAIM RULE (README §3). Row it, or cut the number. "
                    f"Line: {norm(line)[:90]}"
                )

    # 2. Every results table names the rows that cover its cells.
    i = 0
    while i < len(lines):
        if not lines[i].lstrip().startswith("|"):
            i += 1
            continue
        j = i
        while j < len(lines) and lines[j].lstrip().startswith("|"):
            j += 1
        block = lines[i:j]
        if any(SCORE_RE.search(b) for b in block):
            marker = None
            for k in range(max(0, i - 4), i):
                found = TABLE_MARKER_RE.search(lines[k])
                if found:
                    marker = found
            if not marker:
                problems.append(
                    f"{rel}: a results table carries scores with no `<!-- table-claims: ... -->` "
                    f"marker above it (claims-ledger.md §4 step 5) — a table is the easiest place "
                    f"for an unrowed number to hide. First row: {norm(block[0])[:80]}"
                )
            else:
                for cid in [c.strip() for c in marker.group(1).replace(",", " ").split() if c.strip()]:
                    if cid not in declared:
                        problems.append(
                            f"{rel}: table-claims names {cid}, which this piece does not declare "
                            f"in its `claims:` list"
                        )
        i = j

    # 3. No sentence the ledger refused may appear in a piece.
    for row in rejected:
        claim = norm(row["claim"]).rstrip(".").strip()
        if len(claim.split()) < 6:
            continue
        at = flat.find(claim)
        if at != -1 and not excused(flat, at, len(claim)):
            problems.append(
                f"{rel}: contains {row['id']}, a sentence the ledger REJECTED, with nothing "
                f"marking it as refused — rejected copy is the copy most likely to be pasted "
                f"forward: {claim[:80]}"
            )

    # 4. STYLE.md §2's banned phrasing, §3's interlock phrasing, and availability
    #    language with no availability row behind it.
    for phrase in BANNED_PHRASES:
        at = low.find(phrase)
        if at != -1 and not excused(low, at, len(phrase)):
            problems.append(f"{rel}: contains the banned phrase '{phrase}' (STYLE.md §2)")

    for phrase in INTERLOCK_PHRASES:
        at = low.find(phrase)
        if at != -1 and not excused(low, at, len(phrase)):
            problems.append(
                f"{rel}: describes a guardrail as an interlock — '{phrase}' (STYLE.md §3, "
                f"ledger rows CB-1 and CB-7). Nothing in the send path on `main` enforces it; "
                f"write it as a decision Fin makes"
            )

    has_availability = any(by_id.get(c, {}).get("kind") == "availability" for c in declared)
    if not has_availability:
        for phrase in AVAILABILITY_PHRASES:
            at = low.find(phrase)
            if at != -1 and not excused(low, at, len(phrase)):
                problems.append(
                    f"{rel}: says '{phrase}' but declares no `availability` row — an availability "
                    f"claim needs a build number in App Store Connect (ledger §2)"
                )

    # 5. Infrastructure names. STYLE.md §2's one written exemption is the
    #    loopback endpoint and model identifier in reproduction commands, and
    #    code fences are already stripped out above.
    for pattern, what in INFRA_PATTERNS:
        found = re.search(pattern, flat, re.I)
        if found and not excused(flat, found.start(), len(found.group(0))):
            problems.append(
                f"{rel}: reader-facing text contains {what} ({found.group(0)!r}) — "
                f"infrastructure names never appear in published copy (README §6, STYLE.md §2)"
            )


def check_style_prescribed(style_text: str, rows: list[dict], problems: list[str]) -> None:
    """Every prescribed sentence in STYLE.md is a claim before it is copied.

    `claims-ledger.md` §7. STYLE.md §1's "say" column and §3 exist to be lifted
    verbatim, so a quoted sentence in either needs a `CB` row. The checker's
    reach is quoted spans of six words or more; the rule in §7 is wider and
    covers bolded prescribed sentences too, which a human still has to check.
    """
    cb_claims = {norm(r["claim"]).rstrip(".").strip() for r in rows if r["id"].startswith("CB-")}
    # §1 and §3 only. §2 is a list of phrasing to avoid and quotes bad examples
    # on purpose; §4's quotes are worked examples of numbers, governed by rows in
    # the live ledger rather than by CB rows.
    bounds = [
        ("## 1. What to call things", "## 2. Words to avoid"),
        ("## 3. Describing the agent honestly", "## 4. How to write a number"),
    ]
    region = ""
    for head, tail in bounds:
        start, end = style_text.find(head), style_text.find(tail)
        if start == -1 or end == -1 or end < start:
            problems.append(f"STYLE.md: cannot find the section {head!r} — the prescribed-copy scan did not run")
            return
        region += style_text[start:end] + "\n"
    for match in QUOTED_RE.finditer(region):
        span = norm(match.group(1)).rstrip(".").strip()
        if len(span.split()) < 6:
            continue
        if span not in cb_claims and not any(span in c or c in span for c in cb_claims):
            problems.append(
                f"STYLE.md: the prescribed sentence \"{span[:70]}\" has no CB row in "
                f"claims-ledger.md §7 — a sentence written to be copied is a claim "
                f"before it is copied"
            )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--content-dir", default=str(pathlib.Path(__file__).resolve().parent))
    ap.add_argument(
        "--labbook-dir",
        default=None,
        help="where `labbook:` ids are resolved (default: ../scripts/model-factory/labbook)",
    )
    args = ap.parse_args()
    root = pathlib.Path(args.content_dir).resolve()
    labbook = pathlib.Path(args.labbook_dir).resolve() if args.labbook_dir else (
        root.parent / "scripts" / "model-factory" / "labbook"
    )
    ledger_path = root / "claims-ledger.md"

    problems: list[str] = []
    notes: list[str] = []

    if not ledger_path.exists():
        print(f"FAIL: no claims ledger at {ledger_path}")
        return 1

    rows = parse_ledger(ledger_path)
    by_id = check_rows(rows, problems)
    live_rows = [r for r in rows if r["piece"].startswith(STAGES)]
    rejected = [r for r in rows if r["status"] == "rejected"]

    pieces: list[tuple[pathlib.Path, dict, str]] = []
    for stage in STAGES:
        for path in sorted((root / stage).glob("*.md")):
            if path.name == "README.md":
                continue
            text = path.read_text(encoding="utf-8")
            pieces.append((path, parse_front_matter(text), text))

    for path, fm, text in pieces:
        rel = f"{path.parent.name}/{path.name}"
        stage = path.parent.name
        status = (fm.get("status") or "").strip()
        expected = {"drafts": {"draft"}, "review": {"review", "approved"}, "published": {"published"}}[stage]
        if status not in expected:
            problems.append(f"{rel}: status '{status}' disagrees with its directory (README §2: the directory wins)")

        declared = list(fm.get("claims") or [])
        for cid in declared:
            if cid not in by_id:
                problems.append(f"{rel}: front matter claims {cid}, which has no ledger row (README §3)")

        for row in [r for r in live_rows if r["piece"] == rel]:
            if row["id"] not in declared:
                problems.append(f"{rel}: ledger row {row['id']} names this piece but is not in its claims: list")

        haystack = norm(text)
        for cid in declared:
            row = by_id.get(cid)
            if not row:
                continue
            if row["piece"] != rel:
                problems.append(f"{rel}: claims {cid}, but that row's piece column says {row['piece']}")
                continue
            claim = norm(row["claim"])
            if not claim:
                problems.append(f"{cid}: empty claim text")
            elif claim not in haystack:
                problems.append(
                    f"{cid}: claim text does not appear verbatim in {rel} — "
                    f"the ledger is auditing a sentence the piece does not contain "
                    f"(starts: {claim[:70]!r})"
                )

        check_piece_to_rows(rel, fm, text, declared, by_id, rejected, problems)
        check_approval(rel, stage, fm, text, problems)

        if stage == "review":
            for cid in declared:
                row = by_id.get(cid)
                if row and row["status"] not in REVIEW_OK:
                    problems.append(f"{rel}: in review/ with {cid} at status '{row['status']}' (README §2)")

        if stage in {"review", "published"}:
            kind = (fm.get("kind") or "").strip()
            ids = list(fm.get("labbook") or [])
            if kind == "scientific-result" and not ids and stage == "published":
                problems.append(f"{rel}: a published scientific result cites no lab-book entry (README §1)")
            if ids:
                if not labbook.exists():
                    msg = f"{rel}: cites lab-book entries {ids} but no lab book exists at {labbook}"
                    (problems if stage == "published" else notes).append(msg)
                else:
                    corpus = "\n".join(
                        p.read_text(encoding="utf-8", errors="replace")
                        for p in sorted(labbook.rglob("*.md"))
                    ) + "\n".join(p.name for p in sorted(labbook.rglob("*")))
                    for eid in ids:
                        if eid not in corpus:
                            problems.append(f"{rel}: lab-book id {eid} does not resolve in {labbook}")
            if kind == "release-note" and not re.search(r"\d", (fm.get("build") or "")):
                problems.append(
                    f"{rel}: a release note in {stage}/ with no build number in `build:` — "
                    f"the text that shipped cannot be reconciled with what went out"
                )

        if stage == "published" and not (fm.get("published_at") or "").strip():
            problems.append(f"{rel}: published with an empty published_at (README §2)")

        for box in re.findall(r"^\s*-\s*\[x\][^\n]*(?:\n(?!\s*-\s*\[)[^\n]*)*", text, re.M):
            if "NOT DONE" in box or "PENDING" in box:
                problems.append(f"{rel}: a ticked pre-flight box says NOT DONE / PENDING: {norm(box)[:80]}")

        if stage in {"review", "published"} and "PENDING" in text:
            notes.append(f"{rel}: contains the word PENDING while in {stage}/ — check it is not a blocker")

    # Copy blocks (§7): sentences written to be lifted verbatim out of STYLE.md.
    style_path = root / "STYLE.md"
    if style_path.exists():
        style_raw = style_path.read_text(encoding="utf-8")
        style = norm(style_raw)
        check_style_prescribed(style_raw, rows, problems)
        for row in rows:
            if not row["id"].startswith("CB-"):
                continue
            claim = norm(row["claim"])
            core = claim.rstrip(".").strip()
            if row["status"] in REVIEW_OK and claim not in style and core not in style:
                problems.append(
                    f"{row['id']}: verified copy block is not in STYLE.md verbatim — "
                    f"prescribed copy and the ledger have drifted apart"
                )
            if row["status"] == "rejected" and core and core in style:
                # A rejected sentence may still appear in STYLE.md, but ONLY inside a
                # clause telling writers not to use it. Anywhere else it reads as copy.
                if not excused(style, style.index(core), len(core)):
                    problems.append(
                        f"{row['id']}: rejected copy block sits in STYLE.md with nothing "
                        f"marking it as forbidden — a sentence the ledger refused is where "
                        f"writers copy from"
                    )

    known_pieces = {f"{p.parent.name}/{p.name}" for p, _, _ in pieces}
    for row in live_rows:
        if row["piece"] not in known_pieces:
            problems.append(f"{row['id']}: piece '{row['piece']}' does not exist")

    for note in notes:
        print(f"note: {note}")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for prob in problems:
            print(f"  FAIL {prob}")
        return 1
    print(
        f"ok — {len(rows)} ledger rows, {len(pieces)} piece(s), "
        f"{sum(len(parse_front_matter(t).get('claims') or []) for _, _, t in pieces)} claim references, "
        "all sentences present verbatim, every score rowed"
    )
    print("This is the floor, not the audit: no artifact was opened. A human still verifies evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
