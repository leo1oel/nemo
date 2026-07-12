#!/usr/bin/env bash
# Behavior tests for the always-on watcher's in-bash wake triage on the herdr
# backend: bin/fm-watch.sh + the shared classifier bin/fm-classify-lib.sh.
#
# The watcher absorbs benign wakes (advance the suppression marker, log, keep
# blocking) and queues+exits only on actionable ones. The no-verb turn-end /
# non-terminal-stale path is absorb-only-when-provably-working: absorbed only when
# the crew shows positive evidence it is still working (an actively-running
# no-mistakes step or a busy pane, read via fm-crew-state.sh), surfaced otherwise.
#
# These cases pin the pure classifier predicates and then run a real fm-watch.sh
# subprocess (hermetic: a fake `herdr` serves pane reads through fm-backend.sh, a
# fake fm-crew-state.sh serves the provably-working verdict via FM_CREW_STATE_BIN):
#   - captain-relevant signal            -> surfaced (queue + exit), marked surfaced
#   - no-verb signal, provably working   -> absorbed (no queue, keeps blocking)
#   - no-verb signal, NOT working         -> surfaced
#   - terminal stale                      -> surfaced
#   - non-terminal stale, provably working -> absorbed + wedge timer, then escalates
#   - non-terminal stale, NOT working      -> surfaced immediately (never waits the timer)
#   - wedge escalation                     -> exactly once per stall episode
#   - surfaced stale                       -> no follow-up wedge nag for the same episode
#   - footer-only tick                     -> staleness hash and bookkeeping unchanged
#   - heartbeat no-change                  -> absorbed; backstop surfaces an unsurfaced status
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-watch-triage-tests.XXXXXX")
# fm-wake-drain calls fm-guard.sh (watcher-liveness); pin its tangle check at this
# non-git temp root so the ambient feature-branch checkout never leaks a banner.
export FM_ROOT_OVERRIDE="$TMP_ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac; }

# A case dir with state/ and a fakebin holding a fake `herdr` (pane read serves
# FM_FAKE_PANE_CAPTURE, the watcher's staleness loop reaches it via fm-backend.sh)
# and a fake fm-crew-state.sh (serves a canned provably-working verdict).
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "read" ]; then
  [ -n "${FM_FAKE_PANE_CAPTURE:-}" ] && cat "$FM_FAKE_PANE_CAPTURE"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

# Portable mtime + size:mtime signature, platform-detected (never the stat -f||-c
# fallback, which dumps a partial filesystem listing on Linux; see fm-watch.sh).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}
hash_stdin() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}
# Mirror fm-watch.sh's staleness hash for seeding pane bookkeeping: strip blank
# lines, drop the trailing 6-line footer window (the ticking TUI footer the
# busy regex scans), hash the rest.
stale_hash_of() {  # <pane-text>
  printf '%s' "$1" | grep -v '^[[:space:]]*$' | awk '{ l[NR] = $0 } END { for (i = 1; i <= NR - 6; i++) print l[i] }' | hash_stdin
}

wait_for_exit() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  return 124
}
wait_live() {  # <pid> [limit-ticks]: 0 if still alive after the wait, 1 if it died
  local pid=$1 limit=${2:-25} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1; i=$((i + 1))
  done
  return 0
}
wait_numeric_file() {  # <file> [limit-ticks]
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in ''|*[!0-9]*) ;; *) return 0 ;; esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: compiling\n' > "$state/a.status"
  printf 'done: PR https://x/pr/1\n' > "$state/b.status"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/b.status" || fail "captain-verb status not actionable"
  if signal_reason_is_actionable "$state/a.status"; then fail "no-verb status wrongly actionable"; fi
  if signal_reason_is_actionable "$state/c.turn-ended"; then fail "turn-ended marker wrongly actionable"; fi
  pass "signal_reason_is_actionable keys on a captain-relevant verb, skips no-verb + turn-ended"
}

test_crew_is_provably_working() {
  local dir fakebin
  dir=$(make_case classify-working); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' crew_is_provably_working x \
    || fail "working+run-step should be provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' crew_is_provably_working x \
    || fail "working+pane should be provably working"
  if FM_FAKE_CREW_STATE='state: working · source: status-log · working: note' crew_is_provably_working x; then
    fail "working from a stale status-log line must NOT be provably working"
  fi
  if FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review' crew_is_provably_working x; then
    fail "parked must NOT be provably working"
  fi
  if FM_FAKE_CREW_STATE='state: unknown · source: none · gone' crew_is_provably_working x; then
    fail "unknown must NOT be provably working"
  fi
  unset FM_CREW_STATE_BIN
  pass "crew_is_provably_working: working from run-step/pane only, never status-log/parked/unknown"
}

test_signal_crew_provably_working() {
  local dir fakebin
  dir=$(make_case classify-sig-working); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: working · source: pane · harness busy'
  signal_crew_provably_working "$dir/a.status" "$dir/b.turn-ended" \
    || fail "all-working signal should be absorbable"
  export FM_FAKE_CREW_STATE_b='state: unknown · source: none · gone'
  if signal_crew_provably_working "$dir/a.status" "$dir/b.status"; then
    fail "a not-working member must make the signal not-absorbable"
  fi
  if signal_crew_provably_working; then fail "an empty signal list must surface (return 1)"; fi
  unset FM_CREW_STATE_BIN FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: absorb only when EVERY referenced crew is provably working"
}

test_stale_is_terminal() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: PR https://x/pr/2\n' > "$state/fin.status"
  stale_is_terminal "fm-fin" "$state" || fail "captain-verb status should be terminal stale"
  if stale_is_terminal "fm-none" "$state"; then fail "missing status must be non-terminal"; fi
  printf 'working: still going\n' > "$state/wip.status"
  if stale_is_terminal "fm-wip" "$state"; then fail "no-verb status must be non-terminal"; fi
  pass "stale_is_terminal keys on a captain-relevant last status line"
}

# --- behavioral: captain-relevant signal is surfaced ------------------------

test_captain_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case captain-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  assert_contains "$(cat "$out")" "signal: $status_file" "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# --- behavioral: no-verb signal, crew provably working -> absorbed ----------

test_noverb_signal_provably_working_absorbed() {
  local dir state fakebin out status_file pid seen
  dir=$(make_case noverb-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher exited for a provably-working no-verb signal (should absorb): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "absorbed signal printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "absorbed signal enqueued a wake"; }
  seen=$(cat "$state/.seen-task_status" 2>/dev/null || true)
  [ -n "$seen" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "absorbed signal did not advance the .seen marker"; }
  grep -F "absorbed benign" "$state/.watch-triage.log" >/dev/null 2>&1 || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "absorb was not logged to the triage log"; }
  [ -s "$state/.hb-surfaced-task" ] && { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "an absorbed signal must not record a surfaced marker"; }
  reap "$pid"; unset FM_FAKE_CREW_STATE
  pass "no-verb signal whose crew is provably working is absorbed (no queue, no exit)"
}

# --- behavioral: no-verb signal, crew NOT provably working -> surfaced ------

test_noverb_signal_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case noverb-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; status_file="$state/task.status"
  printf 'working: implementing\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { unset FM_FAKE_CREW_STATE; fail "watcher did not surface a no-verb signal whose crew is not provably working"; }
  assert_contains "$(cat "$out")" "signal: $status_file" "watcher did not print the surfaced signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || { unset FM_FAKE_CREW_STATE; fail "drain failed"; }
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "surfaced no-verb signal was not queued"; }
  unset FM_FAKE_CREW_STATE
  pass "no-verb signal whose crew is NOT provably working is surfaced (the swallowed-finish guard)"
}

# --- behavioral: terminal stale -> surfaced ---------------------------------

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file id w key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  id="done"; w="fm-$id"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  pane_hash=$(stale_hash_of "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $w" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$w" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- behavioral: terminal-looking stale log OVERRIDDEN by an active run --------
# A crew's status log gets no new entry once firstmate hands it to a no-mistakes
# validation, so its last line can stay a pre-validation "done:" for the whole
# run. A provably-working crew must absorb that stale (with a wedge timer), not
# surface as terminal every poll.

test_terminal_stale_provably_working_overridden() {
  local dir state fakebin out drain_out capture_file id w key pane_hash sig pid
  dir=$(make_case terminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  id="valid"; w="fm-$id"
  printf 'validating quietly' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'done: implemented, handing to validation\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  pane_hash=$(stale_hash_of "validating quietly")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: provably working overrides the captain-relevant log line -> absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher surfaced a provably-working crew as terminal stale (should absorb): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "overridden terminal stale printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "overridden terminal stale enqueued a wake"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "stale suppressor not advanced on the override"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "wedge timer was not recorded on the override"; }
  grep -F "overriding a stale captain-relevant status" "$state/.watch-triage.log" >/dev/null 2>&1 \
    || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "override was not logged to the triage log"; }
  reap "$pid"

  # Phase B: backdate the wedge timer past the threshold -> next run escalates
  # even though the log line is still captain-relevant.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { unset FM_FAKE_CREW_STATE; fail "watcher did not wedge-escalate an overridden terminal stale past the threshold"; }
  assert_contains "$(cat "$out")" "stale: $w" "override escalation did not print a stale wake"
  assert_contains "$(cat "$out")" "possible wedge" "override escalation did not flag a possible wedge"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || { unset FM_FAKE_CREW_STATE; fail "drain after the override escalation failed"; }
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$w" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "override escalation was not queued"; }
  unset FM_FAKE_CREW_STATE
  pass "a terminal-looking stale log is overridden while the crew provably works, then wedge-escalates"
}

# --- behavioral: non-terminal stale, provably working -> absorb then escalate ---

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file id w key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  id="quiet"; w="fm-$id"
  printf 'idle building output' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'working: still compiling\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  pane_hash=$(stale_hash_of "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: high threshold -> first sighting absorbed, wedge timer started.
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "fresh provably-working stale printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "fresh provably-working stale enqueued a wake"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "stale suppressor not advanced on absorb"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "wedge timer was not recorded on absorb"; }
  reap "$pid"

  # Phase B: backdate the wedge timer past the threshold -> next run escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { unset FM_FAKE_CREW_STATE; fail "watcher did not escalate a provably-working stale past the threshold"; }
  assert_contains "$(cat "$out")" "stale: $w" "escalation did not print a stale wake"
  assert_contains "$(cat "$out")" "possible wedge" "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || { unset FM_FAKE_CREW_STATE; fail "wedge timer not cleared after escalation"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || { unset FM_FAKE_CREW_STATE; fail "drain after the wedge escalation failed"; }
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$w" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "wedge escalation was not queued"; }
  unset FM_FAKE_CREW_STATE
  pass "provably-working non-terminal stale is absorbed first, then wedge-escalated past the threshold"
}

# --- behavioral: non-terminal stale, NOT provably working -> surfaced at once ---

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file id w key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  id="stopped"; w="fm-$id"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'working: implementing\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  pane_hash=$(stale_hash_of "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || { unset FM_FAKE_CREW_STATE; fail "watcher did not surface a not-provably-working non-terminal stale at once"; }
  grep -Fx "stale: $w" "$out" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "watcher did not print the immediate stale wake"; }
  if grep -F "possible wedge" "$out" >/dev/null; then unset FM_FAKE_CREW_STATE; fail "an immediate stopped-crew stale was mislabeled a wedge"; fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || { unset FM_FAKE_CREW_STATE; fail "stale suppressor was not advanced on surface"; }
  [ ! -e "$state/.stale-since-$key" ] || { unset FM_FAKE_CREW_STATE; fail "wedge timer should not be set when surfacing immediately"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || { unset FM_FAKE_CREW_STATE; fail "drain after the immediate stale failed"; }
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$w" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "immediate stale wake was not queued"; }
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait the timer)"
}

# --- behavioral: wedge escalation fires once per stall episode ----------------
# A provably-working pane that goes truly static escalates as a possible wedge
# exactly once. Before the once-per-episode marker, the post-escalation poll
# self-healed a fresh wedge timer for the SAME hash and the SAME static pane
# re-escalated every STALE_ESCALATE_SECS, forever (the hourly stale nag storm).
# A new stall episode (the pane changed, then went static again) escalates once
# more.

test_wedge_escalates_once_per_episode() {
  local dir state fakebin out drain_out capture_file id w key pid sig
  dir=$(make_case wedge-once); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  id="wedged"; w="fm-$id"
  printf 'running long CI wait\nno new output\nstill the same\nsame\nsame\nsame\nsame\nsame\n' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'working: waiting on CI\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: no seeded bookkeeping - the watcher itself detects the stale,
  # absorbs it (provably working), arms the wedge timer, and escalates once
  # past the (tiny) threshold.
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_FAKE_CREW_STATE; fail "watcher did not wedge-escalate a static provably-working pane"; }
  assert_contains "$(cat "$out")" "possible wedge" "first stall episode did not escalate as a possible wedge"
  [ "$(cat "$state/.stale-escalated-$key" 2>/dev/null || true)" = "$(cat "$state/.hash-$key")" ] \
    || { unset FM_FAKE_CREW_STATE; fail "escalation did not record the once-per-episode marker"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || { unset FM_FAKE_CREW_STATE; fail "drain after the first wedge escalation failed"; }

  # Phase B: same pane, same hash, marker present - the episode is already
  # reported. The watcher must NOT re-arm the timer and re-escalate; it keeps
  # blocking silently.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 45; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher re-escalated an already-escalated stall episode: $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "already-escalated episode printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "already-escalated episode enqueued a wake"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "already-escalated episode re-armed the wedge timer"; }
  reap "$pid"

  # Phase C: the pane makes progress (content above the footer changes), then
  # goes static again - a NEW stall episode. It must escalate exactly once more.
  printf 'resumed, new build output\nfresh line one\nfresh line two\nsame\nsame\nsame\nsame\nsame\n' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_FAKE_CREW_STATE; fail "a new stall episode after progress did not wedge-escalate"; }
  assert_contains "$(cat "$out")" "possible wedge" "new stall episode did not escalate as a possible wedge"
  [ "$(cat "$state/.stale-escalated-$key" 2>/dev/null || true)" = "$(cat "$state/.hash-$key")" ] \
    || { unset FM_FAKE_CREW_STATE; fail "new episode's escalation did not re-record the marker for the new hash"; }
  unset FM_FAKE_CREW_STATE
  pass "wedge escalation fires exactly once per stall episode, and once more per new episode"
}

# --- behavioral: an immediately-surfaced stale never wedge-nags afterwards ----
# A stopped crew's stale is surfaced at once (one wake). Before the marker, the
# next poll self-healed a wedge timer for that same already-surfaced hash and
# nagged "possible wedge" every STALE_ESCALATE_SECS on top of the original wake.

test_surfaced_stale_never_wedge_nags() {
  local dir state fakebin out capture_file id w key pid sig
  dir=$(make_case surfaced-no-nag); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  id="idle"; w="fm-$id"
  printf 'stopped at a prompt\nline\nline\nline\nline\nline\nline\nline\n' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'working: implementing\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Phase A: the stopped crew's stale surfaces once (existing behavior).
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_FAKE_CREW_STATE; fail "watcher did not surface the stopped crew's stale"; }
  grep -Fx "stale: $w" "$out" >/dev/null || { unset FM_FAKE_CREW_STATE; fail "stopped crew's stale wake not printed"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || { unset FM_FAKE_CREW_STATE; fail "drain after the surfaced stale failed"; }

  # Phase B: same static pane. The one wake for this episode already fired;
  # the watcher must not follow it up with a "possible wedge" nag.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 45; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher wedge-nagged an already-surfaced stale: $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "already-surfaced stale printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "already-surfaced stale enqueued a wake"; }
  reap "$pid"; unset FM_FAKE_CREW_STATE
  pass "an immediately-surfaced stale produces no follow-up wedge nag for the same episode"
}

# --- behavioral: the ticking TUI footer never changes the staleness hash ------
# The staleness hash must exclude the footer region the busy regex scans (the
# last 6 non-blank lines): Claude's footer counters tick on every render, so a
# footer-included hash makes an idle pane look freshly active, then freshly
# DISTINCTLY stale, on every tick - an endless stream of one-shot stale wakes.

test_footer_tick_does_not_change_stale_hash() {
  local dir state fakebin out capture_file id w key pid sig hash_before
  dir=$(make_case footer-tick); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  id="ticker"; w="fm-$id"
  printf 'content line 1\ncontent line 2\ncontent line 3\n\n> \nfooter a\nfooter b\nfooter c\nfooter d\n5h: 12%% (4h49m)\n' > "$capture_file"
  printf 'handle=p1\nkind=ship\n' > "$state/$id.meta"
  printf 'working: quiet stretch\n' > "$state/$id.status"
  sig=$(seen_sig "$state/$id.status"); printf '%s' "$sig" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$w" | tr ':/.' '___')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Warm up: let the watcher record the pane's staleness hash and absorb the
  # provably-working stale (high threshold: the wedge timer never fires here).
  PATH="$fakebin:$PATH" FM_FAKE_PANE_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(cat "$state/.hash-$key" 2>/dev/null || echo missing)" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$i" -lt 60 ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "warm-up never absorbed the initial stale"; }
  hash_before=$(cat "$state/.hash-$key")

  # Tick the footer: only the counter inside the last-6-non-blank-line footer
  # window changes. The staleness hash - and so all stale bookkeeping - must
  # not move, and no wake fires.
  printf 'content line 1\ncontent line 2\ncontent line 3\n\n> \nfooter a\nfooter b\nfooter c\nfooter d\n5h: 12%% (4h48m)\n' > "$capture_file"
  if ! wait_live "$pid" 45; then reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher woke on a footer-only tick: $(cat "$out")"; fi
  [ "$(cat "$state/.hash-$key")" = "$hash_before" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "a footer-only tick changed the staleness hash"; }
  [ ! -s "$out" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "footer-only tick printed a wake reason"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "footer-only tick enqueued a wake"; }
  [ -e "$state/.stale-since-$key" ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "footer-only tick reset the wedge timer (hash was treated as fresh activity)"; }
  reap "$pid"; unset FM_FAKE_CREW_STATE
  pass "a footer-only tick never changes the staleness hash or stale bookkeeping"
}

# --- behavioral: heartbeat absorb + backstop --------------------------------

test_heartbeat_absorbs_then_backstop_surfaces() {
  local dir state fakebin out drain_out pid
  dir=$(make_case heartbeat); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # No statuses at all: a heartbeat finds nothing captain-relevant -> absorbed.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then reap "$pid"; fail "watcher exited on a no-change heartbeat (should absorb): $(cat "$out")"; fi
  [ ! -s "$out" ] || { reap "$pid"; fail "no-change heartbeat printed a wake reason"; }
  grep -F "absorbed heartbeat" "$state/.watch-triage.log" >/dev/null 2>&1 || { reap "$pid"; fail "no-change heartbeat was not logged as absorbed"; }
  reap "$pid"

  # Now plant a captain-relevant status that the per-wake path never surfaced (no
  # .hb-surfaced marker): the heartbeat fleet-scan backstop must surface it.
  printf 'done: PR https://example.test/pr/9 checks green\n' > "$state/lurker.status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_SIGNAL_GRACE=1 "$WATCH" > "$out" &
  pid=$!
  # Prime .seen for the lurker so the SIGNAL path does not surface it - we want the
  # heartbeat backstop to be what catches it.
  printf '%s' "$(seen_sig "$state/lurker.status")" > "$state/.seen-lurker_status"
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  assert_contains "$(cat "$out")" "heartbeat" "backstop did not print a heartbeat wake"
  [ -s "$state/.hb-surfaced-lurker" ] || fail "backstop did not mark the lurking status surfaced"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "no-change heartbeat is absorbed; the fleet-scan backstop surfaces an unsurfaced captain-relevant status"
}

test_signal_reason_is_actionable
test_crew_is_provably_working
test_signal_crew_provably_working
test_stale_is_terminal
test_captain_signal_surfaced
test_noverb_signal_provably_working_absorbed
test_noverb_signal_not_working_surfaced
test_terminal_stale_surfaced
test_terminal_stale_provably_working_overridden
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_nonterminal_stale_not_working_surfaced
test_wedge_escalates_once_per_episode
test_surfaced_stale_never_wedge_nags
test_footer_tick_does_not_change_stale_hash
test_heartbeat_absorbs_then_backstop_surfaces

echo "all fm-watch-triage tests passed"
