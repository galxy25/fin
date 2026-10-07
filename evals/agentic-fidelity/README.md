# Agentic fidelity — golden scenarios

Real, transcript-evidenced failures of the resident daemon acting on a user's
request, kept as scenarios so a prompt or model change is judged against them
before it ships. Each scenario is a user message plus the machine picture the
daemon had, and the tool sequence a passing run must produce. Source of truth
for the harness: the daemon's `audit.jsonl` (kinds `userMessage`, `toolCall`,
`assistantMessage`) — a run passes when the recorded tool calls match.

## S1 — hand work to another pane, then close the loop (2026-09-12)

**Machine:** tmux `main` with panes `main:0.0 pocketdj`, `main:1.0 fin`,
`main:2.0 africanintellect — ✳ composable-social-posts` (a Claude Code session
idle at its prompt). Goals ledger: two live goals, neither related.

**User (voice):** "Tell the African Intellect claw session to use the
share-file-to-Levi skill to send Levi the current version of the Awesome
Foundation grant as a PDF so he can review it."

**Pass — the user turn:**
1. `read_session` (list) — or none, if the prompt's pane inventory suffices
2. `send_session main:2.0 …share-file-to-Levi… Awesome Foundation grant… PDF…`
3. reply: what was sent, to which pane. **No** `goal_upsert`, no role recital,
   no "what are the goals?".

**Pass — the follow-up (daemon-written goal `g-followup-*`, next ticks):**
4. `read_session main:2.0` until the pane shows the file delivered
5. `notify` — one line: what was delivered (or what went wrong)
6. `goal_log close` on the follow-up

**Six live attempts on gemma-4-12b-qat** (`scripts/mac-fin-agentd`, 2026-09-12):
per-pane listing → refusal of ask-the-user goals → act-now preamble →
task-mode prompt → hidden goal tools + role text out of the launch task → step
3 passed at 17:35Z. Steps 4–6 were the gap this scenario adds: the daemon now
records the follow-up goal itself (`GoalsTick.followUpGoal`), because a model
that is not offered the goal tools cannot be asked to remember the hand-off.

## S2 — a read-only task handed in by another Claude session (2026-10-07)

**Machine:** iMac resident daemon, tmux `main` with `main:1.0 fin` (a Claude Code
session whose screen shows the very request below, pasted by the owner).

**Message (via the app, from a Claude session on the Neo):** "...Please do this
on the iMac and reply with what you find. 1) Check whether this folder exists in
iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/From Claude/hire-me
shared/` ... Report the file list with modified times ... say plainly if it is
missing. 2) If it is there, treat those three files as shared state ... Do not
edit, move or delete anything now; this is a read-only check."

**Pass:**
1. `send_input` an `ls` (e.g. `ls -laO "<folder>"`) — no forced `read_terminal` first.
2. reply: the file list with modified times (or plainly "missing").
3. **No** `read_session` of `main:1.0` to find out "who is handling it"; no waiting.

**Observed fail (gemma-4-12b-qat, 04:28Z):** the message matched the
`read_terminal` question pattern (`what ... say`), so the daemon forced
`read_terminal`; the model then listed sessions, read `main:1.0`, saw the pasted
request, and answered that "another agent ... is currently processing the
request", never running `ls`. **Fixes:** `AgentIntentClassifier` only forces
`read_terminal` on short single-line questions (≤200 chars;
`testLongTaskMessageIsNotForcedToReadTerminal`), and `read_session`'s tool
description says task-doing is `send_input`'s and a pane echoing the request is
a transcript, not a worker. The model-behaviour half still needs a live re-run
of S2 after the daemon update.

Failure modes to keep pinning, from `~/.claude/.../fin-agentic-fidelity-failure-modes`:
repetition of the launch reply, recency confusion, ledger override of a live
user request.
