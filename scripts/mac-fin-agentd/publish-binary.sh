#!/bin/bash
# Publishes the release fin-agentd (arm64 macOS) to S3 for the daemon's `update`
# command (docs/SITES.md §3.5): the binary plus a sha256 sidecar the daemon
# verifies before the atomic rename. Build first, through the machine guard:
#
#     scripts/dev/one-at-a-time.sh swift build -c release --package-path daemon
#     scripts/mac-fin-agentd/publish-binary.sh
#
# Operator credentials (AWS profile), never the control plane: the Lambda only
# ever hands out presigned GETs for these two keys.
set -euo pipefail
PROFILE=${FIN_AWS_PROFILE:-levi}
BUCKET=fin-agent-directives-011183829623
KEY=fin/agentd/fin-agentd-macos-arm64
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${1:-$REPO_ROOT/daemon/.build/release/fin-agentd}"
[ -x "$BIN" ] || { echo "no release binary at $BIN — build it first" >&2; exit 1; }
VERSION="$("$BIN" --version | awk '$1 == "fin-agentd" {print $2}')"
[ -n "$VERSION" ] || { echo "$BIN does not answer --version" >&2; exit 1; }
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf '%s  fin-agentd-macos-arm64\n' "$SHA" > "$WORK/sha256"
aws --profile "$PROFILE" s3 cp "$BIN" "s3://$BUCKET/$KEY" --no-progress --metadata "version=$VERSION,sha256=$SHA" >/dev/null
aws --profile "$PROFILE" s3 cp "$WORK/sha256" "s3://$BUCKET/$KEY.sha256" --no-progress --content-type text/plain >/dev/null
echo "published fin-agentd $VERSION -> s3://$BUCKET/$KEY (sha256 $SHA)"
