#!/usr/bin/env bash
# Tear down a finished task: remove the herdr worktree (closing its workspace + pane)
# or retire a secondmate home, clear volatile state, refresh/prune the project's clone
# for PR-based ship tasks, then print a backlog-refresh reminder.
# REFUSES if the worktree holds work not on any remote, because the worktree removal
# discards it (and kills the agent process). A fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode. local-only
# projects additionally accept work merged into the local default branch (firstmate
# performs that merge on the captain's approval) as a fallback for the common case
# where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal teardown
# refuses while their home has in-flight crewmate meta files; --force is the
# approved discard path that prevalidates child removal targets, discards child
# work, kills child panes, and removes the retired home. A herdr-provisioned home
# (a herdr worktree of $FM_ROOT, recorded via home_workspace=) is removed with
# "herdr worktree remove"; a plain directory home has its workspace closed and the
# directory deleted.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips the unpushed-work check for ordinary tasks and discards
#   secondmate child work for kind=secondmate. Only use it when the captain has
#   explicitly said to discard the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
SUB_HOME_WS_MARKER=".fm-secondmate-home.workspace"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
HANDLE=$(grep '^handle=' "$META" | cut -d= -f2- || true)
WS=$(grep '^workspace=' "$META" | cut -d= -f2- || true)
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
HOME_WORKSPACE=$(grep '^home_workspace=' "$META" | cut -d= -f2- || true)

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | cut -d= -f2- || true
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

# Reject removal targets that are the active home, the firstmate repo, an ancestor of
# either, or inside either - so a stray home= can never delete live state. Echoes the
# resolved absolute path on success.
validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then :; else abs_home=; fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

# A seeded secondmate home must carry the marker (matching $ID if known), have safe
# operational dirs, and not contain another registered secondmate home. Echoes its
# resolved path on success.
validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

# Retire a secondmate home. A herdr-provisioned home (a herdr worktree of $FM_ROOT,
# recorded via home_workspace=) is removed with "herdr worktree remove", which removes
# the worktree, closes its workspace, and kills the pane in one call. A plain directory
# home has no worktree: close its workspace if recorded (killing the pane), then delete
# the directory.
remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} ws=${4:-} abs_home_path
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  # The workspace marker beside the home is authoritative for retirement; fall back to
  # the meta-recorded workspace if the marker is missing.
  [ -n "$ws" ] || ws=$(cat "$abs_home_path/$SUB_HOME_WS_MARKER" 2>/dev/null || true)
  if [ -f "$abs_home_path/$SUB_HOME_WS_MARKER" ]; then
    # herdr-provisioned home: the workspace IS a herdr worktree of the repo.
    command -v herdr >/dev/null 2>&1 || {
      echo "error: herdr command not found; cannot remove $label $abs_home_path" >&2
      return 1
    }
    [ -n "$ws" ] || { echo "error: no herdr workspace recorded for $label $abs_home_path" >&2; return 1; }
    herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 || {
      echo "error: 'herdr worktree remove' failed for $label $abs_home_path; worktree may still exist" >&2
      return 1
    }
    return 0
  fi
  # Plain directory home: close its herdr workspace (kills the pane), then delete it.
  if [ -n "$ws" ] && command -v herdr >/dev/null 2>&1; then
    herdr workspace close "$ws" >/dev/null 2>&1 || true
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_ws child_handle child_kind child_home child_home_ws
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_ws=$(meta_value "$child_meta" workspace)
    child_handle=$(meta_value "$child_meta" handle)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      child_home_ws=$(meta_value "$child_meta" home_workspace)
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home"
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" "$child_home_ws"
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      rm -f "$child_wt/.claude/settings.local.json" 2>/dev/null || true
      "$FM_ROOT/bin/fm-backend.sh" kill "$child_handle" "$child_ws" || true
      [ -n "$child_proj" ] && git -C "$child_proj" worktree prune 2>/dev/null || true
      [ -n "$child_proj" ] && git -C "$child_proj" branch -D "fm-$child_id" >/dev/null 2>&1 || true
    fi
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.check.sh" "$sub_state/$child_id.meta"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" != "--force" ]; then
    SUB_STATE="$HOME_PATH/state"
    if [ -d "$SUB_STATE" ]; then
      for child_meta in "$SUB_STATE"/*.meta; do
        [ -e "$child_meta" ] || continue
        echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
        echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
        exit 1
      done
    fi
  else
    cleanup_firstmate_home_children "$HOME_PATH"
  fi
fi

if [ "$KIND" != secondmate ] && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$DATA/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude/' | head -1 || true)
    # A worktree's work is "safely on a remote" once HEAD is reachable from ANY
    # remote-tracking branch (empty result here). A fork is a remote too, so
    # upstream-contribution PRs pushed to a fork satisfy this regardless of mode.
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
      # local-only ships have no remote in the common case, so the "on a remote"
      # test above is expected to be non-empty. The work is safe once it is merged
      # into the local default branch (firstmate does that merge on the captain's
      # approval). Refuse until then.
      DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
      unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
      if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
        echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
        [ -n "$dirty" ] && echo "uncommitted changes present" >&2
        [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
        echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    elif [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      echo "REFUSED: worktree $WT has work not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unpushed" ] && printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  fi
fi

if [ "$KIND" = secondmate ]; then
  # Retire the persistent home: remove its herdr worktree (or close its workspace and
  # delete the directory), drop its route, and clear the main-home metadata.
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" "$HOME_WORKSPACE" || exit 1
  remove_secondmate_registry_entry "$ID"
  rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta"
  echo "teardown $ID complete (secondmate home $HOME_PATH retired)"
  printf '%s\n' "🌱 Backlog: secondmate $ID retired. Update data/backlog.md and data/secondmates.md as needed, then re-scan Queued for items now unblocked or now time-due and dispatch what's ready."
  exit 0
fi

# Remove our hook file, then let herdr remove the worktree AND close its workspace+pane
# (one call kills the agent process too). Finally drop the now-unused task branch and
# prune the worktree registration so the source repo does not accumulate refs.
[ -d "$WT" ] && rm -f "$WT/.claude/settings.local.json" 2>/dev/null || true
"$FM_ROOT/bin/fm-backend.sh" kill "$HANDLE" "$WS" || true
git -C "$PROJ" worktree prune 2>/dev/null || true
git -C "$PROJ" branch -D "fm-$ID" >/dev/null 2>&1 || true
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta"
if [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (handle $HANDLE, worktree $WT)"
printf '%s\n' "🌱 Backlog: $ID just finished. Update data/backlog.md - move $ID to Done (keep Done to the 10 most recent), then re-scan Queued for items now unblocked (a \"blocked-by: $ID\" may have just cleared) or now time-due, and dispatch what's ready."
