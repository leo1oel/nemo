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

test_marker_and_afk_contract
test_classifiers
test_pane_layer
test_inject_flow
