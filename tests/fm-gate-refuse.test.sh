#!/usr/bin/env bash
# Behavior test for the no-mistakes GATE-agent fleet-lifecycle refusal.
#
# A confused no-mistakes gate agent runs inside a firstmate checkout, adopts the
# captain identity from AGENTS.md, and reaches for fm-spawn/fm-send/fm-teardown.
# bin/fm-gate-refuse-lib.sh is the firstmate capability-removal half: sourced at
# the top of those three entrypoints and called before any fleet mutation, it
# fails closed on either of two independent signals:
#   1. NO_MISTAKES_GATE set in the environment (the marker no-mistakes stamps);
#   2. the current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the unspoofable backstop, which
#      still refuses even if the marker was tampered/unset.
# A normal firstmate session (real primary, real herdr crew worktree) has NEITHER
# signal and is completely unaffected. The normal-path no-regression of each
# entrypoint is covered by tests/fm-spawn-*.test.sh, tests/fm-send.test.sh, and
# tests/fm-teardown.test.sh (which now export FM_GATE_REFUSE_BYPASS=1); this test
# owns the refusal directions plus the direct-lib contract.
#
# This test deliberately does NOT export FM_GATE_REFUSE_BYPASS: it must exercise
# the REAL refusal even when the whole suite is itself run inside a no-mistakes
# gate worktree. Every refusal case sets exactly ONE signal (env -u clears the
# other) and stands in a controlled fixture, so the suite is hermetic regardless
# of where it runs.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

# Deterministic git identity so sandbox commits succeed without global config.
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-refuse.XXXXXX")

# The env marker's exact stderr fragment (the primary signal).
ENV_MSG='NO_MISTAKES_GATE set'
# The git-common-dir backstop's exact stderr fragment (the unspoofable signal).
PATH_MSG='no-mistakes gate worktree'

# --- fixtures ---------------------------------------------------------------

# mk_gate_worktree <root> -> echoes a worktree whose git-common-dir is
# <root>/.no-mistakes/repos/<id>.git, reproducing no-mistakes' gate topology.
mk_gate_worktree() {
  local root=$1 id=016d88035d58 run=01KXC3SD5NZYMERGDS68Z1C8ER seed
  mkdir -p "$root/.no-mistakes/repos"
  git init -q --bare "$root/.no-mistakes/repos/$id.git"
  seed=$(mktemp -d "$TMP/gate-seed.XXXXXX")
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m init
  git -C "$seed" push -q "$root/.no-mistakes/repos/$id.git" HEAD:refs/heads/main
  rm -rf "$seed"
  git -C "$root/.no-mistakes/repos/$id.git" worktree add --detach -q \
    "$root/.no-mistakes/worktrees/$id/$run" main
  printf '%s\n' "$root/.no-mistakes/worktrees/$id/$run"
}

# mk_normal_repo <dir> -> echoes a plain (non-gate) git repo standing in for a
# normal primary/crew checkout: its git-common-dir is <dir>/.git, never a gate.
mk_normal_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

GATE_WT=$(mk_gate_worktree "$TMP/gate")
NORMAL_CWD=$(mk_normal_repo "$TMP/normal-cwd")

# --- the shared helper, tested directly -------------------------------------

# run_guard_lib <cwd> [set|empty|unset] : from <cwd>, source the lib and call the
# guard under set -eu in a subshell (proving set -eu safety). Both env signals are
# cleared first; a "set"/"empty" second arg re-exports NO_MISTAKES_GATE so the
# caller picks the signal under test. Echoes combined output; guard exit is $?.
run_guard_lib() {
  local cwd=$1 marker=${2:-unset}
  (
    cd "$cwd" || exit 111
    unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
    case "$marker" in
      set) export NO_MISTAKES_GATE=1 ;;
      empty) export NO_MISTAKES_GATE= ;;
    esac
    set -eu
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$GATE_LIB"
    fm_refuse_if_gate_agent
  ) 2>&1
}

test_helper_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" set); rc=$?
  [ "$rc" = 3 ] || fail "helper: env marker must exit 3 (got $rc)"
  case "$out" in *"$ENV_MSG"*) ;; *) fail "helper: env-marker message missing: $out" ;; esac
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set"
}

test_helper_empty_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" empty); rc=$?
  [ "$rc" = 3 ] || fail "helper: empty env marker must exit 3 (got $rc)"
  case "$out" in *"$ENV_MSG"*) ;; *) fail "helper: empty env-marker message missing: $out" ;; esac
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set empty"
}

test_helper_path_backstop_refuses() {
  local out rc
  # Marker UNSET: only the git-common-dir backstop can fire here.
  out=$(run_guard_lib "$GATE_WT"); rc=$?
  [ "$rc" = 3 ] || fail "helper: gate worktree must exit 3 with the marker unset (got $rc)"
  case "$out" in *"$PATH_MSG"*) ;; *) fail "helper: path-backstop message missing: $out" ;; esac
  case "$out" in *"$ENV_MSG"*) fail "helper: backstop wrongly attributed to the env marker: $out" ;; esac
  pass "fm-gate-refuse-lib: refuses from a gate worktree via git-common-dir (marker unset)"
}

test_helper_normal_is_noop() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD"); rc=$?
  [ "$rc" = 0 ] || fail "helper: a normal session (neither signal) must not refuse (got $rc)"
  [ -z "$out" ] || fail "helper: normal session printed output: $out"
  pass "fm-gate-refuse-lib: no-op for a normal session (neither signal, set -eu clean)"
}

# --- fm-spawn wiring (refusal directions) -----------------------------------

# run_spawn <cwd> <home> <id> <proj> [ASSIGN...] -> combined output. The guard is
# sourced and called before any argument parsing or backend call, so no herdr
# stub is needed on the refusal path; a refused spawn must record no meta.
run_spawn() {
  local cwd=$1 home=$2 id=$3 proj=$4; shift 4
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_PROJECTS_OVERRIDE=$home/projects" "FM_CONFIG_OVERRIDE=$home/config" \
      "FM_SPAWN_NO_GUARD=1" "$@" \
      "$SPAWN" "$id" "$proj" ) 2>&1
}

test_spawn_refuses() {
  local home proj out rc
  home="$TMP/spawn-home"; mkdir -p "$home/data"
  proj=$(mk_normal_repo "$TMP/spawn-proj")

  # env-marker refuse: neutral cwd, marker set.
  out=$(run_spawn "$NORMAL_CWD" "$home" spawn-envmark "$proj" NO_MISTAKES_GATE=1); rc=$?
  [ "$rc" = 3 ] || fail "spawn: NO_MISTAKES_GATE must refuse (got $rc)"
  case "$out" in *"$ENV_MSG"*) ;; *) fail "spawn: env-marker message missing: $out" ;; esac
  [ ! -e "$home/state/spawn-envmark.meta" ] || fail "spawn: refused env-marker launch recorded meta"

  # path-backstop refuse: gate-worktree cwd, marker UNSET.
  out=$(run_spawn "$GATE_WT" "$home" spawn-backstop "$proj"); rc=$?
  [ "$rc" = 3 ] || fail "spawn: gate-worktree cwd must refuse with the marker unset (got $rc)"
  case "$out" in *"$PATH_MSG"*) ;; *) fail "spawn: path-backstop message missing: $out" ;; esac
  [ ! -e "$home/state/spawn-backstop.meta" ] || fail "spawn: refused backstop launch recorded meta"

  pass "fm-spawn: refuses on the env marker and the gate-worktree backstop, recording no meta"
}

# --- fm-send wiring (refusal directions) ------------------------------------

# run_send <cwd> <home> <target> <text> [ASSIGN...] -> combined output. The guard
# fires before any herdr command, so no pane stub is needed on the refusal path.
run_send() {
  local cwd=$1 home=$2 target=$3 text=$4; shift 4
  mkdir -p "$home/state"
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_SEND_SETTLE=0" "$@" \
      "$SEND" "$target" "$text" ) 2>&1
}

test_send_refuses() {
  local home out rc
  home="$TMP/send-home"; mkdir -p "$home/state"
  printf 'handle=%%1\nkind=ship\n' > "$home/state/lane-ok.meta"

  # env-marker refuse.
  out=$(run_send "$NORMAL_CWD" "$home" fm-lane-ok "hello captain" NO_MISTAKES_GATE=1); rc=$?
  [ "$rc" = 3 ] || fail "send: NO_MISTAKES_GATE must refuse (got $rc)"
  case "$out" in *"$ENV_MSG"*) ;; *) fail "send: env-marker message missing: $out" ;; esac

  # path-backstop refuse (marker UNSET).
  out=$(run_send "$GATE_WT" "$home" fm-lane-ok "hello captain"); rc=$?
  [ "$rc" = 3 ] || fail "send: gate-worktree cwd must refuse with the marker unset (got $rc)"
  case "$out" in *"$PATH_MSG"*) ;; *) fail "send: path-backstop message missing: $out" ;; esac

  pass "fm-send: refuses on the env marker and the gate-worktree backstop, before any steer"
}

# --- fm-teardown wiring (refusal directions) --------------------------------

# run_teardown <cwd> <state_dir> [ASSIGN...] -> combined output. The guard fires
# before the meta lookup and any landed-work check, so a trivial meta suffices and
# a refused teardown must leave the task untouched.
run_teardown() {
  local cwd=$1 state_dir=$2; shift 2
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$state_dir" "$@" \
      "$TEARDOWN" task-x1 ) 2>&1
}

mk_teardown_state() {
  local dir=$1
  mkdir -p "$dir"
  printf 'handle=%%1\nworktree=%s/wt\nkind=ship\nmode=no-mistakes\n' "$dir" > "$dir/task-x1.meta"
  printf '%s\n' "$dir"
}

test_teardown_refuses() {
  local st out rc

  # env-marker refuse: the task is left in place.
  st=$(mk_teardown_state "$TMP/teardown-envmark/state")
  out=$(run_teardown "$NORMAL_CWD" "$st" NO_MISTAKES_GATE=1); rc=$?
  [ "$rc" = 3 ] || fail "teardown: NO_MISTAKES_GATE must refuse (got $rc)"
  case "$out" in *"$ENV_MSG"*) ;; *) fail "teardown: env-marker message missing: $out" ;; esac
  [ -e "$st/task-x1.meta" ] || fail "teardown: refused env-marker teardown removed the task"

  # path-backstop refuse (marker UNSET).
  st=$(mk_teardown_state "$TMP/teardown-backstop/state")
  out=$(run_teardown "$GATE_WT" "$st"); rc=$?
  [ "$rc" = 3 ] || fail "teardown: gate-worktree cwd must refuse with the marker unset (got $rc)"
  case "$out" in *"$PATH_MSG"*) ;; *) fail "teardown: path-backstop message missing: $out" ;; esac
  [ -e "$st/task-x1.meta" ] || fail "teardown: refused backstop teardown removed the task"

  pass "fm-teardown: refuses on the env marker and the gate-worktree backstop, leaving the task"
}

# --- tracked .no-mistakes.yaml (authority-removal half) ---------------------

test_no_mistakes_yaml_disables_project_settings() {
  local file="$ROOT/.no-mistakes.yaml" tab
  [ -f "$file" ] || fail "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  tab=$(printf '\t')
  case "$(cat "$file")" in
    *"$tab"*) fail ".no-mistakes.yaml uses a tab (invalid YAML indentation)" ;;
  esac
  grep -qxE 'disable_project_settings:[[:space:]]+true' "$file" \
    || fail "top-level 'disable_project_settings: true' not found in .no-mistakes.yaml"
  pass ".no-mistakes.yaml sets disable_project_settings: true (authority-removal half of the gate boundary)"
}

test_helper_env_marker_refuses
test_helper_empty_env_marker_refuses
test_helper_path_backstop_refuses
test_helper_normal_is_noop
test_spawn_refuses
test_send_refuses
test_teardown_refuses
test_no_mistakes_yaml_disables_project_settings
