#!/bin/bash
# make-bundle.sh — pack a self-contained resident-site installer for a Mac that has no
# checkout of this repo (a work laptop, a fresh MacBook). Produces
# fin-agentd-site-<version>.tar.gz containing the release binary, every runtime script
# the LaunchAgents need, both plists, a rendered SETUP.md, and — when asked — a 0600
# site.env carrying the settings that machine cannot be expected to guess.
#
#   make-bundle.sh --out DIR [--binary PATH] [--name "Work laptop"] [--priority 80]
#                  [--llm URL] [--from-local-shim] [--model ID] [--endpoint URL]
#                  [--transport local]
#
#   --from-local-shim   read the LM Studio shim bearer out of THIS Mac's
#                       dev.levischoen.fin.llm-shim LaunchAgent and put it in site.env.
#                       The token is never printed — not by this script, not by install.sh.
#
# WHY A TARBALL AND NOT A CHECKOUT. install.sh only ever needs its own directory: it copies
# the runtime scripts next to the binary and renders the plists to point THERE, never into
# a git working tree (a plist pointing at a checkout becomes a silent ENOENT the first time
# someone runs `git checkout main`). Everything else it needs — the site token, the
# presigned URLs — arrives over HTTPS from the control plane. So a resident site install
# needs exactly these files and an enroll token, nothing else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_PLIST="$HOME/Library/LaunchAgents/dev.levischoen.fin.llm-shim.plist"

BIN_SRC="$REPO_ROOT/daemon/.build/release/fin-agentd"
OUT_DIR=""; NAME=""; PRIORITY=""; LLM_URL=""; MODEL=""; FROM_SHIM=0; TRANSPORT=""
ENDPOINT="${FIN_CONTROL_PLANE_ENDPOINT:-https://vzrf1bf59g.execute-api.us-west-2.amazonaws.com}"

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT_DIR="$2"; shift ;;
		--binary) BIN_SRC="$2"; shift ;;
		--name) NAME="$2"; shift ;;
		--priority) PRIORITY="$2"; shift ;;
		--llm) LLM_URL="$2"; shift ;;
		--model) MODEL="$2"; shift ;;
		--endpoint) ENDPOINT="$2"; shift ;;
		--transport)
			case "$2" in ssh|local) TRANSPORT="$2" ;; *) echo "error: --transport must be ssh or local" >&2; exit 64 ;; esac
			shift ;;
		--from-local-shim) FROM_SHIM=1 ;;
		-h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done
[ -n "$OUT_DIR" ] || { echo "error: --out DIR is required" >&2; exit 64; }
[ -x "$BIN_SRC" ] || { echo "error: no release binary at $BIN_SRC (build it through scripts/dev/one-at-a-time.sh)" >&2; exit 1; }

VERSION="$("$BIN_SRC" --version | awk '$1 == "fin-agentd" {print $2}')"
[ -n "$VERSION" ] || { echo "error: $BIN_SRC does not answer --version" >&2; exit 1; }

umask 077
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/fin-agentd-site"
mkdir -p "$PKG"

for f in install.sh uninstall.sh refresh.sh provision-config.sh enroll-config.py \
         rotate-logs.sh launch-agentd.sh dev.levischoen.fin.agentd.plist \
         dev.levischoen.fin.agentd.refresh.plist README.md SETUP.md; do
	cp "$SCRIPT_DIR/$f" "$PKG/$f"
done
chmod 755 "$PKG"/*.sh
cp "$BIN_SRC" "$PKG/fin-agentd"
chmod 755 "$PKG/fin-agentd"

# --- site.env ---------------------------------------------------------------------------
# Only written when there is something non-default to say. install.sh sources it before it
# reads any environment default, and refuses to read it unless it is owner-only.
if [ -n "$NAME$PRIORITY$LLM_URL$MODEL$TRANSPORT" ] || [ "$FROM_SHIM" -eq 1 ]; then
	ENV_FILE="$PKG/site.env"
	: > "$ENV_FILE"; chmod 600 "$ENV_FILE"
	# Every value is shell-QUOTED. install.sh sources this file, and a display name is the
	# one setting that routinely contains a space: `FIN_DISPLAY_NAME=Work laptop` sources
	# as an assignment followed by an attempt to RUN `laptop`. (Found by the smoke test,
	# not by reading it.)
	kv() { [ -n "$2" ] && printf '%s=%q\n' "$1" "$2"; return 0; }
	{
		echo "# fin-agentd site settings — sourced by install.sh. OWNER-ONLY (chmod 600):"
		echo "# it carries the brain's bearer token."
		kv FIN_CONTROL_PLANE_ENDPOINT "$ENDPOINT"
		kv FIN_DISPLAY_NAME "$NAME"
		kv FIN_PRIORITY "$PRIORITY"
		kv FIN_LLM_URL "$LLM_URL"
		kv FIN_MODEL "$MODEL"
		kv FIN_TRANSPORT "$TRANSPORT"
	} >> "$ENV_FILE"
	if [ "$FROM_SHIM" -eq 1 ]; then
		[ -f "$SHIM_PLIST" ] || { echo "error: no shim LaunchAgent at $SHIM_PLIST" >&2; exit 1; }
		TOKEN="$(/usr/bin/plutil -extract EnvironmentVariables.FIN_LLM_SHIM_TOKEN raw -o - "$SHIM_PLIST")"
		[ -n "$TOKEN" ] || { echo "error: the shim plist has no FIN_LLM_SHIM_TOKEN" >&2; exit 1; }
		printf 'FIN_LLM_API_KEY=%q\n' "$TOKEN" >> "$ENV_FILE"
		unset TOKEN
		echo "site.env:   brain bearer copied from the local shim LaunchAgent (not printed)"
	fi
	echo "site.env:   written ($(grep -c '^FIN_' "$ENV_FILE") settings)"
fi

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/fin-agentd-site-$VERSION.tar.gz"
# -p on the pack side is free; the far side must extract with -p or site.env lands 0644.
tar -C "$STAGE" -czpf "$TARBALL" fin-agentd-site
echo "bundle:     $TARBALL ($(stat -f %z "$TARBALL") bytes, fin-agentd $VERSION)"
