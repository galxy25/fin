#!/usr/bin/env python3
"""Watch a Claude Code session's workflow agent transcripts for API-error deaths.

    workflow-exhaustion-watch.py <session-dir> [--interval 60]

Every <interval> seconds, scan <session-dir>/subagents/workflows/wf_*/agent-*.jsonl for
assistant messages flagged "isApiErrorMessage": true (model "<synthetic>") that have not been
reported yet, and print ONE line per new error:

    EXHAUSTION wf=<run-id> agent=<agent-id> text=<message>   # usage / rate / overload / quota
    TRANSIENT  wf=<run-id> agent=<agent-id> text=<message>   # e.g. "Connection lost mid-response"

Levi's standing rule (2026-09-05): when Fable usage runs out mid-workflow, re-kick the
workflow on Opus (edit the script: model: 'opus' on every agent(), then resume with
resumeFromRunId) — the watchdog itself must stay cheap, so this is plain Python and the repair
agent runs on Sonnet. Keys on the transcript's structured flag, never on prose, so a prompt that
happens to mention "rate limit" cannot false-positive.
"""
import glob, json, os, re, sys, time

EXHAUST = re.compile(r"usage[ _-]?limit|out of (extra )?usage|rate[ _-]?limit|overloaded|429|quota|exhaust|too many requests|insufficient credits|billing", re.I)

def main():
    if len(sys.argv) < 2:
        print(__doc__); return 64
    session_dir = sys.argv[1]
    interval = 60
    if "--interval" in sys.argv:
        interval = int(sys.argv[sys.argv.index("--interval") + 1])
    pattern = os.path.join(session_dir, "subagents", "workflows", "wf_*", "agent-*.jsonl")
    seen = {}  # path -> number of lines already examined
    while True:
        for path in sorted(glob.glob(pattern)):
            start = seen.get(path, 0)
            try:
                with open(path, "rb") as f:
                    lines = f.read().splitlines()
            except OSError:
                continue
            for raw in lines[start:]:
                if b'"isApiErrorMessage":true' not in raw and b'"isApiErrorMessage": true' not in raw:
                    continue
                try:
                    o = json.loads(raw)
                except Exception:
                    continue
                m = o.get("message", {}) or {}
                c = m.get("content")
                text = c if isinstance(c, str) else " ".join(b.get("text", "") for b in (c or []) if isinstance(b, dict))
                err = o.get("error")
                blob = f"{text} {json.dumps(err) if err is not None else ''}"
                kind = "EXHAUSTION" if EXHAUST.search(blob) else "TRANSIENT"
                wf = os.path.basename(os.path.dirname(path))
                agent = os.path.basename(path).replace("agent-", "").replace(".jsonl", "")
                print(f"{kind} wf={wf} agent={agent} text={blob.strip()[:220]}", flush=True)
            seen[path] = len(lines)
        time.sleep(interval)

if __name__ == "__main__":
    sys.exit(main() or 0)
