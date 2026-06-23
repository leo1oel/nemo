#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2030,SC2031  # daemon sourced via runtime $DAEMON; subshell-local env is intentional
# Behavior tests for bin/fm-supervise-daemon.sh — the presence-gated sub-supervisor.
# The daemon is sourceable (fm_super_main runs only when executed), so we source it
# and exercise the pure classifiers, the /afk presence-gating contract, and the
# herdr pane layer (ported from tmux). The pane layer is driven by a stub `herdr`
# on PATH whose shape mirrors the real herdr 0.7.0 verified live:
#   - `pane get`  -> JSON with .result.pane.agent_status (idle|working|...)
#   - `pane read` -> a Claude render whose composer is the "❯ <text>" line
# so nothing touches a live herdr server.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

MARK=$(printf '\x1f')

# Build a sandbox: a state dir and a stub `herdr` on PATH. The stub reads two env
# knobs so a test can drive pane state:
#   STUB_STATUS  -> agent_status returned by `pane get` (default idle)
#   STUB_COMPOSER-> text after the ❯ marker in `pane read` (empty = idle composer)
# Echoes the sandbox root.
mk_env() {
  local tmp state fb
  tmp=$(mktemp -d); state="$tmp/state"; fb="$tmp/bin"
  mkdir -p "$state" "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get")
    [ "$3" = "gone" ] && { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s","agent_status":"%s"}}}\n' "$3" "${STUB_STATUS:-idle}"
    ;;
  "pane read")
    # A Claude-shaped render: history, the rule lines, the ❯ composer, footers.
    printf 'history line\n────\n❯ %s\n────\n  Opus 4.8 | Context 0%%\n  bypass on\n' "${STUB_COMPOSER:-}"
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$tmp"
}

# Build a sandbox whose stub `herdr` simulates a Claude-style BORDERED composer
# ("│ > … │") — the exact rendering the old detector misread as permanent pending
# input (incident afk-invx-i5). The live composer text lives in $tmp/composer so
# send-text / Enter can mutate it across calls. Env knobs:
#   STUB_STATUS        -> agent_status from `pane get` (default idle)
#   FM_FAKE_COMPOSER   -> path to the composer file (set per-test, exported)
#   FM_FAKE_SWALLOW    -> if set to an existing file, Enter is "swallowed" (the
#                         composer is NOT cleared); a one-shot swallow deletes the
#                         flag file, a persistent one (FM_FAKE_PERSIST_SWALLOW=1)
#                         keeps it.
#   FM_FAKE_SENT       -> optional log of each typed line + each landed [ENTER].
# Echoes the sandbox root.
mk_bordered_env() {
  local tmp state fb
  tmp=$(mktemp -d); state="$tmp/state"; fb="$tmp/bin"
  mkdir -p "$state" "$fb"
  printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$tmp/composer"   # "│ > │" bordered-empty
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "$1 $2" in
  "pane get")
    [ "$3" = "gone" ] && { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s","agent_status":"%s"}}}\n' "$3" "${STUB_STATUS:-idle}"
    ;;
  "pane read")
    # Claude-shaped render with a BORDERED composer line between rule lines, and
    # the model/effort + bypass footers BELOW it (so a tail-1 read sees a footer).
    printf 'history line\n'
    printf '\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90\n'   # box top
    cat "$COMPOSER" 2>/dev/null
    printf '\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98\n'   # box bottom
    printf '  Opus 4.8 | Context 0%%\n  bypass on\n'
    ;;
  "pane send-text")
    [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
    [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$4" >> "$FM_FAKE_SENT"
    printf '\xe2\x94\x82 > %s \xe2\x94\x82\n' "$4" > "$COMPOSER"   # "│ > <text> │"
    ;;
  "pane send-keys")
    # $3 is the pane id, $4.. the key(s). Only Enter mutates the composer.
    shift 3
    for k in "$@"; do
      case "$k" in
        enter|Enter)
          if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
            [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
          else
            [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
            printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$COMPOSER"   # cleared: "│ > │"
          fi
          ;;
      esac
    done
    ;;
  "notification show") : ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$tmp"
}

# --- pure classifiers + presence-gating (backend-agnostic) ------------------

test_marker_and_afk_contract() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  ( set -u; . "$DAEMON"
    message_is_injection "${MARK}digest" || exit 11
    message_is_injection "real message" && exit 12
    [ "$(strip_injection_marker "${MARK}hi")" = "hi" ] || exit 13
    afk_active "$state" && exit 14
    afk_enter "$state"; afk_active "$state" || exit 15
    should_exit_afk "$state" "${MARK}escalation" && exit 16
    should_exit_afk "$state" "/afk later" && exit 17
    should_exit_afk "$state" "real msg" || exit 18
    afk_exit "$state"; should_exit_afk "$state" "real msg" && exit 19
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "marker/afk contract (code $rc)"
  pass "sentinel marker + /afk enter/exit contract"
}

test_classifiers() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  printf 'done: PR ready https://x\n' > "$state/t1.status"
  printf 'building the thing\n'        > "$state/t2.status"
  ( set -u; . "$DAEMON"
    case "$(classify_signal "$state/t1.status" "$state")" in escalate\|*) ;; *) exit 21 ;; esac
    case "$(classify_signal "$state/t2.status" "$state")" in self\|*) ;; *) exit 22 ;; esac
    case "$(classify_heartbeat)" in self\|*) ;; *) exit 23 ;; esac
    case "$(classify_unknown 'weird')" in escalate\|*) ;; *) exit 24 ;; esac
    [ "$(window_to_task "fm-task9")" = "task9" ] || exit 25
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "classifiers (code $rc)"
  pass "signal/heartbeat/unknown classifiers + window_to_task"
}

# --- ported herdr pane layer (validated live against herdr 0.7.0 + Claude) --

test_pane_layer() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state"
    . "$DAEMON"
    [ "$(_handle_for fm-task9 "$state")" = p1 ] || exit 31   # meta resolution
    [ "$(_handle_for somepane "$state")" = somepane ] || exit 32  # passthrough
    pane_exists p1 || exit 33
    pane_exists gone && exit 34
    [ "$(window_for_task "$(_stale_key task9)")" = fm-task9 ] || exit 35
    # busy via agent_status (the live-verified signal; catches thinking)
    STUB_STATUS=working pane_is_busy fm-task9 || exit 36
    STUB_STATUS=idle    pane_is_busy fm-task9 && exit 37
    # input-pending reads the ❯ composer line, not the footer below it
    STUB_COMPOSER=""        pane_input_pending p1 && exit 38   # empty composer
    STUB_COMPOSER="halfTyped" pane_input_pending p1 || exit 39 # typed -> pending
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "pane layer (code $rc)"
  pass "herdr pane layer: agent_status busy + ❯-composer input detection"
}

test_inject_flow() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_TARGET=p1 \
      FM_INJECT_CONFIRM_SLEEP=0 FM_INJECT_CONFIRM_RETRIES=1 STUB_STATUS=idle STUB_COMPOSER=""
    . "$DAEMON"
    afk_enter "$state"                         # inject only fires when afk is active
    escalate_add "$state" "done: PR ready"
    escalate_flush "$state" || exit 41         # idle + empty composer => submit ack
    [ -s "$state/.subsuper-escalations" ] && exit 42   # buffer cleared on success
    # composer guard: non-empty composer => defer, buffer preserved
    escalate_add "$state" "second"
    STUB_COMPOSER="user is typing" bash -c '. "'"$DAEMON"'"; escalate_flush "'"$state"'"' && exit 43
    [ -s "$state/.subsuper-escalations" ] || exit 44
    # afk OFF => inject suppressed regardless of pane state
    afk_exit "$state"
    escalate_flush "$state" && exit 45
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "inject flow (code $rc)"
  pass "inject: success on idle+empty, defers on busy composer, suppressed when afk off"
}

# ============================================================================
# afk-invx-i5 regressions: border-aware composer detection (RC1), verified
# submit-ACK on a bordered composer (RC2), and the max-defer escape (RC1b).
# ============================================================================

# RC1: a bordered idle composer reads NOT pending; a bordered composer with real
# text reads pending. The old detector matched only a BARE "^❯", so an idle
# bordered claude composer ("│ > … │") read as pending and the daemon deferred
# 100% of escalations for 9.5h.
test_bordered_composer_detection() {
  local tmp state comp; tmp=$(mk_bordered_env); state="$tmp/state"; comp="$tmp/composer"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_FAKE_COMPOSER="$comp"
    . "$DAEMON"
    # bordered-empty in several renderings -> NOT pending
    printf '\xe2\x94\x82 > \xe2\x94\x82\n'              > "$comp"; pane_input_pending p1 && exit 51
    printf '\xe2\x94\x82 \xe2\x9d\xaf            \xe2\x94\x82\n' > "$comp"; pane_input_pending p1 && exit 52  # "│ ❯       │"
    printf '\xe2\x94\x82              \xe2\x94\x82\n'    > "$comp"; pane_input_pending p1 && exit 53  # blank box
    # bordered with real typed text -> pending
    printf '\xe2\x94\x82 > half typed \xe2\x94\x82\n'   > "$comp"; pane_input_pending p1 || exit 54
    # FM_COMPOSER_IDLE_RE override forces empty AFTER border stripping
    printf '\xe2\x94\x82 > custom idle \xe2\x94\x82\n'  > "$comp"
    FM_COMPOSER_IDLE_RE='^custom idle$' pane_input_pending p1 && exit 55
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "bordered composer detection (code $rc)"
  pass "border-aware composer: bordered-idle not pending, bordered-text pending, idle-RE override"
}

# RC2: submit-ACK on a BORDERED composer. A clean Enter clears the box ("│ > │")
# and inject confirms (border-aware: not mistaken for a swallowed Enter). A
# persistent swallow leaves the text and inject fails after retries.
test_bordered_submit_ack() {
  local tmp state comp; tmp=$(mk_bordered_env); state="$tmp/state"; comp="$tmp/composer"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_FAKE_COMPOSER="$comp" \
      FM_SUPERVISOR_TARGET=p1 FM_INJECT_CONFIRM_SLEEP=0 FM_INJECT_CONFIRM_RETRIES=3 STUB_STATUS=idle
    . "$DAEMON"
    afk_enter "$state"
    # clean submit: Enter clears the bordered box -> confirmed empty -> success
    escalate_add "$state" "done: PR ready"
    escalate_flush "$state" || exit 61
    [ -s "$state/.subsuper-escalations" ] && exit 62   # buffer cleared on confirmed submit
    # persistent swallow: Enter never clears -> inject fails -> buffer preserved
    escalate_add "$state" "second event"
    : > "$tmp/swallow"
    FM_FAKE_SWALLOW="$tmp/swallow" FM_FAKE_PERSIST_SWALLOW=1 \
      bash -c '. "'"$DAEMON"'"; escalate_flush "'"$state"'"' && exit 63
    [ -s "$state/.subsuper-escalations" ] || exit 64
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "bordered submit ack (code $rc)"
  pass "verified submit: bordered-empty confirms, persistent swallow reports pending (buffer kept)"
}

# RC1b: the max-defer escape. On a STUCK pane (busy) past FM_MAX_DEFER_SECS the
# forced flush still fails and the wedge alarm fires (ERROR log + marker). On an
# IDLE pane the forced flush lands and clears any standing marker. Below the
# threshold housekeeping stays quiet.
test_max_defer_escape() {
  local tmp state comp; tmp=$(mk_bordered_env); state="$tmp/state"; comp="$tmp/composer"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_FAKE_COMPOSER="$comp" \
      FM_SUPERVISOR_TARGET=p1 FM_INJECT_CONFIRM_SLEEP=0 FM_INJECT_CONFIRM_RETRIES=1 \
      FM_MAX_DEFER_SECS=300 FM_ESCALATE_BATCH_SECS=999999 FM_HEARTBEAT_SCAN_SECS=999999 \
      LOG="$state/.supervise-daemon.log"
    . "$DAEMON"
    afk_enter "$state"
    : > "$state/.supervise-daemon.log"

    # (a) below threshold: a fresh buffer must NOT alarm or flush.
    escalate_add "$state" "fresh event"
    STUB_STATUS=working housekeeping "$state"
    [ -e "$state/.subsuper-inject-wedged" ] && exit 71
    [ -s "$state/.subsuper-escalations" ] || exit 72   # still buffered, untouched

    # (b) stuck pane past max-defer: forced flush fails (busy) -> wedge alarm.
    printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$state/.subsuper-escalations.since"
    STUB_STATUS=working housekeeping "$state"
    [ -e "$state/.subsuper-inject-wedged" ] || exit 73
    grep -q 'ERROR: away-mode escalation undelivered' "$state/.supervise-daemon.log" || exit 74
    [ -s "$state/.subsuper-escalations" ] || exit 75   # buffer preserved through the alarm

    # (c) pane recovers (idle + bordered-empty): forced flush lands, marker cleared.
    printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$comp"
    # Re-age both the buffer AND the marker so the throttle allows another attempt.
    printf '%s\n' "$(( $(date +%s) - 1000 ))" > "$state/.subsuper-escalations.since"
    touch -t 200001010000 "$state/.subsuper-inject-wedged"
    STUB_STATUS=idle housekeeping "$state"
    [ -e "$state/.subsuper-inject-wedged" ] && exit 76   # alarm cleared on recovery
    [ -s "$state/.subsuper-escalations" ] && exit 77     # buffer flushed
    grep -q 'inject recovered: max-defer flush succeeded' "$state/.supervise-daemon.log" || exit 78
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "max-defer escape (code $rc)"
  pass "max-defer: quiet below threshold, alarms on a stuck pane, recovers (clears marker) on idle"
}

test_marker_and_afk_contract
test_classifiers
test_pane_layer
test_inject_flow
test_bordered_composer_detection
test_bordered_submit_ack
test_max_defer_escape
