#!/bin/sh
# Run ONE heavy build/test command at a time on this machine.
#
#   scripts/dev/one-at-a-time.sh xcodebuild test -project fin.xcodeproj ...
#   scripts/dev/one-at-a-time.sh swift test --package-path daemon
#
# Why: 2026-09-05 the iMac (32 GB) hard-crashed under parallel xcodebuild runs
# + an mlx fine-tune + LM Studio serving a 12B model. Levi's standing rule since:
# heavily serialize Xcode/Swift testing, and never let it pile onto training.
#
# What it does, in order, before exec'ing the command:
#   1. Waits for the machine-wide lock ($FIN_BUILD_LOCK, default ~/.fin-build.lock)
#      so two of these never run at once — across sessions and worktrees.
#   2. Waits until no OTHER xcodebuild / swift-build / swift-test process is running
#      (another session's build counts; we don't kill it, we wait).
#   3. Stops the resident fin-agentd and unloads its model, restoring both
#      afterwards however the build ends (disable with --no-quiesce-fin).
#   4. Refuses if LM Studio still holds models (see resident_model_gb).
#   5. Waits until free memory is at least $FIN_MIN_FREE_GB (default 8) so the
#      build never competes with a training run for the last gigabytes.
# Each wait is logged to stderr once per minute. Ctrl-C releases the lock.
#
# BY DEFAULT this puts the resident fin-agentd to sleep for the duration of the build
# (bootout + unload its model) and restores it afterwards, however the build ends —
# because on a Mac where Fin lives `lms unload --all` does not stay done (see the JIT
# note above resident_model_gb) and the guard was otherwise unsatisfiable. Fin is
# offline for the length of the build and comes back on its own.
#
#   --no-quiesce-fin   Leave the resident agent running. The guard will then refuse
#                      while its model holds memory, which is the pre-2026-09-16
#                      behavior. Equivalent: FIN_QUIESCE_AGENTD=0.
set -eu

LOCK="${FIN_BUILD_LOCK:-$HOME/.fin-build.lock}"
MIN_FREE_GB="${FIN_MIN_FREE_GB:-8}"
MAX_WAIT_S="${FIN_MAX_WAIT_S:-7200}"
# ON BY DEFAULT. Levi, 2026-09-16: "the agent going offline would only affect me, and
# only during new builds of fin that I would be working on — development iteration
# speeds matter far more than uptime of my agent brain." So the build no longer asks
# permission to borrow the machine back; it takes it and gives it straight back.
# FIN_QUIESCE_AGENTD=0 (or --no-quiesce-fin) opts out for a build that must not
# interrupt a resident agent.
QUIESCE="${FIN_QUIESCE_AGENTD:-1}"
AGENTD_LABEL="${FIN_AGENTD_LABEL:-dev.levischoen.fin.agentd}"
AGENTD_DOMAIN="gui/$(id -u)"
AGENTD_PLIST="${FIN_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/$AGENTD_LABEL.plist"

if [ "${1:-}" = "--quiesce-fin" ]; then QUIESCE=1; shift; fi
if [ "${1:-}" = "--no-quiesce-fin" ]; then QUIESCE=0; shift; fi

[ $# -gt 0 ] || { echo "usage: $0 [--no-quiesce-fin] <command> [args...]" >&2; exit 64; }

log() { echo "[one-at-a-time] $*" >&2; }

free_gb() {
  # Free + inactive + speculative pages are reclaimable; purgeable is not counted
  # so this stays conservative.
  vm_stat | awk '
    /page size of/ { gsub(/[^0-9]/, "", $8); ps = $8 }
    /Pages free/        { gsub(/\./, "", $3); f = $3 }
    /Pages inactive/    { gsub(/\./, "", $3); i = $3 }
    /Pages speculative/ { gsub(/\./, "", $3); s = $3 }
    END { printf "%d", (f + i + s) * ps / 1073741824 }'
}

other_builds() {
  # Any xcodebuild or SwiftPM build/test driver that is not our own ancestor.
  #
  # Match the EXECUTABLE, not the command line. `pgrep -f` matches the whole
  # command line, so anything that merely MENTIONS a build tool counts as one:
  # on 2026-09-07 this loop waited out its full two-hour timeout against a single
  # monitor process whose only crime was grepping for the string "swift-build".
  # A watcher looking for builds is not a build. `ps -o comm=` gives the running
  # program's own name, which a shell wrapper's arguments cannot forge.
  ps -axo pid=,comm= 2>/dev/null | while read -r _pid _comm; do
    case "${_comm##*/}" in
      xcodebuild|swift-build|swift-test|swift-frontend|swift-package|swiftc)
        [ "$_pid" = "$$" ] || [ "$_pid" = "$PPID" ] || echo "$_pid" ;;
    esac
  done | wc -l | tr -d ' '
}

# The pids we are waiting on, so an orphan from a killed run is distinguishable
# from a live neighbour without another session having to guess.
other_build_pids() {
  ps -axo pid=,comm= 2>/dev/null | while read -r _pid _comm; do
    case "${_comm##*/}" in
      xcodebuild|swift-build|swift-test|swift-frontend|swift-package|swiftc)
        [ "$_pid" = "$$" ] || [ "$_pid" = "$PPID" ] || echo "$_pid" ;;
    esac
  done | tr '\n' ' '
}

# Whether WE booted the daemon out, so restore only ever undoes our own doing: a
# machine where Fin was already stopped must be left stopped.
QUIESCED=0

agentd_loaded() { launchctl print "$AGENTD_DOMAIN/$AGENTD_LABEL" >/dev/null 2>&1; }

# Put Fin to sleep for the build. `launchctl stop` is NOT enough: the plist is
# KeepAlive=true with a 15s throttle, so a stopped daemon respawns and JIT-reloads
# the model right back into the memory this build is about to need. bootout removes
# the job from the domain, which is the only thing that stays done.
quiesce_agentd() {
  agentd_loaded || { log "fin-agentd is not loaded; nothing to quiesce"; return 0; }
  log "quiescing $AGENTD_LABEL for the build (it will be restored afterwards)"
  launchctl bootout "$AGENTD_DOMAIN/$AGENTD_LABEL" 2>/dev/null || true
  QUIESCED=1
  # Only now can the unload stick. Give a turn already in flight a moment to die
  # with its process rather than racing the unload.
  sleep 2
  command -v lms >/dev/null 2>&1 || return 0
  lms unload --all >/dev/null 2>&1 || true
  # AND WAIT FOR IT. `lms unload` returns before LM Studio has released the memory,
  # so the resident-model check that follows was measuring the machine as it had
  # been a second earlier and refusing a build that was already fine. Poll the same
  # number the check uses, rather than sleeping a guess.
  _w=0
  while [ "$(resident_model_gb)" -ge "${FIN_MAX_RESIDENT_MODEL_GB:-2}" ]; do
    if [ "$_w" -ge "${FIN_UNLOAD_WAIT_S:-60}" ]; then
      log "models still resident ${_w}s after unload; letting the check below decide"
      break
    fi
    [ "$_w" = 0 ] && log "waiting for LM Studio to release the model"
    sleep 2; _w=$((_w + 2))
  done
}

# Always paired with quiesce_agentd, on every exit path including Ctrl-C, because
# the failure mode of forgetting is a Mac whose agent is simply gone with nothing
# to say so. The model is deliberately NOT reloaded here: JIT brings it back on the
# daemon's first request, at the context length its per-model default specifies,
# which is the path we actually want exercised.
restore_agentd() {
  [ "$QUIESCED" = "1" ] || return 0
  QUIESCED=0
  if [ -f "$AGENTD_PLIST" ]; then
    launchctl enable "$AGENTD_DOMAIN/$AGENTD_LABEL" 2>/dev/null || true
    if launchctl bootstrap "$AGENTD_DOMAIN" "$AGENTD_PLIST" 2>/dev/null; then
      log "restored $AGENTD_LABEL"
      return 0
    fi
  fi
  log "WARNING: could not restore $AGENTD_LABEL — Fin is DOWN on this machine."
  log "  bring it back with: launchctl bootstrap $AGENTD_DOMAIN $AGENTD_PLIST"
}

release() { restore_agentd; rm -rf "$LOCK"; }

waited=0
while ! mkdir "$LOCK" 2>/dev/null; do
  # A lock whose owner is gone is stale (reboot, killed session): reclaim it.
  if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    log "reclaiming stale lock held by dead pid $(cat "$LOCK/pid" 2>/dev/null)"
    rm -rf "$LOCK"; continue
  fi
  [ $((waited % 60)) -eq 0 ] && log "waiting for build lock $LOCK (held by pid $(cat "$LOCK/pid" 2>/dev/null || echo '?'))"
  sleep 5; waited=$((waited + 5))
  [ "$waited" -lt "$MAX_WAIT_S" ] || { log "gave up after ${MAX_WAIT_S}s waiting for the lock"; exit 75; }
done
echo $$ > "$LOCK/pid"
trap 'release' EXIT INT TERM HUP

# A model loaded in LM Studio holds unified memory the build will need, and it
# holds it whether or not anything is using it. On 2026-09-07 a `swift test` was
# killed by the system TWICE while an IDLE 7.15 GB model sat resident for a daemon
# that was not running — the second time an hour after that exact hazard had been
# written down, which is why this is a check and not a note. Unload before a
# build; reload after. Safe whenever no daemon is running.
#
# WHEN A DAEMON *IS* RUNNING, `lms unload --all` does not stay done. LM Studio's
# `justInTimeModelLoading` is on, so the resident site's next heartbeat reloads the
# model within seconds — at its DEFAULT context length, which is not necessarily the
# one the daemon's `contextWindowTokens` is configured for. That mismatch does not
# fail loudly: budgets derived from the configured window come out too large for the
# real one and turns return EMPTY completions ("the model stopped without producing
# an answer"). It cost three live requests on 2026-09-16 before it was found.
#
# The default is per model, in
#   ~/.lmstudio/.internal/user-concrete-model-default-config/<owner>/<model>.json
#     {"preset":"","operation":{"fields":[]},
#      "load":{"fields":[{"key":"llm.load.contextLength","value":32768}]}}
# which a JIT load honors immediately, with LM Studio running. gemma-4-12b-qat is
# set to 32768 there. Check with `lms ps` (CONTEXT column) after any unload/reload,
# and see `ContextWindowProbe` for the in-daemon clamp that catches it if it slips.
resident_model_gb() {
  command -v lms >/dev/null 2>&1 || { echo 0; return; }
  lms ps 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+$/ && $(i+1) == "GB") s += $i } END { printf "%d", s + 0 }'
}
[ "$QUIESCE" = "1" ] && quiesce_agentd

# Measured AFTER any quiesce, so the check judges the machine the build will
# actually run on rather than the one it walked in on.
_m=$(resident_model_gb)
if [ "${_m:-0}" -ge "${FIN_MAX_RESIDENT_MODEL_GB:-2}" ]; then
  log "refusing to start: ${_m}GB of models are loaded in LM Studio and will compete for unified memory."
  # TELL THE TRUTH ABOUT WHICH ADVICE WORKS HERE. On a Mac where Fin is resident,
  # "unload them first" is advice that cannot be followed: the daemon JIT-reloads
  # the model within seconds of the unload, so the guard stayed unsatisfiable and
  # the only ways past it were an override or a hand-rolled bootout. Twice on
  # 2026-09-16 the unload lost that race between one command and the next.
  if agentd_loaded; then
    log "  fin-agentd is running here, so \`lms unload --all\` will NOT stay done — its next"
    log "  request reloads the model within seconds. Quiescing it for the build is the"
    log "  DEFAULT and something turned it off (--no-quiesce-fin, or FIN_QUIESCE_AGENTD=0);"
    log "  drop that to let this build borrow the machine and hand it straight back."
  else
    log "  unload them first (lms unload --all) and reload after the build."
  fi
  log "  or set FIN_MAX_RESIDENT_MODEL_GB to override."
  exit 75
fi

waited=0
while :; do
  n=$(other_builds); f=$(free_gb)
  if [ "$n" -eq 0 ] && [ "$f" -ge "$MIN_FREE_GB" ]; then break; fi
  [ $((waited % 60)) -eq 0 ] && log "holding: other builds=$n [$(other_build_pids)], free=${f}GB (need 0 and >=${MIN_FREE_GB}GB)"
  sleep 10; waited=$((waited + 10))
  [ "$waited" -lt "$MAX_WAIT_S" ] || { log "gave up after ${MAX_WAIT_S}s waiting for a quiet machine"; exit 75; }
done

log "running (free=$(free_gb)GB): $*"
"$@"
