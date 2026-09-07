#!/bin/bash
# rotate-logs.sh — cap the three unbounded files a resident site writes.
#
#   rotate-logs.sh            rotate anything over the size cap
#   rotate-logs.sh --force    rotate regardless of size
#
# Nothing else rotates them. The daemon's stdout carries every directive, every inbox
# message and every model reply in plaintext (Daemon.swift `log()`, callers "applying
# directive …" and "agent: …") — redaction is applied only on the way OFF the machine
# (DaemonTranscriptUplink, DaemonNotifyClient), so the local copy is raw. audit.jsonl is
# opened once and appended to forever (AuditLogWriter), and a heartbeat line lands every
# 60 s. On an always-on Mac all three grow without bound on the boot disk, and a
# credential dictated into the inbox from a phone stays on disk indefinitely.
#
# Rotation is by rename, so it MUST happen while the daemon is stopped or immediately
# before a restart — a running process keeps writing to the renamed inode until launchd
# reopens StandardOutPath on the next spawn. refresh.sh calls this right before its
# `launchctl kickstart -k`, and install.sh --start before it bootstraps.
set -euo pipefail

FIN_AGENTD_HOME="${FIN_AGENTD_HOME:-$HOME/Library/Application Support/fin-agentd}"
LOG_DIR="${FIN_AGENTD_LOG_DIR:-$HOME/Library/Logs/fin-agentd}"
MAX_BYTES="${FIN_LOG_MAX_BYTES:-8388608}"   # 8 MiB
KEEP="${FIN_LOG_KEEP:-2}"                   # .1 and .2, then dropped
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

umask 077

rotate() {
	local file="$1" size=0
	[ -f "$file" ] || return 0
	size="$(stat -f %z "$file" 2>/dev/null || echo 0)"
	if [ "$FORCE" -eq 0 ] && [ "$size" -lt "$MAX_BYTES" ]; then return 0; fi
	[ "$size" -gt 0 ] || return 0
	local i
	for (( i = KEEP; i >= 1; i-- )); do
		if [ -f "$file.$i" ]; then
			if [ "$i" -eq "$KEEP" ]; then rm -f "$file.$i"; else mv -f "$file.$i" "$file.$((i + 1))"; fi
		fi
	done
	mv -f "$file" "$file.1"
	chmod 600 "$file.1" 2>/dev/null || true
	# Recreate empty so a running process that still holds the old fd at least does not
	# resurrect the rotated file, and so tail -F finds something.
	: > "$file"
	chmod 600 "$file" 2>/dev/null || true
	echo "rotated: $file ($size bytes -> $file.1)"
}

rotate "$LOG_DIR/agentd.out.log"
rotate "$LOG_DIR/agentd.err.log"
rotate "$LOG_DIR/refresh.out.log"
rotate "$LOG_DIR/refresh.err.log"
rotate "$FIN_AGENTD_HOME/audit.jsonl"
