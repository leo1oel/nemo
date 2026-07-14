#!/usr/bin/env bash
# Behavior tests for the watcher's event-accelerated poll sleep (fork #472,
# bin/fm-fastwake-lib.sh).
#
# fm_fastwake_sleep is a drop-in for `sleep <POLL>` that returns early when a live
# crewmate pane hits the herdr blocked status (via the native `herdr wait
# agent-status`), and is fail-safe to a plain sleep otherwise. This suite proves,
# with a stubbed herdr: the fail-safe paths (disabled, no native wait, no live
# panes, secondmate-only), the early return on a blocked pane, the busy-spin
# floor, and the plain-sleep timeout when nothing blocks. No real herdr is used.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-fastwake-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fastwake.XXXXXX")

# A stub herdr: `wait --help` advertises agent-status (so the native path is
# "available"); `wait agent-status <pane> ...` records the call to
# FM_FAKE_HERDR_MARKER and exits 0 (blocked) iff <pane> == FM_FAKE_BLOCKED_PANE,
# else 1 (a timeout / no transition). FM_FAKE_NO_WAIT drops the agent-status
# advertisement so the availability probe fails.
make_herdr() {
  local dir=$1 hb
  hb="$dir/herdrbin"; mkdir -p "$hb"
  cat > "$hb/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = wait ] && [ "${2:-}" = --help ]; then
  [ -n "${FM_FAKE_NO_WAIT:-}" ] || printf '  herdr wait agent-status <pane_id> --status ...\n'
  exit 0
fi
if [ "${1:-}" = wait ] && [ "${2:-}" = agent-status ]; then
  printf 'agent-status %s\n' "${3:-}" >> "${FM_FAKE_HERDR_MARKER:-/dev/null}"
  [ "${3:-}" = "${FM_FAKE_BLOCKED_PANE:-}" ] && exit 0
  exit 1
fi
exit 0
SH
  chmod +x "$hb/herdr"
  printf '%s\n' "$hb"
}

# A state dir with a live ship crewmate (handle=%7).
make_ship_state() {
  local st=$1
  mkdir -p "$st"
  printf 'handle=%%7\nkind=ship\n' > "$st/pick-x2.meta"
  printf '%s\n' "$st"
}

# run_fastwake <secs> <state> <herdrbin> [ASSIGN...] -> prints elapsed integer secs
run_fastwake() {
  local secs=$1 state=$2 hb=$3; shift 3
  local t0 t1
  t0=$(date +%s)
  # shellcheck disable=SC2016  # $1/$2/$3 are the inner bash -c positionals, deliberately unexpanded here
  env "PATH=$hb:$PATH" "$@" bash -c '. "$1"; fm_fastwake_sleep "$2" "$3"' _ "$LIB" "$secs" "$state" >/dev/null 2>&1
  t1=$(date +%s)
  echo $(( t1 - t0 ))
}

HB=$(make_herdr "$TMP")

test_disabled_is_plain_sleep() {
  local st marker e
  st=$(make_ship_state "$TMP/s-disabled")
  marker="$TMP/m-disabled"
  e=$(run_fastwake 1 "$st" "$HB" FM_FASTWAKE=0 "FM_FAKE_HERDR_MARKER=$marker")
  [ "$e" -ge 1 ] || fail "FM_FASTWAKE=0 should still sleep the full interval (elapsed ${e}s)"
  [ ! -e "$marker" ] || fail "FM_FASTWAKE=0 must not invoke herdr at all"
  pass "fm-fastwake: FM_FASTWAKE=0 is a plain sleep, no herdr call"
}

test_no_native_wait_is_plain_sleep() {
  local st marker e
  st=$(make_ship_state "$TMP/s-nonative")
  marker="$TMP/m-nonative"
  e=$(run_fastwake 1 "$st" "$HB" FM_FAKE_NO_WAIT=1 "FM_FAKE_HERDR_MARKER=$marker")
  [ "$e" -ge 1 ] || fail "no native wait should sleep the full interval (elapsed ${e}s)"
  [ ! -e "$marker" ] || fail "without agent-status support the wait must never be launched"
  pass "fm-fastwake: a herdr without 'wait agent-status' falls back to a plain sleep"
}

test_no_live_panes_is_plain_sleep() {
  local st marker e
  st="$TMP/s-empty"; mkdir -p "$st"   # no metas
  marker="$TMP/m-empty"
  e=$(run_fastwake 1 "$st" "$HB" "FM_FAKE_HERDR_MARKER=$marker")
  [ "$e" -ge 1 ] || fail "no live panes should sleep the full interval (elapsed ${e}s)"
  [ ! -e "$marker" ] || fail "with no live crewmate panes the wait must never be launched"
  pass "fm-fastwake: no live crewmate panes falls back to a plain sleep"
}

test_secondmate_excluded() {
  local st marker e
  st="$TMP/s-second"; mkdir -p "$st"
  printf 'handle=%%9\nkind=secondmate\n' > "$st/dom-a1.meta"
  marker="$TMP/m-second"
  e=$(run_fastwake 1 "$st" "$HB" "FM_FAKE_HERDR_MARKER=$marker")
  [ "$e" -ge 1 ] || fail "a secondmate-only fleet should sleep the full interval (elapsed ${e}s)"
  [ ! -e "$marker" ] || fail "a secondmate pane must be excluded from the blocked-status wait"
  pass "fm-fastwake: secondmate panes are excluded (parent supervises them by status, not pane)"
}

test_early_return_on_blocked() {
  local st marker e
  st=$(make_ship_state "$TMP/s-early")
  marker="$TMP/m-early"
  # secs=4 but the pane is blocked, so it returns early; the floor (2) still applies.
  e=$(run_fastwake 4 "$st" "$HB" FM_FASTWAKE_FLOOR=2 FM_FAKE_BLOCKED_PANE=%7 "FM_FAKE_HERDR_MARKER=$marker")
  [ "$e" -le 3 ] || fail "a blocked pane must return before the full 4s poll (elapsed ${e}s)"
  [ "$e" -ge 1 ] || fail "the busy-spin floor should hold the cycle to at least ~1s (elapsed ${e}s)"
  grep -q 'agent-status %7' "$marker" || fail "the blocked-status wait should have been launched for the live pane"
  pass "fm-fastwake: returns early on a blocked pane, floored against busy-spin"
}

test_timeout_when_nothing_blocks() {
  local st e
  st=$(make_ship_state "$TMP/s-timeout")
  # No pane matches FM_FAKE_BLOCKED_PANE, so every waiter times out -> full sleep.
  e=$(run_fastwake 3 "$st" "$HB" FM_FAKE_BLOCKED_PANE=%none)
  [ "$e" -ge 3 ] || fail "with nothing blocked it must sleep the full interval (elapsed ${e}s)"
  pass "fm-fastwake: sleeps the full poll interval when no pane blocks"
}

test_disabled_is_plain_sleep
test_no_native_wait_is_plain_sleep
test_no_live_panes_is_plain_sleep
test_secondmate_excluded
test_early_return_on_blocked
test_timeout_when_nothing_blocks
