#!/usr/bin/env bash
# Behavior tests for bin/fm-turnend-guard.sh, the Claude Code Stop-hook backstop
# for primary turn-end supervision:
#   (a) empty/absent stdin payload -> allow (exit 0), never block blind
#   (b) stop_hook_active=true -> allow (the once-per-turn loop guard)
#   (c) non-primary scopes are silent no-ops: secondmate home marker, linked
#       worktree (git-dir != git-common-dir)
#   (d) no tasks in flight -> allow
#   (e) in flight + fresh watcher beacon -> allow
#   (f) in flight + stale/missing beacon -> BLOCK (exit 2) with the banner
#   (g) afk: live daemon pid -> allow; dead daemon -> BLOCK with the afk hint
#   (h) tracked .claude/settings.json anchors the hook via $CLAUDE_PROJECT_DIR
#
# The real script runs via a fake-root symlink (its FM_ROOT resolves from
# BASH_SOURCE), with real throwaway git repos for the primary/worktree scoping.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-turnend-guard-tests.XXXXXX")

PAYLOAD_IDLE='{"session_id":"s1","stop_hook_active":false}'
PAYLOAD_LOOP='{"session_id":"s1","stop_hook_active":true}'

# make_case <name> -> a fake PRIMARY root: its own git repo (main checkout, so
# git-dir == git-common-dir), AGENTS.md, bin/ with the real guard symlinked,
# and an empty state/.
make_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/root/bin" "$d/root/state"
  git -C "$d/root" init -q
  git -C "$d/root" commit -q --allow-empty -m init
  echo agents > "$d/root/AGENTS.md"
  ln -s "$ROOT/bin/fm-turnend-guard.sh" "$d/root/bin/fm-turnend-guard.sh"
  printf '%s\n' "$d"
}

run_guard() {  # <case-dir> <payload>
  printf '%s' "$2" | "$1/root/bin/fm-turnend-guard.sh" 2> "$1/stderr"
}

add_task() {  # <case-dir> <id>
  printf 'handle=p1\nkind=ship\n' > "$1/root/state/$2.meta"
}

test_empty_payload_allows() {
  local d rc
  d=$(make_case empty-payload)
  add_task "$d" t1
  set +e; printf '' | "$d/root/bin/fm-turnend-guard.sh" 2> "$d/stderr"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "empty payload must fail open, got $rc"
  pass "an empty Stop payload never blocks"
}

test_loop_guard_allows() {
  local d rc
  d=$(make_case loop-guard)
  add_task "$d" t1
  set +e; run_guard "$d" "$PAYLOAD_LOOP"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "stop_hook_active=true must allow the stop, got $rc"
  pass "stop_hook_active bounds blocking to once per turn"
}

test_non_primary_scopes_noop() {
  local d rc
  d=$(make_case secondmate-home)
  add_task "$d" t1
  printf 'sm-x' > "$d/root/.fm-secondmate-home"
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "secondmate home must be a no-op, got $rc"

  d=$(make_case linked-worktree)
  add_task "$d" t1
  git -C "$d/root" worktree add -q "$d/wt" -b side >/dev/null 2>&1
  mkdir -p "$d/wt/bin" "$d/wt/state"
  cp "$d/root/AGENTS.md" "$d/wt/AGENTS.md" 2>/dev/null || true
  ln -sf "$ROOT/bin/fm-turnend-guard.sh" "$d/wt/bin/fm-turnend-guard.sh"
  printf 'handle=p1\n' > "$d/wt/state/t2.meta"
  set +e; printf '%s' "$PAYLOAD_IDLE" | "$d/wt/bin/fm-turnend-guard.sh" 2>/dev/null; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "linked worktree must be a no-op, got $rc"
  pass "secondmate homes and linked worktrees are silent no-ops"
}

test_no_tasks_allows() {
  local d rc
  d=$(make_case no-tasks)
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "no in-flight tasks must allow, got $rc"
  pass "an empty fleet never blocks a turn end"
}

test_fresh_beacon_allows() {
  local d rc
  d=$(make_case fresh-beacon)
  add_task "$d" t1
  touch "$d/root/state/.last-watcher-beat"
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "fresh beacon must allow, got $rc"
  pass "a fresh watcher beacon allows the turn end"
}

test_stale_beacon_blocks() {
  local d rc
  d=$(make_case stale-beacon)
  add_task "$d" t1
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 2 ] || fail "missing beacon with tasks in flight must block (exit 2), got $rc"
  grep -qF 'TURN WOULD END BLIND' "$d/stderr" || fail "block banner missing"
  grep -qF 'fm-watch-arm.sh' "$d/stderr" || fail "block did not name the re-arm command"

  touch "$d/root/state/.last-watcher-beat"
  set +e; FM_GUARD_GRACE=0 run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 2 ] || fail "stale beacon past grace must block, got $rc"
  pass "tasks in flight with no fresh beacon block the turn end with the banner"
}

test_afk_daemon_liveness() {
  local d rc
  d=$(make_case afk-live)
  add_task "$d" t1
  touch "$d/root/state/.afk"
  printf '%s' "$$" > "$d/root/state/.supervise-daemon.pid"
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "afk with a live daemon must allow, got $rc"

  d=$(make_case afk-dead)
  add_task "$d" t1
  touch "$d/root/state/.afk"
  printf '999999' > "$d/root/state/.supervise-daemon.pid"
  set +e; run_guard "$d" "$PAYLOAD_IDLE"; rc=$?; set -e
  [ "$rc" -eq 2 ] || fail "afk with a dead daemon must block, got $rc"
  grep -qF 'daemon is dead' "$d/stderr" || fail "afk block did not explain the dead daemon"
  pass "away mode judges the daemon pid: live allows, dead blocks"
}

test_settings_json_anchored() {
  # The JSON string carries backslash-escaped quotes: \"$CLAUDE_PROJECT_DIR\"/bin/...
  # shellcheck disable=SC2016  # literal, must not expand
  grep -qF '\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh' "$ROOT/.claude/settings.json" \
    || fail "tracked .claude/settings.json must anchor the hook via \$CLAUDE_PROJECT_DIR (Claude Code runs hooks from the session cwd)"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/.claude/settings.json" \
    || fail ".claude/settings.json is not valid JSON"
  pass "the tracked Stop hook is registered and anchored to the project root"
}

test_empty_payload_allows
test_loop_guard_allows
test_non_primary_scopes_noop
test_no_tasks_allows
test_fresh_beacon_allows
test_stale_beacon_blocks
test_afk_daemon_liveness
test_settings_json_anchored
