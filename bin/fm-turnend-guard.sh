#!/usr/bin/env bash
# Claude Code "Stop" hook for the firstmate PRIMARY session only.
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# re-arming the watcher, and then never runs another fleet-touching command
# itself, can sit blind for hours (upstream's 2026-07-04 incident: a parked
# no-mistakes gate sat unwatched all night). This hook is push-based: Claude
# Code invokes it every time the primary is about to end a turn, and it can
# force the turn to continue instead by exiting 2 with a reason on stderr.
# The tracked settings command invokes this script as
# "$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh because Claude Code runs hook
# commands via /bin/sh from the session's current cwd, not necessarily the
# repo root.
#
# Ships as the TRACKED .claude/settings.json at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home.
# It must therefore scope itself to the PRIMARY at runtime and stay a silent,
# fast no-op everywhere else.
#
# Loop-guard: never block twice in the same turn. Claude Code's stdin payload
# carries stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not the watcher actually got re-armed. That bounds this
# to at most one forced continuation per turn - never a wedged, un-endable
# session - while still nagging again on a later turn if the problem persists.
#
# Away mode: while state/.afk exists the daemon owns the watcher (the watcher
# runs one-shot for it and its beacon cadence is the daemon's business), so a
# live daemon pid counts as supervision and a dead one blocks with its own
# repair hint.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}

# Read the whole Stop hook payload once; never block on unreadable/absent stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# python3 is this fork's established JSON reader (fm-backend.sh _jget). Without
# it we cannot safely read the loop-guard field, so we must never block - fail
# open, not noisy.
command -v python3 >/dev/null 2>&1 || exit 0
STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("true")
else:
    print("true" if d.get("stop_hook_active") else "false")
' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "false" ] || exit 0

# --- scope precisely to the PRIMARY checkout --------------------------------
# Excludes secondmate homes (the .fm-secondmate-home marker is written at seed
# time; see bin/fm-home-seed.sh) and crewmate/scout task worktrees of
# firstmate-on-itself (bin/fm-spawn.sh only ever hands those out as genuine
# linked worktrees - it aborts the spawn otherwise). A linked worktree's
# git-dir lives under the main repo's .git/worktrees/<name> and differs from
# the common (shared) git-dir; only the main, non-worktree checkout has the
# two equal.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# --- the actual predicate ----------------------------------------------------

in_flight=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  in_flight=$((in_flight + 1))
done
[ "$in_flight" -gt 0 ] || exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
block() {  # <headline> <fix>
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    printf '●  %s\n' "$1"
    printf '●  %s\n' "$2"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

# Away mode: the daemon owns supervision; judge by the daemon pid, not the beacon.
if [ -e "$STATE/.afk" ]; then
  daemon_pid=$(cat "$STATE/.supervise-daemon.pid" 2>/dev/null || true)
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    exit 0
  fi
  block "$in_flight task(s) in flight, away-mode is active, but the sub-supervisor daemon is dead." \
    "Restart it (nohup bin/fm-supervise-daemon.sh &) or clear state/.afk and arm bin/fm-watch-arm.sh before ending the turn."
fi

# Portable mtime; see fm-watch.sh for why the `stat -f || stat -c` fallback breaks on Linux.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

BEAT="$STATE/.last-watcher-beat"
beacon_desc=never
if [ -e "$BEAT" ]; then
  m=$(stat_mtime "$BEAT")
  if [ -n "$m" ]; then
    age=$(( $(date +%s) - m ))
    beacon_desc="${age}s ago"
    [ "$age" -lt "$GRACE" ] && exit 0
  else
    beacon_desc=unknown
  fi
fi

block "$in_flight task(s) in flight, but no watcher has a fresh beacon (last beat: $beacon_desc, grace ${GRACE}s)." \
  "Run bin/fm-watch-arm.sh as a harness-tracked background task before ending the turn."
