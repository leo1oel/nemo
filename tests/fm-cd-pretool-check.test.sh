#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for the cd-guard Claude PreToolUse seatbelt (docs/cd-guard.md).
#
# bin/fm-cd-command-policy.mjs is the single owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-cd-pretool-check.sh is the Claude transport: it scopes the guard to the
# real primary checkout, then reads the PreToolUse payload. This fork is
# Claude-only, so the suite drives the Claude entry forms (CLI --command and
# stdin --claude); it proves the full decision matrix, primary-checkout scoping
# (a linked crewmate/scout worktree is inert), the fail-open transport, and the
# prefilter fast path. No harness is spawned.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cd-pretool.XXXXXX")

DENY_MSG='persistent-cd'

# Copy the transport plus BOTH policy files into a fixture bin/ (cd-command-policy
# imports the shared classifier from arm-command-policy). Copy, not symlink, so
# the transport resolves FM_ROOT to the fixture and scopes against its git dirs.
install_cd_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-cd-pretool-check.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, git-dir == git-common-dir.
make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks. git-dir and git-common-dir differ, so the guard must be inert.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  git -C "$base" worktree add -q --detach "$dir" >/dev/null 2>&1
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP/primary")
CHECK="$PRIMARY/bin/fm-cd-pretool-check.sh"

# --- decision matrix (ported from upstream #483, driven via the Claude CLI) ---

IDS=(); EXPECT=(); CMDS=()
mc() { IDS+=("$1"); EXPECT+=("$2"); CMDS+=("$3"); }

# BLOCK: a persistent top-level cwd change in the parent shell.
mc B01 deny 'cd projects/foo'
mc B02 deny 'cd ..'
mc B03 deny 'cd'
mc B04 deny 'cd -'
mc B05 deny 'cd /abs/path'
mc B06 deny 'pushd projects/foo'
mc B07 deny 'popd'
mc B08 deny 'X=1 cd projects/foo'
mc B09 deny 'cd projects/foo && tasks-axi add x'
mc B10 deny 'echo before; cd projects/foo'
mc B11 deny 'true && cd projects/foo'
mc B12 deny 'tasks-axi done x || cd projects/foo'
mc B13 deny 'cd "projects/foo"'
mc B14 deny '"cd" projects/foo'
mc B15 deny 'sleep 1 & cd projects/foo'
mc B16 deny 'command cd projects/foo'
mc B17 deny 'cd projects/foo >/dev/null'
mc B18 deny $'cd projects/foo\necho done'
mc B19 deny "\$'\\143d' projects/foo"
mc B20 deny "c'd' projects/foo"
mc B21 deny 'c"d" projects/foo'
mc B22 deny 'c\d projects/foo'
mc B23 deny 'builtin cd projects/foo'
mc B24 deny 'command builtin cd projects/foo'
mc B25 deny 'builtin command cd projects/foo'
mc B26 deny 'command -p cd projects/foo'
mc B27 deny 'command -- cd projects/foo'

# ALLOW: reaches a dir without moving the parent shell, or is not a cd at all.
mc A01 allow 'git -C projects/foo status'
mc A02 allow 'cat /abs/path/file'
mc A03 allow 'ls projects/foo'
mc A04 allow 'echo "cd projects/foo"'
mc A05 allow 'grep cd file'
mc A06 allow '(cd projects/foo && pwd)'
mc A07 allow "bash -c 'cd projects/foo'"
mc A08 allow 'env -C projects/foo make'
mc A09 allow 'make -C projects/foo build'
mc A10 allow 'find . -execdir cd {} \;'
mc A11 allow 'cd projects/foo | cat'
mc A12 allow 'cat foo | cd bar'
mc A13 allow 'cd projects/foo &'
mc A14 allow 'abcd project'
mc A15 allow 'cdk deploy'
mc A16 allow 'env cd projects/foo'
mc A17 allow 'sudo cd projects/foo'
mc A18 allow 'x=$(cd foo && pwd)'
mc A19 allow 'dirs'
mc A20 allow "echo 'pushd x'"
mc A21 allow 'git checkout main'
mc A22 allow "sh -c 'cd projects/foo && ls'"
mc A23 allow "printf '%s\\n' 'cd projects/foo'"
mc A24 allow 'ls -la'
mc A25 allow './cd projects/foo'
mc A26 allow '/tmp/cd projects/foo'
mc A27 allow '/usr/bin/cd projects/foo'
mc A28 allow './builtin cd projects/foo'
mc A29 allow 'c\d\ projects/foo'
mc A30 allow './command cd projects/foo'
mc A31 allow '/usr/bin/command cd projects/foo'
mc A32 allow '/tmp/builtin cd projects/foo'
mc A33 allow 'command -v cd'
mc A34 allow 'command -V cd'
mc A35 allow 'command -pv cd'
mc A36 allow 'command -vp cd'

test_decision_matrix() {
  local i cmd want out rc bad=0
  for i in "${!IDS[@]}"; do
    cmd=${CMDS[$i]}; want=${EXPECT[$i]}
    out=$("$CHECK" --command "$cmd" 2>&1); rc=$?
    if [ "$want" = deny ]; then
      { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "$DENY_MSG"; } \
        || { printf '  %s expected deny, got rc=%s out=%s\n' "${IDS[$i]}" "$rc" "$out" >&2; bad=1; }
    else
      { [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
        || { printf '  %s expected allow, got rc=%s out=%s\n' "${IDS[$i]}" "$rc" "$out" >&2; bad=1; }
    fi
  done
  [ "$bad" -eq 0 ] || fail "cd decision matrix had mismatches"
  pass "cd-guard decision matrix: ${#IDS[@]} cases (27 deny + 36 allow) via the Claude CLI"
}

test_stdin_transport() {
  local out rc
  out=$(printf '{"tool_input":{"command":"cd projects/foo && rm x"}}' | "$CHECK" --claude 2>&1); rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; } \
    || fail "cd-guard stdin: a deniable payload must exit 2 with a Claude deny object (rc=$rc)"
  out=$(printf '{"tool_input":{"command":"git -C projects/foo status"}}' | "$CHECK" --claude 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "cd-guard stdin: an allowed payload must exit 0 silently (rc=$rc)"
  out=$(printf 'not json' | "$CHECK" --claude 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "cd-guard stdin: malformed payload must fail open (rc=$rc)"
  pass "cd-guard stdin transport: deny object on exit 2, silent allow, malformed fails open"
}

test_primary_scoping() {
  local wt out rc
  wt=$(make_child_worktree_fixture "$PRIMARY" "$TMP/child-wt")
  # The SAME deniable command is INERT from a linked worktree (git-dir != common).
  out=$("$wt/bin/fm-cd-pretool-check.sh" --command 'cd projects/foo' 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    || fail "cd-guard: a linked child worktree must be inert, not deny (rc=$rc out=$out)"
  # And still denies from the primary checkout (control).
  out=$("$CHECK" --command 'cd projects/foo' 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "cd-guard: the primary checkout must still deny (rc=$rc)"
  pass "cd-guard scoping: denies in the primary checkout, inert in a linked crew/scout worktree"
}

test_fail_open_missing_policy() {
  local dir out rc
  dir="$TMP/nopolicy"
  git init -q "$dir"; git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"; mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  chmod +x "$dir/bin/fm-cd-pretool-check.sh"   # policy .mjs deliberately absent
  out=$("$dir/bin/fm-cd-pretool-check.sh" --command 'cd projects/foo' 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } \
    || fail "cd-guard: a missing policy owner must fail open (allow), not error (rc=$rc out=$out)"
  pass "cd-guard fail-open: a missing policy .mjs allows instead of blocking"
}

test_prefilter_fast_allow() {
  local out rc
  # No cd/pushd/popd substring: the prefilter fast-allows before invoking Node.
  out=$("$CHECK" --command 'ls -la && tasks-axi ready' 2>&1); rc=$?
  { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || fail "cd-guard prefilter: a cd-free command must fast-allow (rc=$rc)"
  pass "cd-guard prefilter: a command with no cd/pushd/popd fast-allows"
}

test_decision_matrix
test_stdin_transport
test_primary_scoping
test_fail_open_missing_policy
test_prefilter_fast_allow
