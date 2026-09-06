#!/usr/bin/env python3
"""Mechanical floor for content/ — the checks a human should never have to do by hand.

`content/README.md` §3 says the claim rule is "mechanical on purpose". Before this
file existed, every gate in the pipeline was a markdown checkbox an agent ticked
about its own work, and the seed draft shipped two ticked boxes that were false.
This is what makes the checkable half actually checked.

What it CANNOT do is open an artifact and read it — the part that matters most.
This is a floor, not the audit. It exits non-zero on any defect.

    python3 content/check-claims.py [--content-dir content]

No dependencies, no network, no repo history: it reads this directory only.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

STAGES = ("drafts", "review", "published")
STATUS_ORDER = ("proposed", "verified", "approved", "published", "stale", "retired", "rejected")
REVIEW_OK = {"verified", "approved", "published"}
KINDS = {"performance", "capability", "availability", "roadmap", "method"}
BUILD_RE = re.compile(r"\bbuild\b[^|]{0,40}?\d", re.I)
DATE_RE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
SPLIT_RE = re.compile(r"(?<!\\)\|")


def norm(text: str) -> str:
    """Whitespace-insensitive form, so a sentence wrapped across lines still matches."""
    return re.sub(r"\s+", " ", text.replace("\\|", "|")).strip()


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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--content-dir", default=str(pathlib.Path(__file__).resolve().parent))
    args = ap.parse_args()
    root = pathlib.Path(args.content_dir).resolve()
    ledger_path = root / "claims-ledger.md"

    problems: list[str] = []
    notes: list[str] = []

    if not ledger_path.exists():
        print(f"FAIL: no claims ledger at {ledger_path}")
        return 1

    rows = parse_ledger(ledger_path)
    by_id: dict[str, dict] = {}
    for row in rows:
        if row["id"] in by_id:
            problems.append(f"claims-ledger.md: duplicate id {row['id']} — ids are never reused (§1)")
        by_id[row["id"]] = row

    # Rows that name a live piece must be checkable against it.
    live_rows = [r for r in rows if r["piece"].startswith(STAGES)]

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
        if status in {"verified", "approved", "published"}:
            if not DATE_RE.search(row["verified"]):
                problems.append(f"{rid}: status '{status}' with no ISO verification date (§1)")
            if not row["verified_by"] or row["verified_by"] in {"-", "—"}:
                problems.append(f"{rid}: status '{status}' with no verifier (§1)")

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

        rows_for_piece = [r for r in live_rows if r["piece"] == rel]
        for row in rows_for_piece:
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

        if stage == "review":
            for cid in declared:
                row = by_id.get(cid)
                if row and row["status"] not in REVIEW_OK:
                    problems.append(f"{rel}: in review/ with {cid} at status '{row['status']}' (README §2)")

        if stage == "published":
            approved = (fm.get("approved_by") or "").strip()
            if not approved:
                problems.append(f"{rel}: published with an empty approved_by (README §4)")
            elif not (DATE_RE.search(approved) and ('"' in approved or "'" in approved or "“" in approved)):
                problems.append(
                    f"{rel}: approved_by must carry the quoted words, the date, and where they were said "
                    f"(README §4); a bare name is treated as empty"
                )
            if not (fm.get("published_at") or "").strip():
                problems.append(f"{rel}: published with an empty published_at (README §2)")
            if not (fm.get("labbook") or []) and (fm.get("kind") or "") == "scientific-result":
                problems.append(f"{rel}: a published scientific result cites no lab-book entry (README §1)")

        for box in re.findall(r"^\s*-\s*\[x\][^\n]*", text, re.M):
            if "NOT DONE" in box or "PENDING" in box:
                problems.append(f"{rel}: a ticked pre-flight box says NOT DONE / PENDING: {box.strip()[:80]}")

        if stage in {"review", "published"} and "PENDING" in text:
            notes.append(f"{rel}: contains the word PENDING while in {stage}/ — check it is not a blocker")

    # Copy blocks (§7): sentences written to be lifted verbatim out of STYLE.md.
    # They are the most-copied text here and were once the least-audited, so a
    # `verified` CB row must still match the words STYLE.md actually carries.
    style_path = root / "STYLE.md"
    if style_path.exists():
        style = norm(style_path.read_text(encoding="utf-8"))
        for row in rows:
            if not row["id"].startswith("CB-"):
                continue
            claim = norm(row["claim"])
            core = claim.rstrip(".").strip()
            if row["status"] in REVIEW_OK and claim not in style:
                problems.append(
                    f"{row['id']}: verified copy block is not in STYLE.md verbatim — "
                    f"prescribed copy and the ledger have drifted apart"
                )
            if row["status"] == "rejected" and core and core in style:
                # A rejected sentence may still appear in STYLE.md, but ONLY inside a
                # clause telling writers not to use it. Anywhere else it reads as copy.
                at = style.index(core)
                window = style[max(0, at - 220): at + len(core) + 220].lower()
                if not any(w in window for w in ("never", "bad:", "do not", "forbid", "rejected")):
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
        "all sentences present verbatim"
    )
    print("This is the floor, not the audit: no artifact was opened. A human still verifies evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
