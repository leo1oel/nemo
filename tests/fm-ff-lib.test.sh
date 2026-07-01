#!/usr/bin/env bash
# Behavior tests for bin/fm-ff-lib.sh's local-HEAD fast-forward path: the
# secondmate sync to the primary checkout's HEAD.
#   - primary_head_commit reads the default-branch ref (not HEAD), so a tangled
#     primary still yields the true default tip.
#   - ff_target with a commit base advances a behind home, no fetch, no origin.
#   - guards hold: already-current, dirty, diverged, wrong-branch are skipped and
#     leave the home untouched.
#   - a home carrying BOTH herdr seed markers (.fm-secondmate-home and
#     .fm-secondmate-home.workspace) is treated as clean (the marker-leak fix).
# All hermetic over temp git repos; a home is a real worktree of its primary, so
# it shares the object store and the local commit is always present.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ff-lib-tests.XXXXXX")

# The lib's validators read FM_ROOT/FM_HOME (at call time); export so they are
# unambiguously in use. ff_target and primary_head_commit take their dir explicitly.
export FM_ROOT="$TMP_ROOT" FM_HOME="$TMP_ROOT"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
gitq() { git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# Run ff_target WITHOUT a command substitution so its FF_STATUS/FF_INSTR globals
# survive into the caller (a `$(...)` capture would set them in a lost subshell).
# Output lands in $FFOUT.
FFOUT=""
run_ff() {
  ff_target "$@" >"$TMP_ROOT/.ffout" 2>&1
  FFOUT=$(cat "$TMP_ROOT/.ffout")
}

# A primary repo on main with one commit. Echoes its path.
make_primary() {
  local dir=$1
  git init -q -b main "$dir"
  gitq "$dir" commit -q --allow-empty -m c1
  printf '%s\n' "$dir"
}
head_of() { git -C "$1" rev-parse "${2:-HEAD}"; }

# --- primary_head_commit ----------------------------------------------------

test_primary_head_commit_reads_default_ref() {
  local primary main_c
  primary=$(make_primary "$TMP_ROOT/phc")
  main_c=$(head_of "$primary" refs/heads/main)
  [ "$(primary_head_commit "$primary")" = "$main_c" ] || fail "primary_head_commit did not return main's tip"

  # Even with the primary stranded on a feature branch, the default-branch ref tip
  # (not the feature HEAD) is what propagates to the fleet.
  gitq "$primary" commit -q --allow-empty -m c2
  main_c=$(head_of "$primary" refs/heads/main)
  gitq "$primary" checkout -q -B fm/tangle
  gitq "$primary" commit -q --allow-empty -m stray
  [ "$(primary_head_commit "$primary")" = "$main_c" ] || fail "primary_head_commit followed the feature branch, not main"
  pass "primary_head_commit returns the default-branch tip, even on a tangled primary"
}

# --- local-HEAD ff: advance / current / no-fetch ----------------------------

# A home worktree of the primary, detached at the primary's FIRST commit (behind).
# No origin remote anywhere, so a successful ff proves the local base needs no fetch.
make_behind_home() {
  local primary=$1 home=$2 first
  first=$(git -C "$primary" rev-list --max-parents=0 HEAD | tail -1)
  git -C "$primary" worktree add -q --detach "$home" "$first" >/dev/null 2>&1
}

test_localhead_advances_behind_home_without_fetch() {
  local primary home base
  primary=$(make_primary "$TMP_ROOT/adv")
  gitq "$primary" commit -q --allow-empty -m c2
  base=$(primary_head_commit "$primary")
  make_behind_home "$primary" "$TMP_ROOT/adv-home"

  run_ff "$TMP_ROOT/adv-home" "secondmate x1" "$base" "" yes yes
  [ "$FF_STATUS" = updated ] || fail "behind home was not fast-forwarded (status=$FF_STATUS): $FFOUT"
  [ "$(head_of "$TMP_ROOT/adv-home")" = "$base" ] || fail "home HEAD did not reach the primary base"
  git -C "$TMP_ROOT/adv-home" remote get-url origin >/dev/null 2>&1 && fail "test home unexpectedly had an origin remote"
  pass "local-HEAD ff advances a behind home with no origin and no fetch"
}

test_localhead_current_home_is_noop() {
  local primary home base
  primary=$(make_primary "$TMP_ROOT/cur")
  base=$(primary_head_commit "$primary")
  git -C "$primary" worktree add -q --detach "$TMP_ROOT/cur-home" "$base" >/dev/null 2>&1
  run_ff "$TMP_ROOT/cur-home" "secondmate x1" "$base" "" yes yes
  [ "$FF_STATUS" = current ] || fail "home already at base should be 'current' (status=$FF_STATUS): $FFOUT"
  pass "local-HEAD ff reports a home already at the primary base as current"
}

# --- guards: dirty (incl. two-marker fix), diverged, wrong branch -----------

test_localhead_two_markers_are_clean() {
  local primary base
  primary=$(make_primary "$TMP_ROOT/marks")
  gitq "$primary" commit -q --allow-empty -m c2
  base=$(primary_head_commit "$primary")
  make_behind_home "$primary" "$TMP_ROOT/marks-home"
  # Both herdr seed markers, exactly as fm-home-seed.sh leaves them (untracked).
  printf 'x1\n'   > "$TMP_ROOT/marks-home/.fm-secondmate-home"
  printf 'ws-1\n' > "$TMP_ROOT/marks-home/.fm-secondmate-home.workspace"
  run_ff "$TMP_ROOT/marks-home" "secondmate x1" "$base" "" yes yes
  [ "$FF_STATUS" = updated ] || fail "home with only the two seed markers must be clean, was skipped: $FFOUT"
  pass "local-HEAD ff treats a home holding only the two herdr seed markers as clean"
}

test_localhead_real_dirty_is_skipped() {
  local primary base
  primary=$(make_primary "$TMP_ROOT/dirty")
  gitq "$primary" commit -q --allow-empty -m c2
  base=$(primary_head_commit "$primary")
  make_behind_home "$primary" "$TMP_ROOT/dirty-home"
  printf 'x1\n' > "$TMP_ROOT/dirty-home/.fm-secondmate-home"
  printf 'real work\n' > "$TMP_ROOT/dirty-home/local.txt"   # genuine uncommitted work
  run_ff "$TMP_ROOT/dirty-home" "secondmate x1" "$base" "" yes yes
  [ "$FF_STATUS" = skipped ] || fail "dirty home should be skipped (status=$FF_STATUS): $FFOUT"
  case "$FFOUT" in *'dirty working tree'*) : ;; *) fail "skip reason was not 'dirty working tree': $FFOUT" ;; esac
  [ -f "$TMP_ROOT/dirty-home/local.txt" ] || fail "skipped home lost its uncommitted work"
  pass "local-HEAD ff skips a genuinely dirty home and preserves its work"
}

test_localhead_diverged_is_skipped() {
  local primary base before
  primary=$(make_primary "$TMP_ROOT/div")
  gitq "$primary" commit -q --allow-empty -m c2
  base=$(primary_head_commit "$primary")
  make_behind_home "$primary" "$TMP_ROOT/div-home"
  gitq "$TMP_ROOT/div-home" commit -q --allow-empty -m "home-only divergent commit"
  before=$(head_of "$TMP_ROOT/div-home")
  run_ff "$TMP_ROOT/div-home" "secondmate x1" "$base" "" yes yes
  [ "$FF_STATUS" = skipped ] || fail "diverged home should be skipped (status=$FF_STATUS): $FFOUT"
  [ "$(head_of "$TMP_ROOT/div-home")" = "$before" ] || fail "diverged home HEAD was moved"
  pass "local-HEAD ff skips a diverged home and never force-moves it"
}

test_localhead_lease_branch_accepted() {
  local primary first base
  primary=$(make_primary "$TMP_ROOT/lease")
  first=$(git -C "$primary" rev-list --max-parents=0 HEAD | tail -1)
  gitq "$primary" commit -q --allow-empty -m c2
  base=$(primary_head_commit "$primary")
  # Home on its lease branch secondmate-x1, behind the primary.
  git -C "$primary" worktree add -q -b secondmate-x1 "$TMP_ROOT/lease-home" "$first" >/dev/null 2>&1
  run_ff "$TMP_ROOT/lease-home" "secondmate x1" "$base" "secondmate-x1" yes yes
  [ "$FF_STATUS" = updated ] || fail "home on its lease branch should be accepted and ff'd (status=$FF_STATUS): $FFOUT"
  [ "$(git -C "$TMP_ROOT/lease-home" symbolic-ref --short HEAD)" = secondmate-x1 ] || fail "lease branch was not preserved"
  pass "local-HEAD ff accepts and advances a home on its secondmate-<id> lease branch"
}

test_primary_head_commit_reads_default_ref
test_localhead_advances_behind_home_without_fetch
test_localhead_current_home_is_noop
test_localhead_two_markers_are_clean
test_localhead_real_dirty_is_skipped
test_localhead_diverged_is_skipped
test_localhead_lease_branch_accepted
