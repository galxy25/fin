#!/bin/bash
# Generates s3://<bucket>/fin/agentd/_template.json — the template POST /workers
# instantiates for any agent that has no hand-provisioned daemon config — from a
# LIVE per-agent config (default source: nimbus).
#
#   make-config-template.sh [source-agent-slug]
#
# The template travels S3 to S3 through a private temp dir: the shared LLM
# bearer token inside the source config rides along both ways and never lands in
# git, and this script never prints it.
#
# Per-agent values become placeholders; the shared LLM route + token
# (agent.endpointURL, agent.apiKey, model parameters) are preserved as-is —
# every auto-provisioned agent shares that infrastructure. Placeholders the
# Lambda substitutes at instantiation:
#
#   {{AGENT}}               display name (supervision.agentName, task text)
#   {{AGENT_SLUG}}          lowercased name (tmux session name)
#   {{AGENT_ID}}            fresh UUID per agent (agentID)
#   {{DEVICE_TOKEN8}}       fresh 8-char device stamp (deviceToken8)
#   {{DIRECTIVE_GET_URL}}   presigned GET  fin/directives.json
#   {{STATUS_PUT_URL}}      presigned PUT  fin/status-<slug>.json
#   {{INBOX_GET_URL}}       presigned GET  fin/inbox/<slug>.json
#   {{TRANSCRIPT_PUT_URL}}  presigned PUT  fin/transcripts/<slug>.jsonl
set -euo pipefail

PROFILE=levi
BUCKET=fin-agent-directives-011183829623
TEMPLATE_KEY=fin/agentd/_template.json
SOURCE=${1:-nimbus}

aws() { command aws --profile "$PROFILE" "$@"; }

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

aws s3 cp "s3://$BUCKET/fin/agentd/$SOURCE.json" "$WORK/source.json" --no-progress >/dev/null

# The display name comes from the config itself, so occurrences in task text and
# agentName are replaced with the exact case the config uses.
NAME=$(jq -r '.supervision.agentName // empty' "$WORK/source.json")
[ -n "$NAME" ] || { echo "source config has no supervision.agentName" >&2; exit 1; }
SLUG=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')

# Field-level replacements first (at the JSON level, so nothing can corrupt the
# document), then a walk that swaps the agent's name and slug inside remaining
# string values (task text, tmux session name). split/join, not gsub: the name
# is treated as a literal, never a regex. Name before slug: on an all-lowercase
# name the first pass consumes every occurrence and the second finds nothing.
jq --arg name "$NAME" --arg slug "$SLUG" '
  .agentID = "{{AGENT_ID}}"
  | .deviceToken8 = "{{DEVICE_TOKEN8}}"
  | .supervision.agentName = "{{AGENT}}"
  | .supervision.directiveURL = "{{DIRECTIVE_GET_URL}}"
  | .supervision.statusURL = "{{STATUS_PUT_URL}}"
  | .supervision.inboxURL = "{{INBOX_GET_URL}}"
  | .transcript.putURL = "{{TRANSCRIPT_PUT_URL}}"
  | walk(
      if type == "string"
      then (split($name) | join("{{AGENT}}")) | (split($slug) | join("{{AGENT_SLUG}}"))
      else . end
    )
' "$WORK/source.json" > "$WORK/template.json"

# Refuse to upload a template that still carries per-agent material. The
# signature check catches a config shape with a presigned-URL field this script
# does not know about — such a URL would rot inside every instantiation.
if grep -q "X-Amz-Signature" "$WORK/template.json"; then
  echo "template still contains a presigned URL (unknown URL field in $SOURCE.json?); aborting" >&2
  exit 1
fi
SRC_ID=$(jq -r '.agentID // empty' "$WORK/source.json")
if [ -n "$SRC_ID" ] && grep -qF "$SRC_ID" "$WORK/template.json"; then
  echo "template still contains the source agentID; aborting" >&2
  exit 1
fi

aws s3 cp "$WORK/template.json" "s3://$BUCKET/$TEMPLATE_KEY" \
  --no-progress --content-type application/json >/dev/null

echo "==> Uploaded s3://$BUCKET/$TEMPLATE_KEY (from $SOURCE.json)"
echo "==> Placeholders:"
grep -o '{{[A-Z0-9_]*}}' "$WORK/template.json" | sort -u | sed 's/^/    /'
