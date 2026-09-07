#!/usr/bin/env python3
"""Mechanical citation checker for the model-factory lab book.

The defect this exists to kill
------------------------------
Four consecutive rounds of this book shipped a provenance error of the same
shape: a citation that named a **branch** instead of a **revision**, and the
branch moved out from under it. O010 wrote the rule ("a branch name is not a
revision") and then broke it in the same commit. Editorial care demonstrably
does not hold. This is the control that does: a command, run before every
commit, that fails.

Rules enforced
--------------
  BRANCH-ANCHOR   A content citation of the form ``<ref>:<path>`` whose
                  ``<ref>`` is not a 7-40 character hex sha. ``main:README.md:44``
                  names a file that changes; ``704ab09:README.md:44`` names bytes.

  BRANCH-LOCUS    Prose that locates a fact at a branch -- "at main", "on
                  imac-site", "against labbook" -- with no sha pinned beside it
                  on the same line. A tip is a fact with a timestamp; if you
                  mean the tip, say which commit it was and when you read it.
                  Prepositions match case-INSENSITIVELY: round 5 found the rule
                  had never fired on a sentence-initial "On `imac-site`".

  BRANCH-SUBJECT  A branch used as the bare grammatical SUBJECT of a tip
                  predicate -- "`main` now means X", "`main` points at X",
                  "the name `main`, which ... resolves to X" -- with no sha
                  beside it. BRANCH-LOCUS only ever matched
                  "<preposition> <branch>", so the subject form was invisible
                  to it, and that is the form all three round-5 findings took.

  BRANCH-TIP      A present-tense claim about a branch tip -- one carrying
                  "now", "today", "currently" -- with no READ DECLARATION
                  ("read at ...", "when read", "resolved at ...") anywhere in
                  the logical line. A sha beside it is NOT sufficient and this
                  is the whole point: `main` now means `587fb9a` cites a sha
                  and is still false the moment someone merges. A commit date
                  is indistinguishable from a read time to any reader, so the
                  words "read at" are what the rule requires.

  KNOWN LIMIT of BRANCH-SUBJECT and BRANCH-TIP: both are CLOSED WORD LISTS --
  TIP_PREDICATE enumerates the verbs, TIP_NOW_RE the temporal phrases. Round 5
  shipped them claiming to close the defect shape; the round-5 audit showed the
  shape escaping on a ONE-WORD substitution ("`main` means `587fb9a`
  presently" fired nothing). Both lists were widened and T007 locks the
  widening in, but a wider closed list is still a closed list: a verb and a
  temporal phrase both off the lists still escape, and prose has unbounded
  ways to say "now". The structural alternative -- require a read declaration
  beside EVERY prose branch mention, unconditionally -- was measured against
  this book: 117 findings, against the 35 (at 27 sites) every BRANCH-* rule
  finds today, which in an append-only book means ~90 new waivers. Recorded in
  O013, not fixed.

  BRANCH-LINECOUNT  A line count -- "that file is 217 lines" -- asserted in the
                  same logical line as an unpinned branch. LINE-CLAIM only
                  re-derives counts stated beside a `<sha>:<path>` anchor, so a
                  count asserted against a *branch* was never checked at all.

  STASIS          Any assertion that a branch "has not moved" / "is unchanged"
                  / "still resolves". This is never checkable from the text and
                  was false the last two times the book said it. Delete the
                  assertion; publish the sha comparison you actually ran.

  SHA-EXISTS      Every token that is cited as a sha must resolve in this
                  repository (``git cat-file -e``). Catches typos and shas that
                  only ever existed in another clone.

  LINE-CLAIM      (--verify-lines) For ``<sha>:<path>:N`` and ``<sha>:<path>:N-M``,
                  the blob must exist at that sha and be long enough. For
                  "<sha> ... <path> ... is N lines", re-derive the count.

Hard-wrapped prose is scanned as LOGICAL lines
----------------------------------------------
The book is hard-wrapped at ~76 columns, so one sentence is two or three
physical lines. A line-oriented scanner never saw ``imac-site`` (P001:82) and
``at line 210`` (P001:83) together, and never saw ``main`` (O005:211) and the
word ``now`` (O005:212) together. Prose lines are therefore joined into logical
lines before the rules run, and a finding is reported at the physical line the
offending token sits on. Table rows, headings, blockquotes and rules stand
alone -- joining a whole table would invent adjacency between its rows.

Waivers
-------
A branch name is legitimate in six places (see ``citation-waivers.txt`` for the
list and the reason each one must name). Those go in ``citation-waivers.txt``
beside this file, keyed by the exact snippet rather than a line number so they
survive edits, and each one must carry a reason. Fenced code blocks are skipped
wholesale -- they are transcripts, not claims.

One reason class is checked mechanically rather than trusted: a waiver whose
reason begins ``corrected-elsewhere`` exists because the book is append-only
and the offending sentence lives in a PUBLISHED entry that may not be
rewritten. Such a waiver must name the correcting entry id, that entry must
exist, and its ``corrects:`` front matter must list the waived entry's id.
A pointer, not an excuse.

Usage
-----
    check_citations.py                    # scan, exit 1 on any finding
    check_citations.py --verify-lines     # also re-derive line numbers/counts
    check_citations.py --fix-suggestions  # print the sha each branch resolves to
    check_citations.py --self-test        # prove the checker fires

stdlib only, no network.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
WAIVER_FILE = HERE / "citation-waivers.txt"

# A sha as this book cites them: git's short form is 7, full is 40.
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")

# Names that are not revisions even though they look like they address one.
# Real branches are read from the repository; this is the floor, so the checker
# still fires in a clone that has only `main`.
SYMBOLIC_REFS = {
    "main",
    "HEAD",
    "FETCH_HEAD",
    "ORIG_HEAD",
    "MERGE_HEAD",
    "master",
    "origin/main",
    "origin/HEAD",
}


def git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd or HERE),
        capture_output=True,
        text=True,
    )


def repo_branch_names(cwd: Path | None = None) -> set[str]:
    """Every ref name in this repository, plus the symbolic floor."""
    names = set(SYMBOLIC_REFS)
    proc = git(
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads",
        "refs/remotes",
        cwd=cwd,
    )
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            name = line.strip()
            if name:
                names.add(name)
                # `origin/foo` also gets cited bare as `foo`.
                if "/" in name:
                    names.add(name.rsplit("/", 1)[1])
    return {n for n in names if n and not SHA_RE.match(n)}


@dataclass
class Finding:
    rule: str
    path: str
    line: int
    text: str
    snippet: str
    detail: str

    def __str__(self) -> str:
        return (
            f"{self.path}:{self.line}: [{self.rule}] {self.detail}\n"
            f"    | {self.text.strip()[:150]}"
        )


# --------------------------------------------------------------------------
# waivers
# --------------------------------------------------------------------------


def load_waivers(path: Path = WAIVER_FILE) -> list[tuple[str, str, str]]:
    """(file-glob, exact snippet, reason) triples. Keyed by text, not line."""
    out: list[tuple[str, str, str]] = []
    if not path.exists():
        return out
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3:
            raise SystemExit(
                f"{path}: waiver must be '<file> | <snippet> | <reason>': {raw!r}"
            )
        fileglob, snippet, reason = parts
        if not reason:
            raise SystemExit(f"{path}: waiver without a reason: {raw!r}")
        out.append((fileglob, snippet, reason))
    return out


ENTRY_ID_RE = re.compile(r"\b([EOHP]\d{3})\b")


def front_matter(path: Path) -> dict[str, str]:
    """The entry's front-matter keys, flat, values as raw strings."""
    out: dict[str, str] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    if not lines or lines[0].strip() != "---":
        return out
    key = None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([a-z][\w-]*):\s*(.*)$", line)
        if m:
            key = m.group(1)
            out[key] = m.group(2).strip()
        elif key and line.strip():
            out[key] += " " + line.strip()
    return out


def validate_waivers(
    waivers: list[tuple[str, str, str]], root: Path
) -> list[str]:
    """`corrected-elsewhere` waivers must point at a real correcting entry.

    Append-only means a published defect cannot be rewritten, so the checker
    would fire on it forever. The waiver is the reconciliation -- but only if it
    is a POINTER: it has to name an entry that exists and whose `corrects:`
    front matter lists the entry being waived. Otherwise the sixth reason
    becomes the excuse the other five are not.
    """
    errors: list[str] = []
    entries = {p.name: p for p in (root / "year-1").glob("*.md")}
    for fileglob, snippet, reason in waivers:
        if not reason.startswith("corrected-elsewhere"):
            continue
        waived_id_m = re.match(r"([EOHP]\d{3})-", fileglob)
        if not waived_id_m:
            errors.append(
                f"corrected-elsewhere waiver must name a specific entry file, "
                f"not {fileglob!r}: {snippet!r}"
            )
            continue
        waived_id = waived_id_m.group(1)
        cited = [i for i in ENTRY_ID_RE.findall(reason) if i != waived_id]
        if not cited:
            errors.append(
                f"{fileglob}: corrected-elsewhere waiver names no correcting "
                f"entry id: {reason!r}"
            )
            continue
        for entry_id in cited:
            match = [n for n in entries if n.startswith(entry_id + "-")]
            if not match:
                errors.append(
                    f"{fileglob}: corrected-elsewhere names {entry_id}, "
                    f"which is not an entry in year-1/"
                )
                continue
            fm = front_matter(entries[match[0]])
            if waived_id not in ENTRY_ID_RE.findall(fm.get("corrects", "")):
                errors.append(
                    f"{fileglob}: waiver names {entry_id} as the correction, "
                    f"but {entry_id}'s `corrects:` does not list {waived_id}"
                )
    return errors


def waived(
    finding: Finding, waivers: list[tuple[str, str, str]]
) -> str | None:
    name = Path(finding.path).name
    for fileglob, snippet, reason in waivers:
        if fileglob not in ("*", name, finding.path):
            continue
        if snippet and snippet in finding.text:
            return reason
    return None


# --------------------------------------------------------------------------
# scanning
# --------------------------------------------------------------------------

# `<ref>:<path>` where path has a directory or an extension -- a content anchor.
ANCHOR_RE = re.compile(
    r"(?<![\w/.-])(?P<ref>[A-Za-z0-9_][\w./-]*)"
    r":(?P<path>(?:[\w.-]+/)*[\w-]+\.[A-Za-z]{1,6})"
    r"(?::(?P<lines>\d+(?:-\d+)?))?"
)

# The wrapper class must absorb markdown emphasis: the book writes `main`,
# **main**, *main* and bare main interchangeably, and an earlier version of this
# regex missed "on **main**" in O003 -- the exact file the rule exists for.
#
# `(?i:...)` on the preposition only, not on the branch alternation: round 5
# found the rule had NEVER fired on P001's "On `imac-site` that file is 217
# lines", because the pattern was compiled case-sensitively and the sentence
# began with a capital O. Case-folding the branch names too would start matching
# "Main" and "Head" as prose words.
LOCUS_RE_TMPL = (
    r"\b(?i:at|on|against|from|in|onto|to)\s+"
    r"[`'\"*_]{0,3}(?P<ref>{names})(?!@\{)[`'\"*_]{0,3}"
    r"(?![\w:/-])"
)

# A branch name sitting in the same breath as a line number: "(`main`, line 154)",
# "on main at 240-262". The line number is only true of a revision.
# `(?!@\{)` keeps reflog selectors out: `labbook@{2026-09-06 11:07:25}` is a
# timestamp, and reading "07" out of it as a line number is noise.
# The window is 80 rather than 40 because the book is hard-wrapped: joining
# P001:82-83 puts `imac-site` 58 characters from "at line 210", and 40 missed it.
# `(?<![\w/-])` is load-bearing: without a LEFT boundary the alternation matches
# `labbook` inside the worktree path `fin-wt-labbook`, which is a directory name
# and not a citation at all.
BRANCH_LINE_RE_TMPL = (
    r"(?<![\w/-])[`'\"*_]{0,3}(?P<ref>{names})(?!@\{)[`'\"*_]{0,3}"
    r"[^.\n]{0,80}?\b(?:line|lines|:)\s*\**(?P<n>\d{2,4})(?:-\d+)?\b"
)

# The bare-colon arm of the pattern above also matches the middle of a clock
# time: `labbook@{2026-09-06 11:07:25}` offers ":07", and this book is full of
# read times. A number that is part of HH:MM(:SS) or a date is not a line
# number, and widening the window to 80 made this the checker's largest false
# positive class.
CLOCKY_RE = re.compile(r"\d[:.-]$")

# A branch as the bare grammatical SUBJECT of a tip predicate. LOCUS_RE demands
# a preposition immediately before the name, so "`main` now means `587fb9a`",
# "the name `main`, which ... points at `587fb9a`" and "`main` is 219 lines"
# matched nothing at all -- and that is the shape of every round-5 finding.
TIP_PREDICATE = (
    r"(?:now\s+|currently\s+|today\s+|presently\s+)?"
    r"(?:means|meant|points?\s+(?:at|to)|pointed\s+(?:at|to)"
    r"|resolves?\s+to|resolved\s+to|has\s+moved\s+to|moved\s+to"
    r"|sits\s+(?:at|on)|sat\s+(?:at|on)|stands\s+(?:at|on)|stood\s+(?:at|on)"
    r"|designates?|designated|equals?|equalled|refers?\s+to|referred\s+to"
    r"|tip\s+is|is|was)"
)

# A negated predicate is not a tip claim. "`labbook` did not name the entry"
# (O009) says what a branch failed to do, not what it currently resolves to,
# and reporting it would teach the reader to skim -- the failure mode the
# precision guards below exist to prevent.
NEGATED_PREDICATE_RE = re.compile(
    r"\b(?:not|never|n't|no\s+longer)\s*$", re.IGNORECASE
)
BRANCH_SUBJECT_RE_TMPL = (
    r"(?<![\w/-])[`'\"*_]{0,3}(?P<ref>{names})(?!@\{)[`'\"*_]{0,3}"
    r"(?![\w:/-])"
    r"(?P<gap>[^.;!?|\n]{0,30}?)\s"
    + TIP_PREDICATE
    + r"\b"
)

# `main` is also an ordinary English adjective. "the main checkout is
# undisturbed" (P005) and "the `main` line of history" (O010) are not claims
# about a branch tip, and reporting them would teach the reader to skim the
# rule's output -- which is how the rule stops working.
MAIN_AS_ADJECTIVE = {
    "checkout", "checkouts", "repo", "repository", "worktree", "tree",
    "line", "thread", "point", "reason", "thing", "idea", "difference",
    "concern", "problem", "focus", "loop", "window", "screen", "target",
    "argument", "path", "event", "menu", "entry", "cost", "risk", "effect",
}

# Present tense about a moving pointer. "now", "today", "currently" date a claim
# to the instant it was typed and to no other, which is the one thing a reader
# cannot recover.
TIP_NOW_RE = re.compile(
    r"\b(?:now|today|currently|presently|nowadays|at\s+the\s+moment|as\s+of\s+now"
    r"|right\s+now|for\s+now|at\s+present|these\s+days|at\s+the\s+tip"
    r"|as\s+(?:things|matters)\s+stand"
    r"|as\s+of\s+(?:this\s+writing|today|now)"
    r"|at\s+(?:this|the\s+time\s+of)\s+writing)\b",
    re.IGNORECASE,
)

# What discharges BRANCH-TIP. Not a sha -- a sha does not say WHEN it was read,
# and a commit date sitting beside a branch name reads exactly like a read time
# while meaning something else entirely (O010:88-89 is the worked example).
READ_DECL_RE = re.compile(
    r"\b(?:read|resolved|checked|measured|observed)\s+(?:at|on)\b"
    r"|\bwhen\s+(?:it\s+was\s+|they\s+were\s+)?read\b"
    r"|\bas\s+read\s+(?:at|on)\b"
    r"|\bat\s+the\s+time\s+of\s+reading\b"
    r"|\bread\s+\d{4}-\d{2}-\d{2}\b",
    re.IGNORECASE,
)

# A counterfactual is not a claim about a tip. "Had this pass left them named
# `main`, all 17 would now be anchors into a different file" (O010) describes a
# world that did not happen; there is no tip to date.
SUBJUNCTIVE_RE = re.compile(r"\b(?:would|could|should|might|were\s+to)\b",
                            re.IGNORECASE)

STASIS_RE = re.compile(
    r"(?P<claim>"
    r"(?:has|have|had)\s+not\s+(?:moved|changed)"
    r"|(?:has|have)n't\s+(?:moved|changed)"
    r"|(?:is|are|was|were)\s+(?:still\s+)?unchanged"
    r"|still\s+(?:resolve|resolves|resolved|point|points|hold|holds)"
    r"|(?:did|does|do)\s+not\s+move"
    r")",
    re.IGNORECASE,
)

# A sha cited in prose: backticked, or bare in a citation-ish position.
# The trailing/leading `-` exclusion keeps uuid segments out (a transcript uuid
# like 96d4ea32-4134-4277-824b-975f32754df7 is four hex runs, none of them git).
SHA_TOKEN_RE = re.compile(r"(?<![\w/-])(?P<sha>[0-9a-f]{7,40})(?![\w-])")

# Hex that is cited as something other than a git object. The book is full of
# sha256 corpus digests and a HuggingFace snapshot id; none of them are in git,
# and reporting them would train the reader to ignore this rule.
NON_GIT_DIGEST_RE = re.compile(
    r"sha256|shasum|snapshot|digest|checksum|uuid|hash-object", re.IGNORECASE
)

# "<path> is 217 lines" / "that file is 217 lines" / "217 lines rather than 202"
LINECOUNT_RE = re.compile(
    r"\b(?:is|are|was|were)\s+(?P<n>\d{2,6})\s+lines\b"
    r"|\b(?P<n2>\d{2,6})\s+lines\s+(?:rather\s+than|instead\s+of|not)\b"
)

FENCE_RE = re.compile(r"^\s*(```|~~~)")

# Lines that are their own logical unit and are never joined to a neighbour.
# Joining a table would invent adjacency between rows that are separate claims.
STANDALONE_RE = re.compile(r"^\s*(?:#{1,6}\s|\||>|-{3,}\s*$|={3,}\s*$|\+\-)")
LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]\s|\d+[.)]\s)")
# A front-matter `key: value` line starts a fresh unit too, so `related:` does
# not glue itself to `title:`.
FM_KEY_RE = re.compile(r"^[a-z][\w-]*:")

# Sentence boundaries, coarse but deliberate: a full stop / semicolon / bang /
# question mark followed by space, an em dash with spaces around it, or a table
# cell wall. Over-splitting makes the proximity tests STRICTER, which is the
# direction this checker should err in.
SENT_BREAK_RE = re.compile(r"[.;!?](?=\s)|\s—\s|\|")

# The same thing without the em dash. An em dash usually joins a citation to its
# gloss -- "| `704ab09` — what `main` pointed at while this entry was written |"
# is one claim with its sha attached -- so splitting there would report a pinned
# citation as unpinned. Used only for "is a sha attached to this?", never for
# "is a present-tense word attached to this?".
CLAUSE_BREAK_RE = re.compile(r"[.;!?](?=\s)|\|")


TABLE_DELIM_RE = re.compile(r"^\s*\|[\s:|-]+\|\s*$")


def logical_lines(
    lines: list[str],
) -> list[tuple[str, list[tuple[int, int]], str]]:
    """Join hard-wrapped prose into logical lines.

    Returns ``(text, [(offset_in_text, physical_line_no), ...], kind)`` so a
    match at offset N can be reported at the physical line it actually sits on,
    and so a table HEADER row can be told from a table data row: a header cell
    is a column label ("| `main` was | at | what happened |"), not a claim, and
    the shas live in the rows beneath it.
    """
    out: list[tuple[str, list[tuple[int, int]], str]] = []
    parts: list[tuple[str, int]] = []

    def flush(kind: str = "prose") -> None:
        nonlocal parts
        if not parts:
            return
        text = ""
        offsets: list[tuple[int, int]] = []
        for chunk, lineno in parts:
            if text:
                text += " "
            offsets.append((len(text), lineno))
            text += chunk
        out.append((text, offsets, kind))
        parts = []

    in_fence = False
    for i, raw in enumerate(lines, start=1):
        if FENCE_RE.match(raw):
            flush()
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = raw.strip()
        if not stripped:
            flush()
            continue
        if STANDALONE_RE.match(raw):
            flush()
            parts.append((stripped, i))
            kind = "standalone"
            if stripped.startswith("|"):
                nxt = lines[i] if i < len(lines) else ""
                kind = "table-header" if TABLE_DELIM_RE.match(nxt) else "table-row"
            flush(kind)
            continue
        if LIST_ITEM_RE.match(raw) or FM_KEY_RE.match(raw):
            flush()
        parts.append((stripped, i))
    flush()
    return out


def physical_line(offsets: list[tuple[int, int]], pos: int) -> int:
    """The physical line number containing text offset `pos`."""
    lineno = offsets[0][1]
    for off, ln in offsets:
        if off <= pos:
            lineno = ln
        else:
            break
    return lineno


def _span(text: str, pos: int, breaker: re.Pattern) -> tuple[int, int]:
    start, end = 0, len(text)
    for m in breaker.finditer(text):
        if m.end() <= pos:
            start = m.end()
        elif m.start() > pos:
            end = m.start()
            break
    return start, end


def sentence_span(text: str, pos: int) -> tuple[int, int]:
    """The (start, end) of the sentence containing offset `pos`."""
    return _span(text, pos, SENT_BREAK_RE)


def clause_span(text: str, pos: int) -> tuple[int, int]:
    """Sentence, but an em dash does not break it. See CLAUSE_BREAK_RE."""
    return _span(text, pos, CLAUSE_BREAK_RE)


def scan_file(
    path: Path,
    branch_names: set[str],
    repo_root: Path,
    verify_lines: bool = False,
) -> list[Finding]:
    findings: list[Finding] = []
    seen: set[tuple[str, int, str]] = set()
    rel = str(path)
    alt = "|".join(re.escape(n) for n in sorted(branch_names, key=len, reverse=True))
    locus_re = re.compile(LOCUS_RE_TMPL.replace("{names}", alt))
    branch_line_re = re.compile(BRANCH_LINE_RE_TMPL.replace("{names}", alt))
    subject_re = re.compile(BRANCH_SUBJECT_RE_TMPL.replace("{names}", alt))
    branch_word_re = re.compile(
        r"(?<![\w/-])[`'\"*_]{0,3}(?P<ref>" + alt
        + r")(?!@\{)[`'\"*_]{0,3}(?![\w:/-])"
    )

    def adjectival(ref: str, at_end: int) -> bool:
        """`main` used as the English adjective, not the branch."""
        if ref != "main":
            return False
        nxt = re.match(r"[`'\"*_]{0,3}\s+([A-Za-z]+)", text[at_end:])
        return bool(nxt) and nxt.group(1).lower() in MAIN_AS_ADJECTIVE

    lines = path.read_text().splitlines()

    for text, offsets, kind in logical_lines(lines):
        # A table header cell names a column; the claim is in the rows below it.
        label_row = kind == "table-header"

        def add(rule: str, pos: int, snippet: str, detail: str) -> None:
            lineno = physical_line(offsets, pos)
            key = (rule, lineno, snippet)
            if key in seen:
                return
            seen.add(key)
            findings.append(
                Finding(rule, rel, lineno, lines[lineno - 1].strip(), snippet, detail)
            )

        # --- BRANCH-ANCHOR -------------------------------------------------
        for m in ANCHOR_RE.finditer(text):
            ref = m.group("ref")
            if SHA_RE.match(ref):
                continue
            if ref not in branch_names:
                continue
            add(
                "BRANCH-ANCHOR",
                m.start(),
                m.group(0),
                f"citation `{m.group(0)}` names the branch `{ref}`, not a revision",
            )

        # --- BRANCH-LOCUS --------------------------------------------------
        for m in locus_re.finditer(text):
            ref = m.group("ref")
            if label_row or adjectival(ref, m.end("ref")):
                continue
            if sha_pinned_near(text, m.start("ref"), m.end("ref")):
                continue
            add(
                "BRANCH-LOCUS",
                m.start("ref"),
                m.group(0),
                f"'{m.group(0)}' locates a fact at branch `{ref}` "
                f"with no sha pinned beside it",
            )

        # --- BRANCH-SUBJECT ------------------------------------------------
        # "`main` now means `587fb9a`" -- no preposition, so BRANCH-LOCUS is
        # blind to it. Fires only when nothing pins it; the dated form of the
        # same sentence is BRANCH-TIP's business.
        for m in subject_re.finditer(text):
            ref = m.group("ref")
            if label_row or adjectival(ref, m.end("ref")):
                continue
            # "`labbook` did NOT name X" is not a claim about a tip.
            if NEGATED_PREDICATE_RE.search(m.group("gap") or ""):
                continue
            # Sentence scope, not a character window: "what `main` meant while
            # this book was written" sits 85 characters from the `704ab09` that
            # pins it, inside one citation. A sha anywhere in the sentence
            # discharges the SUBJECT form; BRANCH-TIP is what a *present-tense*
            # claim still has to answer to.
            clo, chi = clause_span(text, m.start("ref"))
            if sha_pinned_near(text, m.start("ref"), m.end("ref")) or \
                    sha_in_span(text, clo, chi):
                continue
            add(
                "BRANCH-SUBJECT",
                m.start("ref"),
                m.group(0),
                f"'{m.group(0).strip()}' states what branch `{ref}` IS, with no "
                f"sha beside it; a branch is a moving pointer",
            )

        # --- BRANCH-TIP ----------------------------------------------------
        # A present-tense claim about a tip needs a read time, not a sha. The
        # read declaration must be in the SAME SENTENCE: scoping it to the whole
        # logical line let one "measured at `59b0515`" elsewhere in the paragraph
        # discharge O005's "points at `587fb9a` now", which is the exact claim
        # this rule exists to catch.
        if not label_row:
            for bm in branch_word_re.finditer(text):
                ref = bm.group("ref")
                if adjectival(ref, bm.end("ref")):
                    continue
                lo, hi = sentence_span(text, bm.start("ref"))
                nm = TIP_NOW_RE.search(text, lo, hi)
                if not nm:
                    continue
                if READ_DECL_RE.search(text, lo, hi):
                    continue
                if SUBJUNCTIVE_RE.search(text, lo, hi):
                    continue
                add(
                    "BRANCH-TIP",
                    bm.start("ref"),
                    text[lo:hi].strip()[:90],
                    f"'{nm.group(0)}' dates a claim about branch "
                    f"`{ref}` to the instant it was typed; say when "
                    f"you READ the tip ('read at <time>') -- a sha alone does not",
                )

        # --- BRANCH-LINE ---------------------------------------------------
        for m in branch_line_re.finditer(text):
            ref = m.group("ref")
            if label_row or adjectival(ref, m.end("ref")):
                continue
            # A clock time or a date is not a line number.
            if CLOCKY_RE.search(text[max(0, m.start("n") - 3):m.start("n")]) or \
                    re.match(r"[:.-]\d", text[m.end("n"):m.end("n") + 2]):
                continue
            if sha_pinned_near(text, m.start("ref"), m.end("ref")):
                continue
            add(
                "BRANCH-LINE",
                m.start("ref"),
                m.group(0),
                f"line {m.group('n')} is stated against branch `{ref}`; "
                f"a line number is only true of a revision",
            )

        # --- BRANCH-LINECOUNT ----------------------------------------------
        # LINE-CLAIM re-derives a count only when it sits beside a `<sha>:<path>`
        # anchor. A count asserted against a BRANCH was never checked at all.
        for lm in LINECOUNT_RE.finditer(text):
            if label_row:
                continue
            lo, hi = sentence_span(text, lm.start())
            for bm in branch_word_re.finditer(text, lo, hi):
                if adjectival(bm.group("ref"), bm.end("ref")):
                    continue
                if sha_pinned_near(text, bm.start("ref"), bm.end("ref")):
                    continue
                add(
                    "BRANCH-LINECOUNT",
                    bm.start("ref"),
                    lm.group(0),
                    f"'{lm.group(0)}' is a line count asserted against branch "
                    f"`{bm.group('ref')}`; pin the sha and re-derive it there",
                )

        # --- STASIS --------------------------------------------------------
        for sm in STASIS_RE.finditer(text):
            lo, hi = sentence_span(text, sm.start())
            near = sorted({bm.group("ref")
                           for bm in branch_word_re.finditer(text, lo, hi)})
            if near:
                add(
                    "STASIS",
                    sm.start(),
                    sm.group("claim"),
                    f"asserts '{sm.group('claim')}' about branch(es) "
                    f"{', '.join(near)}; publish the sha comparison instead",
                )

        # --- SHA-EXISTS ----------------------------------------------------
        for m in SHA_TOKEN_RE.finditer(text):
            sha = m.group("sha")
            if len(sha) < 7:
                continue
            # Skip things that are plainly not shas: pure digits, or a hex run
            # inside a longer hash citation already checked by context.
            if sha.isdigit():
                continue
            # Cited as a content digest / model snapshot rather than a commit?
            if NON_GIT_DIGEST_RE.search(text[: m.start("sha")]):
                continue
            if not sha_exists(sha, repo_root):
                # A blob/tree hash is also legitimate; cat-file -e covers those.
                add(
                    "SHA-EXISTS",
                    m.start("sha"),
                    sha,
                    f"`{sha}` does not resolve to an object in this repository",
                )

        # --- LINE-CLAIM ----------------------------------------------------
        if verify_lines:
            for f in check_line_claims(rel, 0, text, repo_root):
                add(f.rule, max(0, text.find(f.snippet)), f.snippet, f.detail)

    return findings


def sha_pinned_near(text: str, start: int, end: int, window: int = 70) -> bool:
    """Is a sha cited within `window` characters of this branch mention?

    Clamped to the sentence. Since hard-wrapped prose is joined into logical
    lines, an unclamped window reaches into the NEXT sentence, and a sha over
    there pins nothing over here -- that is how the checker's own T002 fixture
    stopped firing when line-joining arrived.
    """
    slo, shi = sentence_span(text, start)
    lo = max(slo, start - window)
    hi = min(shi, end + window)
    for a, b in ((lo, start), (end, hi)):
        if a >= b:
            continue
        for m in SHA_TOKEN_RE.finditer(text, a, b):
            if not m.group("sha").isdigit():
                return True
    return False


def sha_in_span(text: str, lo: int, hi: int) -> bool:
    """Does a sha appear anywhere inside [lo, hi)?"""
    return any(
        not m.group("sha").isdigit()
        for m in SHA_TOKEN_RE.finditer(text, lo, hi)
    )


_SHA_CACHE: dict[str, bool] = {}


def sha_exists(sha: str, repo_root: Path) -> bool:
    key = f"{repo_root}:{sha}"
    if key in _SHA_CACHE:
        return _SHA_CACHE[key]
    proc = git("cat-file", "-e", f"{sha}^{{object}}", cwd=repo_root)
    _SHA_CACHE[key] = proc.returncode == 0
    return _SHA_CACHE[key]


def check_line_claims(
    rel: str, i: int, text: str, repo_root: Path
) -> list[Finding]:
    """Re-derive line anchors and line counts stated against a sha."""
    out: list[Finding] = []
    for m in ANCHOR_RE.finditer(text):
        ref, path, lines = m.group("ref"), m.group("path"), m.group("lines")
        if not SHA_RE.match(ref):
            continue
        proc = git("show", f"{ref}:{path}", cwd=repo_root)
        if proc.returncode != 0:
            out.append(
                Finding(
                    "LINE-CLAIM",
                    rel,
                    i,
                    text,
                    m.group(0),
                    f"`{path}` does not exist at `{ref}`",
                )
            )
            continue
        if not lines:
            continue
        total = len(proc.stdout.splitlines())
        hi = int(lines.split("-")[-1])
        if hi > total:
            out.append(
                Finding(
                    "LINE-CLAIM",
                    rel,
                    i,
                    text,
                    m.group(0),
                    f"line {hi} is past the end of `{path}` at `{ref}` ({total} lines)",
                )
            )
        # A stated line count in the SAME SENTENCE as the anchor. Sentence
        # scope, not whole-line scope: since hard-wrapped prose is now joined,
        # a paragraph can hold an anchor at one sha and a line count about a
        # different revision, and blaming the anchor for it would be a false
        # attribution. A count asserted against a branch is BRANCH-LINECOUNT's.
        lo, hi = sentence_span(text, m.start())
        lc = LINECOUNT_RE.search(text, lo, hi)
        if lc:
            stated = int(lc.group("n") or lc.group("n2"))
            if stated != total:
                out.append(
                    Finding(
                        "LINE-CLAIM",
                        rel,
                        i,
                        text,
                        lc.group(0),
                        f"states {stated} lines; `{path}` at `{ref}` "
                        f"is {total} lines",
                    )
                )
    return out


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------


def book_files(root: Path) -> list[Path]:
    files = [root / "README.md", root / "INDEX.md"]
    files += sorted((root / "year-1").glob("*.md"))
    return [f for f in files if f.exists()]


def run(
    root: Path,
    repo_root: Path,
    verify_lines: bool,
    waivers: list[tuple[str, str, str]],
) -> tuple[list[Finding], list[tuple[Finding, str]]]:
    branch_names = repo_branch_names(repo_root)
    live: list[Finding] = []
    skipped: list[tuple[Finding, str]] = []
    for f in book_files(root):
        for finding in scan_file(f, branch_names, repo_root, verify_lines):
            finding.path = str(f.relative_to(root))
            reason = waived(finding, waivers)
            if reason:
                skipped.append((finding, reason))
            else:
                live.append(finding)
    return live, skipped


def cited_branches(repo_root: Path, findings: list[Finding]) -> list[str]:
    """The branch names the findings actually name, in first-seen order."""
    seen: dict[str, None] = {}
    for f in findings:
        for name in re.findall(r"[`'*_]*([\w./-]+)[`'*_]*", f.snippet):
            if SHA_RE.match(name) or not name:
                continue
            proc = git("rev-parse", "--verify", "--quiet", f"refs/heads/{name}",
                       cwd=repo_root)
            if proc.returncode == 0:
                seen.setdefault(name, None)
    return list(seen)


def fix_suggestions(repo_root: Path, findings: list[Finding]) -> None:
    print("Branch -> revision, read now. Pin the sha and say when you read it.\n")
    seen = {n: None for n in cited_branches(repo_root, findings)}
    if not seen:
        print("  (no branch citations found -- nothing to pin)")
    for name in seen:
        sha = git("rev-parse", "--short", name, cwd=repo_root).stdout.strip()
        subj = git("log", "-1", "--format=%s", sha, cwd=repo_root).stdout.strip()
        date = git(
            "log", "-1", "--format=%ad", "--date=format:%Y-%m-%d %H:%M:%S", sha,
            cwd=repo_root,
        ).stdout.strip()
        print(f"  {name:18s} -> {sha}  ({date})  {subj[:60]}")
    # Wall-clock, not the last commit's date: the whole point of this mode is
    # that a tip is a fact with a timestamp, and the timestamp is when YOU read it.
    print(f"\n  (read at {datetime.now().astimezone():%Y-%m-%d %H:%M:%S %Z} "
          f"-- copy this into the entry beside the sha)")


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

SELF_TEST_GOOD = """---
id: T001
sources:
  - 704ab09:evals/tmux-routing/run_evals.py:195 (the exit rule)
---
The exit rule is at `704ab09:evals/tmux-routing/run_evals.py:195`.
Measured at `704ab09` on 2026-09-06; the tip of imac-site was `78e6c36`
when it was read at 13:22:14.
`gate_sweep.sh` is reachable from 78e6c36 and not from 704ab09.
"""

SELF_TEST_BAD = """---
id: T002
sources:
  - main:evals/tmux-routing/run_evals.py:195 (the exit rule)
---
The anchors still resolve because `main` has not moved.
The corpus was regenerated at main and again on **imac-site**.
The factory README (`main`, line 240) states the gate.
See `deadbee` for the run that produced it.
"""


# --- the three forms that got through round 4's checker (O013) --------------

# Gap A (case-sensitive preposition) + Gap B (hard-wrapped sentence). Copied
# from P001:82-84 with its wrap points preserved, because the wrap is the bug.
SELF_TEST_WRAPPED = """---
id: T004
---
The eval harness encodes the same split independently -- `run_evals.py:195` on
`704ab09` (same blob at `59b0515`, where this entry lives) is
`return 0 if core_passed == core_total else 1`, so hard-tier misses report
but never fail a run. On `imac-site` that file is 217 lines rather than 202
and the same statement is at line 210; quote the line instead.
"""

# Gap C: a branch as the bare grammatical SUBJECT of a tip claim. Both of these
# cite a sha, and both were false when written. A sha is not a read time.
SELF_TEST_SUBJECT = """---
id: T005
---
The bare grep exits 1 with no output. `main` now means `587fb9a`
(2026-09-06 13:38:26), which merged the sibling publishing pipeline.

| revision | bare |
| --- | --- |
| `587fb9a` -- `main` today | 0, 1 hit |

It is the sha, not the name `main`, which pointed at `704ab09` while this book
was written and points at `587fb9a` now.
"""

# The round-5 audit's finding: TIP_PREDICATE and TIP_NOW_RE are closed word
# lists, so the defect O013 says they close evaded on a ONE-WORD substitution --
# "`main` means `587fb9a` presently" fired nothing at all. The lists are wider
# now and this fixture is what keeps them wide. It is NOT a claim that the gap
# is closed; see O013's "the limit these two rules still have".
SELF_TEST_SUBSTITUTED = """---
id: T007
---
`main` means `587fb9a` presently, and `imac-site` designates `78e6c36` at this
writing.

`labbook` sits on `6ea70e9` as things stand.
"""

# The same three claims, written correctly. A rule nothing can satisfy teaches
# nothing, so this fixture must stay silent.
SELF_TEST_TIP_OK = """---
id: T006
---
`main` was `587fb9a` when read at 2026-09-06 13:38:26, and `imac-site` was
`78e6c36` when read at 2026-09-06 13:22:14.

| revision | bare |
| --- | --- |
| `587fb9a` | 0, 1 hit |

At `78e6c36` that file is 219 lines and the rule is at line 212; at `704ab09`
it is 202 lines and the rule is at line 195.
"""


def self_test() -> int:
    """Plant one defect per rule and assert the checker fires on each."""
    repo_root = HERE
    while repo_root != repo_root.parent and not (repo_root / ".git").exists():
        repo_root = repo_root.parent

    expect = {
        "good": set(),
        "bad": {"BRANCH-ANCHOR", "BRANCH-LOCUS", "BRANCH-LINE", "STASIS",
                "SHA-EXISTS"},
    }
    ok = True
    with tempfile.TemporaryDirectory(
        dir=os.environ.get("TMPDIR") or None, prefix="citecheck-"
    ) as td:
        root = Path(td)
        (root / "year-1").mkdir()
        (root / "README.md").write_text("# fixture\n")
        (root / "INDEX.md").write_text("# index\n")
        (root / "year-1" / "T001-good.md").write_text(SELF_TEST_GOOD)
        (root / "year-1" / "T002-bad.md").write_text(SELF_TEST_BAD)
        (root / "year-1" / "T004-wrapped.md").write_text(SELF_TEST_WRAPPED)
        (root / "year-1" / "T005-subject.md").write_text(SELF_TEST_SUBJECT)
        (root / "year-1" / "T006-tip-ok.md").write_text(SELF_TEST_TIP_OK)
        (root / "year-1" / "T007-substituted.md").write_text(
            SELF_TEST_SUBSTITUTED)

        findings, _ = run(root, repo_root, verify_lines=True, waivers=[])
        by_file: dict[str, set[str]] = {}
        for f in findings:
            by_file.setdefault(Path(f.path).name, set()).add(f.rule)

        got_good = by_file.get("T001-good.md", set())
        got_bad = by_file.get("T002-bad.md", set())

        print("self-test")
        print(f"  clean fixture   expect {sorted(expect['good']) or '[]'}"
              f"  got {sorted(got_good) or '[]'}"
              f"  {'PASS' if got_good == expect['good'] else 'FAIL'}")
        if got_good != expect["good"]:
            ok = False
            for f in findings:
                if Path(f.path).name == "T001-good.md":
                    print(f"      unexpected: {f}")
        missing = expect["bad"] - got_bad
        print(f"  planted defects expect {sorted(expect['bad'])}")
        print(f"                  got    {sorted(got_bad)}"
              f"  {'PASS' if not missing else 'FAIL (missing ' + str(sorted(missing)) + ')'}")
        if missing:
            ok = False

        # --- the three forms round 4's checker missed (O013) ----------------
        regressions = {
            "T004-wrapped.md": (
                "hard-wrapped 'On `imac-site` ... 217 lines ... at line 210'",
                {"BRANCH-LOCUS", "BRANCH-LINE", "BRANCH-LINECOUNT"},
            ),
            "T005-subject.md": (
                "branch as subject: '`main` now means `587fb9a`'",
                {"BRANCH-TIP"},
            ),
            "T007-substituted.md": (
                "one-word substitutions off the closed lists: "
                "'means ... presently', 'designates ... at this writing'",
                {"BRANCH-TIP"},
            ),
        }
        for name, (what, want) in regressions.items():
            got = by_file.get(name, set())
            miss = want - got
            print(f"  {name:16s} expect {sorted(want)}")
            print(f"  {'':16s} got    {sorted(got) or '[]'}"
                  f"  {'PASS' if not miss else 'FAIL (missing ' + str(sorted(miss)) + ')'}")
            print(f"  {'':16s} ({what})")
            if miss:
                ok = False

        # A rule nothing can satisfy teaches nothing: the correct wording of the
        # same three claims must be silent.
        got_ok = by_file.get("T006-tip-ok.md", set())
        print(f"  T006-tip-ok.md   expect []  got {sorted(got_ok) or '[]'}"
              f"  {'PASS' if not got_ok else 'FAIL'}")
        if got_ok:
            ok = False
            for f in findings:
                if Path(f.path).name == "T006-tip-ok.md":
                    print(f"      unexpected: {f}")

        # Fenced blocks must be skipped, and waivers must suppress.
        (root / "year-1" / "T003-fenced.md").write_text(
            "---\nid: T003\n---\n```\n$ git show main:README.md\n```\n"
        )
        f3, _ = run(root, repo_root, verify_lines=False, waivers=[])
        fenced = [x for x in f3 if Path(x.path).name == "T003-fenced.md"]
        print(f"  fenced block    expect []  got {[x.rule for x in fenced] or '[]'}"
              f"  {'PASS' if not fenced else 'FAIL'}")
        if fenced:
            ok = False

        # --fix-suggestions must actually resolve the branches it offers to pin.
        bad_findings = [x for x in findings if Path(x.path).name == "T002-bad.md"]
        resolved = cited_branches(repo_root, bad_findings)
        shas = {n: git("rev-parse", "--short", n, cwd=repo_root).stdout.strip()
                for n in resolved}
        ok_fix = "main" in shas and all(SHA_RE.match(s) for s in shas.values())
        print(f"  fix-suggestions expect main resolves to a sha  "
              f"got {shas or '{}'}  {'PASS' if ok_fix else 'FAIL'}")
        if not ok_fix:
            ok = False

        w = [("T002-bad.md", "has not moved", "fixture waiver")]
        f4, skipped = run(root, repo_root, verify_lines=False, waivers=w)
        stasis_live = [x for x in f4 if x.rule == "STASIS"]
        print(f"  waiver          expect STASIS suppressed  "
              f"got {len(stasis_live)} live, {len(skipped)} waived  "
              f"{'PASS' if not stasis_live and skipped else 'FAIL'}")
        if stasis_live or not skipped:
            ok = False

    print(f"\nself-test: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(HERE), help="lab book directory")
    ap.add_argument("--verify-lines", action="store_true",
                    help="re-derive line anchors and line counts at their shas")
    ap.add_argument("--fix-suggestions", action="store_true",
                    help="print the sha each cited branch currently resolves to")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the checker fires, then exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    root = Path(args.root).resolve()
    repo_root = root
    while repo_root != repo_root.parent and not (repo_root / ".git").exists():
        repo_root = repo_root.parent

    waivers = load_waivers()
    waiver_errors = validate_waivers(waivers, root)
    findings, skipped = run(root, repo_root, args.verify_lines, waivers)

    if args.fix_suggestions:
        fix_suggestions(repo_root, findings)
        return 0

    for f in findings:
        print(f)
    counts: dict[str, int] = {}
    for f in findings:
        counts[f.rule] = counts.get(f.rule, 0) + 1

    print()
    for e in waiver_errors:
        print(f"citation-waivers.txt: [WAIVER] {e}")
    print(f"scanned {len(book_files(root))} files; "
          f"{len(findings)} finding(s), {len(skipped)} waived"
          + (f", {len(waiver_errors)} broken waiver(s)" if waiver_errors else ""))
    for rule in sorted(counts):
        print(f"  {rule:16s} {counts[rule]}")
    if not findings and not waiver_errors:
        print("  clean -- every citation names a revision.")
    return 1 if (findings or waiver_errors) else 0


if __name__ == "__main__":
    sys.exit(main())
