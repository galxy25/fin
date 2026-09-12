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

Failure modes to keep pinning, from `~/.claude/.../fin-agentic-fidelity-failure-modes`:
repetition of the launch reply, recency confusion, ledger override of a live
user request.
