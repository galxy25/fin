#!/bin/bash
# update-binary.sh — install the PUBLISHED fin-agentd on this Mac, by hand.
#
#   update-binary.sh            download, verify, swap in, restart the LaunchAgent
#   update-binary.sh --no-restart
#
# The daemon updates itself when the control plane sends it an `update` command
# (DaemonSiteClient.performUpdate) — but that command rides in on a heartbeat, and
# the one time you need a new binary most is when the running one is not beating
# (a crash loop before the terminal is ready: the work laptop, 2026-09-17/18). This
# is the same download-verify-rename, driven from a shell instead.
#
# Credentials come from the installed config.json — the site's own token, sent the
# way the daemon sends it (bearer + X-Fin-Site) — so nothing here needs the repo, an
# AWS profile, or an operator token. The bearer is read by python and passed on
# stdin, never in argv.
set -euo pipefail

FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
CONFIG="$FIN_AGENTD_HOME/config.json"
BIN="$FIN_AGENTD_HOME/bin/fin-agentd"
LABEL="dev.levischoen.fin.agentd"
PYTHON="${FIN_PYTHON:-/usr/bin/python3}"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

[ -s "$CONFIG" ] || { echo "no config at $CONFIG — is fin-agentd installed here?" >&2; exit 1; }
[ -x "$BIN" ] || { echo "no binary at $BIN — run install.sh first" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# One python invocation does the authenticated presign call and prints the two
# values the shell needs, one per line: the presigned GET and the expected sha256.
FIN_CONFIG="$CONFIG" "$PYTHON" - > "$WORK/presign" <<'PY'
import json, os, sys, urllib.request
with open(os.environ["FIN_CONFIG"]) as fh:
    config = json.load(fh)
plane = config.get("controlPlane") or {}
site = config.get("site") or {}
endpoint = (plane.get("endpointURL") or "").rstrip("/")
token, site_id = site.get("token"), site.get("id")
if not endpoint or not token or not site_id:
    sys.exit("config.json has no controlPlane.endpointURL / site.id / site.token — this Mac is not an enrolled site")
request = urllib.request.Request(
    endpoint + "/presign",
    data=json.dumps({"kinds": ["agentdBinary"]}).encode(),
    headers={"authorization": "Bearer " + token, "X-Fin-Site": site_id, "Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=20) as response:
    urls = json.load(response).get("urls") or {}
get, sha = urls.get("agentdBinaryGet"), (urls.get("agentdBinarySha256") or "").lower()
if not get or not sha:
    sys.exit("the control plane has no published binary (presign returned no agentdBinaryGet/agentdBinarySha256)")
print(get)
print(sha)
PY

URL="$(sed -n 1p "$WORK/presign")"
EXPECTED="$(sed -n 2p "$WORK/presign")"
curl -fsSL --max-time 120 -o "$WORK/fin-agentd" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/fin-agentd" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "sha256 mismatch: published $EXPECTED, downloaded $ACTUAL — not installing" >&2; exit 1; }
chmod 755 "$WORK/fin-agentd"
NEW_VERSION="$("$WORK/fin-agentd" --version 2>/dev/null | awk '$1 == "fin-agentd" {print $2}')"
OLD_VERSION="$("$BIN" --version 2>/dev/null | awk '$1 == "fin-agentd" {print $2}')"

# Same-volume rename: atomic, and the running process keeps its old inode until exit.
mv -f "$WORK/fin-agentd" "$BIN"
echo "installed fin-agentd ${NEW_VERSION:-?} over ${OLD_VERSION:-?} at $BIN"

if [ "$RESTART" = 1 ]; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL" && echo "restarted $LABEL" || \
        echo "could not restart $LABEL — is it bootstrapped? (install.sh --start)" >&2
fi
