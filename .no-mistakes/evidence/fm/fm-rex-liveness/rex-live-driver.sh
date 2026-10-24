#!/usr/bin/env bash
# Live driver: a private Rex server (tests/rex-test-safety.sh), one block whose
# foreground is a fish shell that starts the real Claude Code CLI through a
# fish function wrapper (`function claude; command claude $argv; end`) and the
# cac bash shim. Reads the adapter's agent state with the change (target
# commit) and with the base commit's adapter, against the same live block.
set -u
ROOT=${1:?worktree}
BASE_ADAPTER=${2:?base rex.sh, inside a copy of bin/backends}
cd "$ROOT"
fail() { printf 'not ok - %s\n' "$1"; rex_test_cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare || exit 2
PAIR=$(rex_test_new_session live) || fail "no session"
read -r SID BID <<<"$PAIR"
T=$(fm_backend_rex_target "$SID" "$BID")
echo "private server: $REX_TEST_ENDPOINT  target: $T"

state_new() { fm_backend_agent_state rex "$T"; }
# The base adapter, sourced in a subshell over the same live block.
state_base() { ( . "$BASE_ADAPTER"; fm_backend_agent_state rex "$T" ); }
proc() { fm_backend_rex_block_call "$T" process | jq -c '{foreground:{pid:.foreground.pid,name:.foreground.name,argv0:.foreground.argv0},ancestors:[.ancestors[]|{pid,name,argv0}]}'; }
fgpid() { fm_backend_rex_block_call "$T" process | jq -r .foreground.pid; }
tree() { local r; r=$(fgpid); echo "ps below foreground $r (pid ppid pgid tpgid comm):"; ps -axo pid=,ppid=,pgid=,tpgid=,comm= | awk -v r="$r" '{p[$1]=$2; l[$1]=$0} END{for(k in l){x=k; while(x in p && x!=r && x>1) x=p[x]; if(x==r) print "  " l[k]}}' | sort -n; }
show() { echo "--- $1"; echo "rex process view: $(proc)"; tree; echo "agent_state (target commit): $(state_new)"; echo "agent_state (base commit):   $(state_base)"; echo "live_pids (target commit):   $(fm_backend_rex_live_pids "$T")"; }
wait_state() { local want=$1 n=0; while [ "$n" -lt 150 ]; do [ "$(state_new)" = "$want" ] && return 0; sleep 0.2; n=$((n+1)); done; return 1; }

rex_test_wait_for 50 sh -c '[ -n "$1" ]' _ "$(fgpid)" || true
fm_backend_rex_send_text_line "$T" "exec /opt/homebrew/bin/fish -l" || fail "send exec fish"
sleep 3
fm_backend_rex_send_text_line "$T" "function claude; command claude \$argv; end" || fail "define wrapper"
sleep 1
show "S0: bare fish prompt"
[ "$(state_new)" = dead ] || fail "a bare fish prompt must read dead"
pass "bare fish shell foreground reads dead"

# Scenario 1a: fish's default job control: the shim gets its own process group.
fm_backend_rex_send_text_line "$T" "claude" || fail "start claude"
wait_state alive || { show "S1a (timed out)"; fm_backend_rex_capture "$T" 40; fail "claude via the shim never read alive"; }
sleep 2
show "S1a: claude via fish function + cac bash shim, fish job control on (shim leads its own pgroup)"
echo "base commit reads: $(state_base)"
kill "$(fm_backend_rex_live_pids "$T" | jq -r '.[-1]')" 2>/dev/null
wait_state dead || fail "after claude exits (S1a) the pane must read dead"
pass "S1a: shim-as-foreground over a live claude reads alive"

# Scenario 1: the reported shape: wrapper and harness in fish's own pgroup.
fm_backend_rex_send_text_line "$T" "status job-control none" || fail "job control off"
sleep 1
fm_backend_rex_send_text_line "$T" "claude" || fail "start claude"
wait_state alive || { show "S1 (timed out)"; fm_backend_rex_capture "$T" 40; fail "claude below fish never read alive"; }
sleep 2
show "S1: claude started via fish function + cac bash shim"
[ "$(proc | jq -r .foreground.name)" = fish ] || fail "rex must report fish as the foreground for the repro to hold"
[ "$(state_new)" = alive ] || fail "target commit must read alive"
[ "$(state_base)" = dead ] || echo "note: base commit read $(state_base), not dead"
CLAUDE_PID=$(fm_backend_rex_live_pids "$T" | jq -r '.[-1]')
echo "harness pid in live_pids: $CLAUDE_PID ($(ps -o comm= -p "$CLAUDE_PID"))"
echo "busy_state (target commit): $(fm_backend_busy_state rex "$T")"
echo "program_status records: $(fm_backend_rex_block_call "$T" program_status 2>/dev/null | jq -c '[.records[]? | {state,app,owner}]')"
echo "--- pane capture (last 15 lines)"; fm_backend_rex_capture "$T" 15
pass "live claude below a fish foreground reads alive (base adapter: $(state_base))"

# Scenario 2: the harness exits -> back to dead (no stale alive).
kill "$CLAUDE_PID" 2>/dev/null
wait_state dead || { show "S2 (timed out)"; fail "after claude exits the shell must read dead again"; }
show "S2: claude killed, fish prompt back"
pass "after the harness exits, the fish foreground reads dead again"

# Scenario 3 (adversarial): fish function + bash shim around a non-harness.
fm_backend_rex_send_text_line "$T" "function worker; bash -c 'sleep 300; exit \$?'; end" || fail "define worker"
sleep 1
fm_backend_rex_send_text_line "$T" "worker" || fail "start worker"
sleep 3
show "S3: non-harness sleep via fish function + bash wrapper"
s=$(state_new)
[ "$s" != alive ] || fail "a non-harness process below the shell must not read alive"
pass "non-harness process tree below the fish foreground reads $s, not alive"
fm_backend_rex_send_key "$T" C-c
sleep 1
rex_test_assert_isolated
