#!/usr/bin/env bash
# Live driver: bin/fm-send.sh steering a real Claude Code worker on a private
# Rex server, where the worker's fish shell (job control off, as in the
# reported pane) started Claude through `function claude; command claude
# $argv; end` and the cac bash shim, so Rex reports fish as the foreground.
# The task is recorded in a disposable FM_HOME (rex-test-safety's home).
# Runs fm-send from the base commit's bin/ copy and from the target worktree.
# The composer holds an unsubmitted draft so that a live verdict skips the
# ring (no model turn is spent) while a dead verdict refuses it outright.
set -u
ROOT=${1:?worktree}
BASE_BIN=${2:?base bin dir}
cd "$ROOT"
fail() { printf 'not ok - %s\n' "$1"; rex_test_cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare || exit 2
PAIR=$(rex_test_new_session send) || fail "no session"
read -r SID BID <<<"$PAIR"
T=$(fm_backend_rex_target "$SID" "$BID")
wait_state() { local want=$1 n=0; while [ "$n" -lt 150 ]; do [ "$(fm_backend_agent_state rex "$T")" = "$want" ] && return 0; sleep 0.2; n=$((n+1)); done; return 1; }

sleep 1
fm_backend_rex_send_text_line "$T" "exec /opt/homebrew/bin/fish -l"; sleep 3
fm_backend_rex_send_text_line "$T" "status job-control none"; sleep 0.5
fm_backend_rex_send_text_line "$T" "function claude; command claude \$argv; end"; sleep 0.5
fm_backend_rex_send_text_line "$T" "claude"
wait_state alive || fail "claude never read alive"
sleep 3
# Trust the throwaway folder (second option), then leave a draft in the composer.
rex_test_cli send-key -s "$SID" -b "$BID" down >/dev/null; sleep 0.5
fm_backend_rex_send_key "$T" Enter; sleep 5
fm_backend_rex_send_literal "$T" "draft steer not yet submitted"; sleep 2
echo "rex process view: $(fm_backend_rex_block_call "$T" process | jq -c '{fg:.foreground.name,fg_pid:.foreground.pid,ancestors:[.ancestors[].name]}')"
echo "composer_state: $(fm_backend_composer_state rex "$T" 2>/dev/null)"
echo "--- pane before fm-send"; fm_backend_rex_capture "$T" 12

LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || fail "lab home create"
export FM_HOME="$LAB" STATE="$LAB/state"
cat >"$STATE/w1.meta" <<EOF
window=$T
endpoint_task_id=w1
worktree=$REX_TEST_WORK
project=$REX_TEST_WORK
harness=claude
yolo=off
kind=ship
backend=rex
rex_server=$REX_TEST_ENDPOINT
rex_session_id=$SID
rex_block_id=$BID
EOF

clean() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE "$@"; }
echo "--- base commit: fm-send.sh w1 'please rebase onto main'"
clean "$BASE_BIN/fm-send.sh" w1 "please rebase onto main"; echo "exit=$?"
echo "--- target commit: fm-send.sh w1 'please rebase onto main'"
OUT=$(clean "$ROOT/bin/fm-send.sh" w1 "please rebase onto main" 2>&1); RC=$?
printf '%s\nexit=%s\n' "$OUT" "$RC"
case "$OUT" in *"has exited"*|*refusing*|*error*) fail "target commit did not deliver: $OUT" ;; esac
[ "$RC" = 0 ] || fail "target fm-send exit $RC"
echo "inbox records: $(ls "$STATE/w1.inbox" 2>/dev/null | tr '\n' ' ')"
echo "--- pane after fm-send (draft untouched, claude still running)"; fm_backend_rex_capture "$T" 12
echo "agent_state after: $(fm_backend_agent_state rex "$T")"
pass "target commit: fm-send treats the live claude below the fish foreground as alive"
kill "$(fm_backend_rex_live_pids "$T" | jq -r '.[-1]')" 2>/dev/null
sleep 1
rm -rf "$LAB"
rex_test_assert_isolated
