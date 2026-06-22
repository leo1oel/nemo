#!/usr/bin/env bash
# Behavior tests for bin/fm-supervise-daemon.sh — the presence-gated sub-supervisor.
# The daemon is sourceable (fm_super_main runs only when executed), so we source it
# and exercise the pure classifiers, the /afk presence-gating contract, and the
# herdr pane layer (ported from tmux). The pane layer is driven by a stub `herdr`
# on PATH plus state/<id>.meta files, so nothing touches a live herdr server.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

MARK=$(printf '\x1f')

# Build a sandbox: a state dir and a stub `herdr` on PATH whose `pane read` output
# is whatever STUB_READ holds (default an idle bare prompt). Echoes the state dir.
mk_env() {
  local tmp state fb
  tmp=$(mktemp -d); state="$tmp/state"; fb="$tmp/bin"
  mkdir -p "$state" "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get")  [ "$3" = "gone" ] && { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }; exit 0 ;;
  "pane read") cat "${STUB_READ_FILE:-/dev/null}" 2>/dev/null; printf '\n> \n' ;;
  *) exit 0 ;;
esac
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
    afk_active "$state" && exit 14            # not yet
    afk_enter "$state"; afk_active "$state" || exit 15
    should_exit_afk "$state" "${MARK}escalation" && exit 16   # marker -> stay
    should_exit_afk "$state" "/afk later" && exit 17          # /afk -> stay
    should_exit_afk "$state" "real msg" || exit 18            # real -> exit
    afk_exit "$state"; should_exit_afk "$state" "real msg" && exit 19  # inactive -> nothing
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
    # captain-relevant terminal status -> escalate
    case "$(classify_signal "$state/t1.status" "$state")" in escalate\|*) ;; *) exit 21 ;; esac
    # routine status -> self
    case "$(classify_signal "$state/t2.status" "$state")" in self\|*) ;; *) exit 22 ;; esac
    # heartbeat is always self; unknown is always escalate (fail-safe)
    case "$(classify_heartbeat)" in self\|*) ;; *) exit 23 ;; esac
    case "$(classify_unknown 'weird')" in escalate\|*) ;; *) exit 24 ;; esac
    [ "$(window_to_task "fm-task9")" = "task9" ] || exit 25
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "classifiers (code $rc)"
  pass "signal/heartbeat/unknown classifiers + window_to_task"
}

# --- ported herdr pane layer ------------------------------------------------

test_pane_layer() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  printf 'handle=p1\n' > "$state/task9.meta"
  printf 'esc to interrupt\n' > "$tmp/busy.txt"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state"
    . "$DAEMON"
    [ "$(_handle_for fm-task9 "$state")" = p1 ] || exit 31   # meta resolution
    [ "$(_handle_for somepane "$state")" = somepane ] || exit 32  # passthrough
    pane_exists p1 || exit 33
    pane_exists gone && exit 34
    [ "$(window_for_task "$(_stale_key task9)")" = fm-task9 ] || exit 35
    # busy detection: stub read returns the busy footer
    STUB_READ_FILE="$tmp/busy.txt" pane_is_busy fm-task9 || exit 36
    # idle: default stub read is a bare "> " prompt, not busy
    pane_is_busy fm-task9 && exit 37
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "pane layer (code $rc)"
  pass "herdr pane layer: handle resolve, exists, busy, window enumeration"
}

test_inject_flow() {
  local tmp state; tmp=$(mk_env); state="$tmp/state"
  printf 'handle=p1\n' > "$state/task9.meta"
  ( set -u; export PATH="$tmp/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_TARGET=p1 \
      FM_INJECT_CONFIRM_SLEEP=0 FM_INJECT_CONFIRM_RETRIES=1
    . "$DAEMON"
    afk_enter "$state"                         # inject only fires when afk is active
    escalate_add "$state" "done: PR ready"
    [ -s "$state/.subsuper-escalations" ] || exit 41
    escalate_flush "$state" || exit 42         # idle "> " prompt => submit ack via cleared composer
    [ -s "$state/.subsuper-escalations" ] && exit 43   # buffer cleared on success
    # afk OFF => inject is suppressed, buffer preserved
    afk_exit "$state"
    escalate_add "$state" "another"
    escalate_flush "$state" && exit 44         # returns non-zero (afk inactive)
    [ -s "$state/.subsuper-escalations" ] || exit 45
    exit 0 )
  local rc=$?; rm -rf "$tmp"
  [ "$rc" = 0 ] || fail "inject flow (code $rc)"
  pass "escalation buffer flush injects when afk on, suppresses when afk off"
}

test_marker_and_afk_contract
test_classifiers
test_pane_layer
test_inject_flow
