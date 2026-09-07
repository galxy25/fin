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

Waivers
-------
A branch name is legitimate in three places: a verbatim quotation of command
output, a statement about branch *topology* that is already backed by a named
command, and prose naming the shorthand form itself as a subject. Those go in
``citation-waivers.txt`` beside this file, keyed by the exact snippet rather
than a line number so they survive edits, and each one must carry a reason.
Fenced code blocks are skipped wholesale -- they are transcripts, not claims.

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
LOCUS_RE_TMPL = (
    r"\b(?P<prep>at|on|against|from|in|onto|to)\s+"
    r"[`'\"*_]{0,3}(?P<ref>{names})(?!@\{)[`'\"*_]{0,3}"
    r"(?![\w:/-])"
)

# A branch name sitting in the same breath as a line number: "(`main`, line 154)",
# "on main at 240-262". The line number is only true of a revision.
# `(?!@\{)` keeps reflog selectors out: `labbook@{2026-09-06 11:07:25}` is a
# timestamp, and reading "07" out of it as a line number is noise.
BRANCH_LINE_RE_TMPL = (
    r"[`'\"*_]{0,3}(?P<ref>{names})(?!@\{)[`'\"*_]{0,3}"
    r"[^.\n]{0,40}?\b(?:line|lines|:)\s*\**(?P<n>\d{2,4})(?:-\d+)?\b"
)

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

# "<path> is 217 lines" / "that file is 217 lines"
LINECOUNT_RE = re.compile(r"\bis\s+(?P<n>\d{2,6})\s+lines\b")

FENCE_RE = re.compile(r"^\s*(```|~~~)")


def scan_file(
    path: Path,
    branch_names: set[str],
    repo_root: Path,
    verify_lines: bool = False,
) -> list[Finding]:
    findings: list[Finding] = []
    rel = str(path)
    alt = "|".join(re.escape(n) for n in sorted(branch_names, key=len, reverse=True))
    locus_re = re.compile(LOCUS_RE_TMPL.replace("{names}", alt))
    branch_line_re = re.compile(BRANCH_LINE_RE_TMPL.replace("{names}", alt))

    in_fence = False
    lines = path.read_text().splitlines()
    for i, text in enumerate(lines, start=1):
        if FENCE_RE.match(text):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        # --- BRANCH-ANCHOR -------------------------------------------------
        for m in ANCHOR_RE.finditer(text):
            ref = m.group("ref")
            if SHA_RE.match(ref):
                continue
            if ref not in branch_names:
                continue
            findings.append(
                Finding(
                    "BRANCH-ANCHOR",
                    rel,
                    i,
                    text,
                    m.group(0),
                    f"citation `{m.group(0)}` names the branch `{ref}`, not a revision",
                )
            )

        # --- BRANCH-LOCUS --------------------------------------------------
        for m in locus_re.finditer(text):
            ref = m.group("ref")
            # Already an anchor finding on this exact span? Don't double-report.
            if any(f.rule == "BRANCH-ANCHOR" and f.line == i and ref in f.snippet
                   for f in findings):
                pass
            if not sha_pinned_near(text, m.start("ref"), m.end("ref")):
                findings.append(
                    Finding(
                        "BRANCH-LOCUS",
                        rel,
                        i,
                        text,
                        m.group(0),
                        f"'{m.group(0)}' locates a fact at branch `{ref}` "
                        f"with no sha pinned beside it",
                    )
                )

        # --- BRANCH-LINE ---------------------------------------------------
        for m in branch_line_re.finditer(text):
            ref = m.group("ref")
            if any(f.line == i and ref in f.snippet for f in findings):
                continue
            if not sha_pinned_near(text, m.start("ref"), m.end("ref")):
                findings.append(
                    Finding(
                        "BRANCH-LINE",
                        rel,
                        i,
                        text,
                        m.group(0),
                        f"line {m.group('n')} is stated against branch `{ref}`; "
                        f"a line number is only true of a revision",
                    )
                )

        # --- STASIS --------------------------------------------------------
        sm = STASIS_RE.search(text)
        if sm:
            near = [n for n in branch_names if re.search(rf"\b{re.escape(n)}\b", text)]
            if near:
                findings.append(
                    Finding(
                        "STASIS",
                        rel,
                        i,
                        text,
                        sm.group("claim"),
                        f"asserts '{sm.group('claim')}' about branch(es) "
                        f"{', '.join(sorted(near))}; publish the sha comparison instead",
                    )
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
                findings.append(
                    Finding(
                        "SHA-EXISTS",
                        rel,
                        i,
                        text,
                        sha,
                        f"`{sha}` does not resolve to an object in this repository",
                    )
                )

        # --- LINE-CLAIM ----------------------------------------------------
        if verify_lines:
            findings.extend(check_line_claims(rel, i, text, repo_root))

    return findings


def sha_pinned_near(text: str, start: int, end: int, window: int = 70) -> bool:
    """Is a sha cited within `window` characters of this branch mention?"""
    left = text[max(0, start - window) : start]
    right = text[end : end + window]
    for chunk in (left, right):
        for m in SHA_TOKEN_RE.finditer(chunk):
            if not m.group("sha").isdigit():
                return True
    return False


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
        # A stated line count on the same line as the anchor.
        lc = LINECOUNT_RE.search(text)
        if lc and int(lc.group("n")) != total:
            out.append(
                Finding(
                    "LINE-CLAIM",
                    rel,
                    i,
                    text,
                    lc.group(0),
                    f"states {lc.group('n')} lines; `{path}` at `{ref}` "
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
    print(f"scanned {len(book_files(root))} files; "
          f"{len(findings)} finding(s), {len(skipped)} waived")
    for rule in sorted(counts):
        print(f"  {rule:14s} {counts[rule]}")
    if not findings:
        print("  clean -- every citation names a revision.")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
