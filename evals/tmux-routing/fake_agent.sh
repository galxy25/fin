#!/bin/sh
# fake_agent.sh — a stand-in coding agent for hermetic tmux-routing evals.
#
# Behaves like the only two things the harness needs a "coding agent" to do:
# show a prompt, and visibly acknowledge every line typed at it. The ack
# format is stable and greppable via `tmux capture-pane`:
#
#     FAKE-AGENT[<name>] ack #<n>: <line>
#
# Usage: fake_agent.sh <name>
# Runs forever; the eval harness kills the whole private-socket tmux server.
name="${1:-agent}"
n=0
printf 'FAKE-AGENT[%s] ready\n' "$name"
while printf '> ' && IFS= read -r line; do
  n=$((n + 1))
  printf 'FAKE-AGENT[%s] ack #%d: %s\n' "$name" "$n" "$line"
done
