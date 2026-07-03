#!/usr/bin/env bash
# Behavior tests for bin/fm-session-start.sh, the one-command session start:
#   (a) locked path: lock output, drain output, context files (present/ABSENT),
#       backlog, meta records with endpoint liveness + status tails, orphan
#       status logs, AFK absent, watcher next step; exits 0
#   (b) read-only path: lock refusal banner, drain skipped with queue length,
#       fm-guard still runs, read-only next step; exits 0
#   (c) endpoint liveness distinguishes a live pane from a dead one
#   (d) AFK present flips the next step to the daemon reminder
#   (e) CREW_DISPATCH diagnostics: none / active / invalid
#
# The real fm-session-start.sh is symlinked into a fake root's bin/ beside stub
# fm-lock/fm-wake-drain/fm-guard scripts (and the real fm-herdr-lib.sh it
# sources); a stub `herdr` on PATH serves pane existence. No live herdr, panes,
# locks, or queues are touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-start-tests.XXXXXX")

# make_case <name> [lock-rc] -> case dir with fake root; stubs record invocation.
make_case() {
  local d="$TMP_ROOT/$1" lock_rc=${2:-0} fakebin
  fakebin="$d/root/bin"
  mkdir -p "$d/root/state" "$d/root/data" "$d/root/config" "$fakebin"
  ln -s "$ROOT/bin/fm-session-start.sh" "$fakebin/fm-session-start.sh"
  ln -s "$ROOT/bin/fm-herdr-lib.sh" "$fakebin/fm-herdr-lib.sh"
  cat > "$fakebin/fm-lock.sh" <<SH
#!/usr/bin/env bash
echo "lock: stub holder"
exit $lock_rc
SH
  cat > "$fakebin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
touch "${FM_TEST_DRAIN_MARK:?}"
echo "drained: 1 record (stub)"
exit 0
SH
  cat > "$fakebin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_GUARD_MARK:-}" ] && touch "$FM_TEST_GUARD_MARK"
echo "guard: stub advisory" >&2
exit 0
SH
  # Stub herdr: pane get succeeds only for the id in FM_TEST_LIVE_PANE.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pane get")
    [ "${3:-}" = "${FM_TEST_LIVE_PANE:-}" ] && exit 0
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/fm-lock.sh" "$fakebin/fm-wake-drain.sh" "$fakebin/fm-guard.sh" "$fakebin/herdr"
  printf '%s\n' "$d"
}

run_session_start() {  # <case-dir>
  local d=$1
  PATH="$d/root/bin:$PATH" \
  FM_ROOT_OVERRIDE="$d/root" \
  FM_TEST_DRAIN_MARK="$d/drain.mark" \
  FM_TEST_GUARD_MARK="$d/guard.mark" \
  FM_TEST_LIVE_PANE="${FM_TEST_LIVE_PANE:-}" \
    "$d/root/bin/fm-session-start.sh"
}

test_locked_full_digest() {
  local d out rc
  d=$(make_case locked 0)
  echo "- proj-a [no-mistakes] - a project (added 2026-01-01)" > "$d/root/data/projects.md"
  echo "captain prefs" > "$d/root/data/captain.md"
  printf '## In flight\n- [ ] feat-a - do a thing (repo: proj-a, since 2026-01-01)\n' > "$d/root/data/backlog.md"
  cat > "$d/root/state/feat-a.meta" <<EOF
handle=p1
kind=ship
mode=no-mistakes
EOF
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/root/state/feat-a.status"
  printf 'done: old orphan event\n' > "$d/root/state/gone-z9.status"
  set +e
  out=$(FM_TEST_LIVE_PANE=p1 run_session_start "$d" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "locked: expected exit 0, got $rc"
  printf '%s' "$out" | grep -qF 'lock: stub holder' || fail "locked: lock output missing"
  printf '%s' "$out" | grep -qF 'drained: 1 record (stub)' || fail "locked: drain output missing"
  [ -e "$d/drain.mark" ] || fail "locked: fm-wake-drain was not invoked"
  printf '%s' "$out" | grep -qF 'proj-a [no-mistakes]' || fail "locked: projects.md content missing"
  printf '%s' "$out" | grep -qF 'captain prefs' || fail "locked: captain.md content missing"
  printf '%s' "$out" | grep -A2 'data/secondmates.md' | grep -qF 'ABSENT' || fail "locked: absent secondmates.md not flagged"
  printf '%s' "$out" | grep -qF -- '--- feat-a ---' || fail "locked: meta record missing"
  printf '%s' "$out" | grep -qF 'endpoint: alive (handle=p1)' || fail "locked: live endpoint not reported"
  printf '%s' "$out" | grep -qF 'needs-decision: pick A or B' || fail "locked: status tail missing"
  printf '%s' "$out" | grep -qF -- '--- gone-z9 ---' || fail "locked: orphan status log missing"
  printf '%s' "$out" | grep -qF 'bin/fm-watch-arm.sh' || fail "locked: watcher next step missing"
  printf '%s' "$out" | grep -qF 'READ-ONLY SESSION' && fail "locked: read-only banner should not appear"
  pass "locked session start prints the full ordered digest"
}

test_read_only_skips_drain() {
  local d out rc
  d=$(make_case readonly 1)
  printf 'x\ny\n' > "$d/root/state/.wake-queue"
  set +e
  out=$(run_session_start "$d" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "readonly: expected exit 0 (reporting command), got $rc"
  printf '%s' "$out" | grep -qF 'READ-ONLY SESSION' || fail "readonly: banner missing"
  printf '%s' "$out" | grep -qF 'skipped (read-only session) - 2 record(s)' || fail "readonly: queue length missing"
  [ ! -e "$d/drain.mark" ] || fail "readonly: fm-wake-drain must not run without the lock"
  [ -e "$d/guard.mark" ] || fail "readonly: fm-guard should still run"
  printf '%s' "$out" | grep -qF 'Stay read-only' || fail "readonly: read-only next step missing"
  pass "a read-only session skips the drain but still surfaces guard alarms"
}

test_dead_endpoint_reported() {
  local d out
  d=$(make_case dead-endpoint 0)
  cat > "$d/root/state/feat-b.meta" <<EOF
handle=p-dead
kind=ship
EOF
  out=$(run_session_start "$d" 2>&1) || fail "dead-endpoint: script failed"
  printf '%s' "$out" | grep -qF 'endpoint: dead (handle=p-dead)' || fail "dead-endpoint: dead pane not reported"
  pass "a dead pane is reported as a dead endpoint"
}

test_afk_flips_next_step() {
  local d out
  d=$(make_case afk 0)
  touch "$d/root/state/.afk"
  out=$(run_session_start "$d" 2>&1) || fail "afk: script failed"
  printf '%s' "$out" | grep -qF 'present - away-mode supervision is active' || fail "afk: presence not reported"
  printf '%s' "$out" | grep -qF 'load /afk' || fail "afk: daemon next step missing"
  printf '%s' "$out" | grep -qF 'bin/fm-watch-arm.sh' && fail "afk: normal watcher arm should not be suggested"
  pass "afk presence flips the next step to the daemon reminder"
}

test_dispatch_diagnostics() {
  local d out
  d=$(make_case dispatch-none 0)
  out=$(run_session_start "$d" 2>&1) || fail "dispatch: script failed"
  printf '%s' "$out" | grep -qF 'CREW_DISPATCH: none' || fail "dispatch: absent file not reported"

  d=$(make_case dispatch-active 0)
  echo '{"rules":[]}' > "$d/root/config/crew-dispatch.json"
  out=$(run_session_start "$d" 2>&1) || fail "dispatch-active: script failed"
  printf '%s' "$out" | grep -qF 'CREW_DISPATCH: active' || fail "dispatch: active policy not reported"
  printf '%s' "$out" | grep -qF '{"rules":[]}' || fail "dispatch: active rules not printed"

  d=$(make_case dispatch-invalid 0)
  echo '{broken' > "$d/root/config/crew-dispatch.json"
  out=$(run_session_start "$d" 2>&1) || fail "dispatch-invalid: script failed"
  printf '%s' "$out" | grep -qF 'CREW_DISPATCH: invalid' || fail "dispatch: invalid file not flagged"
  pass "crew-dispatch diagnostics report none, active, and invalid states"
}

test_locked_full_digest
test_read_only_skips_drain
test_dead_endpoint_reported
test_afk_flips_next_step
test_dispatch_diagnostics
