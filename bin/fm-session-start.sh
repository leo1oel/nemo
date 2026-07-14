#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (session start) and 5 (recovery) into ONE
# script producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: fm-lock.sh,
# fm-wake-drain.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/learnings.md, data/backlog.md, every state/*.meta, and
# every state/*.status. Every one of those reads is UNCONDITIONAL at every
# session start, so they belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-wake-drain.sh,
# and fm-guard.sh as real subprocesses and prints their real output. It never
# re-implements their logic; all sequencing/formatting logic added here stays
# local to this file. Those scripts remain fully working standalone.
#
# ORDERING - lock FIRST, before any mutating step:
#
#   1. lock           - acquire the per-home session lock before anything that
#                       mutates shared state.
#   2. diagnostics    - read-only tool presence + crew-dispatch policy
#                       visibility; always safe, always runs.
#   3. wake-drain     - mutates the durable wake queue, so it only runs when
#                       this session actually holds the lock. A refused
#                       (read-only) session reports the queue length and runs
#                       fm-guard.sh directly instead, so the same alarms
#                       surface without touching the queue.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/learnings.md: read-only, always runs.
#   5. fleet digest   - data/backlog.md, every state/*.meta with a cheap
#                       endpoint-liveness read, a bounded state/*.status tail,
#                       orphan status logs, and state/.afk: read-only.
#   6. closing reminder - the context-specific watcher next step; this script
#                       deliberately never arms the watcher itself (a
#                       fire-and-forget arm from a script that exits would be
#                       reaped immediately, silently dropping supervision).
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud banner
#   inline, never a silent failure or a non-zero exit that would make an agent
#   skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Pane existence for the endpoint-liveness read (fm_herdr_pane_exists).
# shellcheck source=bin/fm-herdr-lib.sh
. "$SCRIPT_DIR/fm-herdr-lib.sh"

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically meaningful
# for every one of these files (captain.md absent = template defaults,
# projects.md absent = rebuild from clones, etc. - AGENTS.md section 3) and
# must never be confused with an empty-but-present file, so the two cases
# print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1
  printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' "$STATUS_TAIL" "$status"
  tail -n "$STATUS_TAIL" "$status"
}

section "SESSION START - $FM_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping the wake-queue drain. The read-only-safe digest below still ran.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

# --- 2. diagnostics ------------------------------------------------------
# Read-only detect lines: missing tools and the active crew-dispatch policy.
# This fork has no bootstrap; the environment provisions tools, so a missing
# one here is a report-to-captain problem, not something to install inline.
subsection "DIAGNOSTICS"
MISSING=""
for tool in herdr gh-axi no-mistakes tasks-axi python3; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  printf 'TOOLS: missing:%s\n' "$MISSING"
else
  printf 'TOOLS: all present (herdr, gh-axi, no-mistakes, tasks-axi, python3)\n'
fi
if [ -f "$CONFIG/crew-dispatch.json" ]; then
  if command -v python3 >/dev/null 2>&1 \
    && ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONFIG/crew-dispatch.json" 2>/dev/null; then
    printf 'CREW_DISPATCH: invalid config/crew-dispatch.json - not valid JSON; fix it (dispatch backstop not enforced while invalid)\n'
  else
    printf 'CREW_DISPATCH: active config/crew-dispatch.json - consult these rules before every crewmate/scout dispatch (AGENTS.md section 4):\n'
    cat "$CONFIG/crew-dispatch.json"
  fi
else
  printf 'CREW_DISPATCH: none (no config/crew-dispatch.json; spawns use Claude defaults)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally, so the tangle/watcher-liveness
# banners land right here too, ahead of the bulk digest below. The read-only
# path never touches the queue (another session may be actively draining it)
# but still runs fm-guard.sh directly, so the same alarms surface.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$("$FM_ROOT/bin/fm-guard.sh" 2>&1 || true)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. context digest -----------------------------------------------------
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"
print_file_or_absent "$DATA/backlog.md" "data/backlog.md"

subsection "In-flight tasks (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  handle=$(grep '^handle=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -z "$handle" ]; then
    printf 'endpoint: unknown (no handle recorded)\n'
  elif [ "$kind" = secondmate ]; then
    # A secondmate agent that exits leaves its pane alive as a bare shell, and
    # the watcher exempts secondmates from stale-pane detection - so pane
    # presence alone misses a dead-shell secondmate. Probe the AGENT, not just
    # the pane, and flag a confidently dead one for respawn (AGENTS.md section 5).
    case "$(fm_herdr_agent_alive "$handle")" in
      alive)   printf 'endpoint: alive (handle=%s, agent live)\n' "$handle" ;;
      dead)    printf 'endpoint: DEAD - respawn this secondmate (handle=%s, agent gone/bare shell)\n' "$handle" ;;
      *)       printf 'endpoint: unknown (handle=%s, agent liveness unreadable - do not respawn on this alone)\n' "$handle" ;;
    esac
  elif fm_herdr_pane_exists "$handle"; then
    printf 'endpoint: alive (handle=%s)\n' "$handle"
  else
    printf 'endpoint: dead (handle=%s)\n' "$handle"
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
AFK_PRESENT=0
if [ -e "$STATE/.afk" ]; then
  AFK_PRESENT=1
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Do not arm the normal watcher directly; load /afk and
ensure the daemon is running, because the daemon owns watcher supervision.

EOF
else
cat <<'EOF'
Arm the watcher yourself as your harness's own tracked background task - this
script never does, and never should: a fire-and-forget arm from inside a
script that then exits would be reaped immediately, silently dropping
supervision (AGENTS.md section 8).

  bin/fm-watch-arm.sh

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/secondmates.md, data/captain.md, data/learnings.md,
data/backlog.md, or state/*.meta now - they were just printed in full.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.
EOF

exit 0
