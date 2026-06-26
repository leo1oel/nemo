#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted.
#
# herdr backend: a secondmate home is a herdr worktree of THIS firstmate repo
# ($FM_ROOT), checked out on its own lease branch `secondmate-<id>` (see
# fm-home-seed.sh). Worktrees of this repo share one object store, so a single
# fetch refreshes them all; a standalone-clone home (an explicit-path home) is
# fetched on its own. Fast-forwarding the lease branch to origin/<default>
# advances only that worktree's branch and never touches any other worktree's
# checkout or the shared default branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh, so
# there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# herdr actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: <send-targets...>|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# Helpers (default_branch, validate_secondmate_home, ff_target, ...) live in
# bin/fm-ff-lib.sh, sourced above. This script provides the origin-sync flow.

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin "" no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------

nudge_targets=""
seen_homes=""
fm_root_real=$(resolve_path "$FM_ROOT")

process_secondmate() {
  local id=$1 home=$2 nudge=${3:-} home_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $seen_homes " in
    *" $home_real "*) return 0 ;;
  esac
  seen_homes="$seen_homes $home_real"

  # A herdr secondmate home is leased on branch `secondmate-<id>`; accept that or
  # a detached/default checkout, and fast-forward it to origin/<default>.
  ff_target "$home_real" "secondmate $id" origin "secondmate-$id" yes yes
  if [ "$FF_STATUS" = "updated" ] && [ -n "$nudge" ]; then
    nudge_targets="$nudge_targets $nudge"
  fi
}

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path. The home is a live herdr pane, so it is nudged via
# its task target `fm-<id>` (fm-send.sh resolves the pane handle from the meta).
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    process_secondmate "$id" "$home" "fm-$id"
  done
fi

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home. With
# no live pane there is nothing to nudge.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" ""
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${nudge_targets:- none}"
