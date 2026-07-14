#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling on the herdr backend.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / no-origin paths
# must be unchanged. Each test runs fleet-sync against an isolated FM_HOME, which
# also pins the FM_HOME projects/ resolution (a secondmate home syncs its own
# clones, not the primary's). Upstream's bootstrap-relay case has no analogue
# here: this fork has no fm-bootstrap; fleet-sync output flows through fm-spawn
# and fm-teardown directly.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-sync-tests.XXXXXX")

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; esac; }

HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

# run_sync_err <home> [args...]: like run_sync but returns combined stdout+stderr,
# so the packed-refs recovery messages (which go to stderr) are visible.
run_sync_err() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>&1
}

# #453: a git ref rewrite killed mid-write can strand a .git/packed-refs.lock
# that fails every later fetch that must rewrite packed-refs (e.g. pruning a
# packed remote-tracking ref). fleet-sync retries, then removes a PROVABLY-STALE
# lock (old mtime, no live holder) and completes the sync.
test_packed_refs_lock_recovered_when_stale() {
  local home clone out
  command -v lsof >/dev/null 2>&1 || { pass "packed-refs recovery test skipped (no lsof)"; return; }
  home=$(new_home)
  clone=$(build_pair "$home" prlock)
  # Give the clone a packed remote-tracking ref to prune: branch on origin,
  # fetch it, pack all refs, then delete it on origin so the next prune must
  # rewrite the packed-refs file (which is what contends packed-refs.lock).
  git -C "$home/work-prlock" branch feature
  git -C "$home/work-prlock" push -q origin feature
  git -C "$clone" fetch -q origin
  git -C "$clone" pack-refs --all
  git -C "$home/work-prlock" push -q origin :feature
  # Strand a packed-refs.lock with no holder; age threshold 0 makes it provably
  # stale immediately (the age check exists only to skip a just-created lock).
  : > "$clone/.git/packed-refs.lock"

  out=$(FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
        FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
        FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0.1 \
        run_sync_err "$home" "$clone")

  assert_contains "$out" "removed provably-stale packed-refs lock" "stale packed-refs lock is removed"
  assert_not_contains "$out" "skipped: fetch failed" "recovered fetch is not reported as a failed skip"
  [ ! -e "$clone/.git/packed-refs.lock" ] || fail "packed-refs lock still present after recovery"
  [ -z "$(git -C "$clone" for-each-ref refs/remotes/origin/feature 2>/dev/null)" ] \
    || fail "origin/feature was not pruned, so the fetch did not actually complete"
  pass "a stale packed-refs lock is cleared and the fetch recovers (#453)"
}

# A packed-refs lock held by a LIVE process must never be removed.
test_packed_refs_lock_live_holder_left_untouched() {
  local home clone out
  command -v lsof >/dev/null 2>&1 || { pass "packed-refs live-holder test skipped (no lsof)"; return; }
  home=$(new_home)
  clone=$(build_pair "$home" prlive)
  git -C "$home/work-prlive" branch feature
  git -C "$home/work-prlive" push -q origin feature
  git -C "$clone" fetch -q origin
  git -C "$clone" pack-refs --all
  git -C "$home/work-prlive" push -q origin :feature
  # This test process holds the lock file open on fd 9, so lsof sees a live
  # holder and the lock is NOT provably stale.
  exec 9>"$clone/.git/packed-refs.lock"

  out=$(FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
        FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
        FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0.1 \
        run_sync_err "$home" "$clone")
  exec 9>&-

  assert_contains "$out" "not provably stale" "a live-held packed-refs lock is left in place"
  [ -e "$clone/.git/packed-refs.lock" ] || fail "a live-held packed-refs lock must not be removed"
  pass "a packed-refs lock with a live holder is never removed (#453)"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument. Scans the home's own projects/.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under the home's projects/"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_packed_refs_lock_recovered_when_stale
test_packed_refs_lock_live_holder_left_untouched
test_whole_fleet_form

echo "all fm-fleet-sync tests passed"
