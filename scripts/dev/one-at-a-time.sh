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
#   3. Waits until free memory is at least $FIN_MIN_FREE_GB (default 8) so the
#      build never competes with a training run for the last gigabytes.
# Each wait is logged to stderr once per minute. Ctrl-C releases the lock.
set -eu

LOCK="${FIN_BUILD_LOCK:-$HOME/.fin-build.lock}"
MIN_FREE_GB="${FIN_MIN_FREE_GB:-8}"
MAX_WAIT_S="${FIN_MAX_WAIT_S:-7200}"

[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 64; }

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

release() { rm -rf "$LOCK"; }

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
resident_model_gb() {
  command -v lms >/dev/null 2>&1 || { echo 0; return; }
  lms ps 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+$/ && $(i+1) == "GB") s += $i } END { printf "%d", s + 0 }'
}
_m=$(resident_model_gb)
if [ "${_m:-0}" -ge "${FIN_MAX_RESIDENT_MODEL_GB:-2}" ]; then
  log "refusing to start: ${_m}GB of models are loaded in LM Studio and will compete for unified memory."
  log "  unload them first (lms unload --all) and reload after the build, or set FIN_MAX_RESIDENT_MODEL_GB to override."
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
