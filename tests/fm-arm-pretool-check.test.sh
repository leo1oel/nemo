#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the watcher-arm Claude PreToolUse seatbelt
# (docs/arm-pretool-check.md).
#
# bin/fm-arm-command-policy.mjs is the sole owner of firstmate's shell command
# classification and the watcher-arm decision procedure; it also exports the
# tokenizer the cd-guard imports. bin/fm-arm-pretool-check.sh is the Claude
# transport. This fork is Claude-only (no Codex checkpoint concept), so the suite
# drives the Claude entry forms and covers each deny reason, the blessed setup
# tree, reference/quoted allows, the fail-open transport, and the prefilter fast
# path. No harness or watcher is spawned.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="$ROOT/bin/fm-arm-pretool-check.sh"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-pretool.XXXXXX")

# --- decision matrix (representative; the verbatim classifier's exhaustive
#     adversarial coverage is inherited from upstream #483) --------------------

IDS=(); EXPECT=(); CMDS=()
mc() { IDS+=("$1"); EXPECT+=("$2"); CMDS+=("$3"); }

# ALLOW: a standalone verified arm, after blessed setup nodes, or a mere mention.
mc A01 allow 'bin/fm-watch-arm.sh'
mc A02 allow './bin/fm-watch-arm.sh --restart'
mc A03 allow 'exec bin/fm-watch-arm.sh'
mc A04 allow 'cd /tmp && exec bin/fm-watch-arm.sh'
mc A05 allow 'export FM_HOME=/tmp; bin/fm-watch-arm.sh'
mc A06 allow 'export FM_HOME=/tmp && bin/fm-watch-arm.sh'
mc A07 allow 'cd /tmp; exec bin/fm-watch-arm.sh'
mc A08 allow "rg -n 'fm-watch-arm.sh &' docs"
mc A09 allow "echo 'pkill -f fm-watch'"
mc A10 allow 'echo ok # bin/fm-watch-arm.sh &'
mc A11 allow "git grep 'fm-watch-arm.sh && echo bad'"
mc A12 allow 'ls -la'
mc A13 allow 'git status'
mc A14 allow "printf '%s\\n' 'bin/fm-watch-arm.sh &'"

# DENY: every way a protected watcher command can escape a standalone call.
mc D01 deny 'bin/fm-watch-arm.sh &'            # watcher-background
mc D02 deny 'nohup bin/fm-watch-arm.sh'        # watcher-background
mc D03 deny 'bin/fm-watch-arm.sh & disown'     # watcher-background
mc D04 deny '(bin/fm-watch-arm.sh) &'          # watcher-nested/background
mc D05 deny 'bin/fm-watch-arm.sh | cat'        # watcher-pipeline
mc D06 deny 'bin/fm-watch-arm.sh 2>&1 | head -2' # watcher-pipeline
mc D07 deny 'bin/fm-watch-arm.sh >/tmp/out'     # watcher-redirection
mc D08 deny 'echo before; bin/fm-watch-arm.sh'  # watcher-bundled
mc D09 deny 'true && bin/fm-watch-arm.sh'       # watcher-bundled
mc D10 deny 'bin/fm-watch-arm.sh; echo after'   # watcher-bundled
mc D11 deny '$(bin/fm-watch-arm.sh)'            # watcher-nested (substitution)
mc D12 deny 'cat <(bin/fm-watch-arm.sh)'        # watcher-nested (process sub)
mc D13 deny "bash -lc 'bin/fm-watch-arm.sh &'"  # watcher-nested (shell -c)
mc D14 deny 'bin/fm-watch.sh'                   # watcher-direct
mc D15 deny "pkill -f '/bin/fm-watch.sh'"       # broad-watcher-kill
mc D16 deny "command pkill -f '/bin/fm-watch.sh'" # broad-watcher-kill
mc D17 deny "sudo pkill -f '/bin/fm-watch.sh'"  # broad-watcher-kill
mc D18 deny 'kill "$(pgrep -f '\''/bin/fm-watch.sh'\'')"' # broad-watcher-kill
mc D19 deny 'bin/fm-"watch-arm.sh" &'           # obfuscated quoting
mc D20 deny "WATCHER='bin/fm-watch-arm.sh'; \"\$WATCHER\" &" # var-indirect
mc D21 deny "bash -c \$'bin/fm-watch-arm.sh &'" # ANSI-C decoded

test_decision_matrix() {
  local i cmd want out rc bad=0
  for i in "${!IDS[@]}"; do
    cmd=${CMDS[$i]}; want=${EXPECT[$i]}
    out=$("$ARM" --command "$cmd" 2>&1); rc=$?
    if [ "$want" = deny ]; then
      { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; } \
        || { printf '  %s expected deny, got rc=%s out=%s\n' "${IDS[$i]}" "$rc" "$out" >&2; bad=1; }
    else
      { [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
        || { printf '  %s expected allow, got rc=%s out=%s\n' "${IDS[$i]}" "$rc" "$out" >&2; bad=1; }
    fi
  done
  [ "$bad" -eq 0 ] || fail "arm decision matrix had mismatches"
  pass "arm-guard decision matrix: ${#IDS[@]} cases (14 allow + 21 deny) via the Claude CLI"
}

test_reason_codes() {
  local out
  out=$("$ARM" --command 'bin/fm-watch.sh' 2>&1)
  printf '%s' "$out" | grep -q 'watcher-direct' || fail "arm: fm-watch.sh direct must map to watcher-direct ($out)"
  out=$("$ARM" --command "pkill -f '/bin/fm-watch.sh'" 2>&1)
  printf '%s' "$out" | grep -q 'broad-watcher-kill' || fail "arm: pkill must map to broad-watcher-kill ($out)"
  out=$("$ARM" --command 'bin/fm-watch-arm.sh &' 2>&1)
  printf '%s' "$out" | grep -q 'watcher-background' || fail "arm: backgrounded arm must map to watcher-background ($out)"
  pass "arm-guard reason codes: watcher-direct, broad-watcher-kill, watcher-background map through"
}

test_stdin_transport() {
  local out rc
  out=$(printf '{"tool_input":{"command":"pkill -f fm-watch"}}' | "$ARM" --claude 2>&1); rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; } \
    || fail "arm stdin: a deniable payload must exit 2 with a Claude deny object (rc=$rc)"
  out=$(printf '{"tool_input":{"command":"bin/fm-watch-arm.sh"}}' | "$ARM" --claude 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "arm stdin: a standalone arm must exit 0 silently (rc=$rc)"
  out=$(printf 'not json' | "$ARM" --claude 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "arm stdin: malformed payload must fail open (rc=$rc)"
  pass "arm-guard stdin transport: deny object on exit 2, silent allow, malformed fails open"
}

test_fail_open_missing_policy() {
  local dir out rc
  dir="$TMP/nopolicy"; mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$dir/bin/fm-arm-pretool-check.sh"
  chmod +x "$dir/bin/fm-arm-pretool-check.sh"   # policy .mjs deliberately absent
  out=$("$dir/bin/fm-arm-pretool-check.sh" --command 'bin/fm-watch-arm.sh &' 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    || fail "arm: a missing policy owner must fail open (allow), not error (rc=$rc out=$out)"
  pass "arm-guard fail-open: a missing policy .mjs allows instead of blocking"
}

test_prefilter_fast_allow() {
  local out rc
  out=$("$ARM" --command 'tasks-axi ready && ls -la' 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "arm prefilter: an fm-watch-free command must fast-allow (rc=$rc)"
  pass "arm-guard prefilter: a command with no fm-watch substring fast-allows"
}

test_classifier_exports() {
  # The cd-guard imports Lexer/splitProgram/commandPosition from this classifier;
  # exercising the cd policy end-to-end proves the exports resolve.
  local out
  out=$(node "$ROOT/bin/fm-cd-command-policy.mjs" --command 'cd projects/foo' 2>&1)
  printf '%s' "$out" | grep -q 'persistent-cd' \
    || fail "arm classifier exports (Lexer/splitProgram/commandPosition) must load into the cd policy ($out)"
  pass "arm-command-policy exports the shared tokenizer the cd-guard imports"
}

test_decision_matrix
test_reason_codes
test_stdin_transport
test_fail_open_missing_policy
test_prefilter_fast_allow
test_classifier_exports
