#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards on the herdr backend.
#
# Firstmate is a git repo of itself: linked herdr worktrees and secondmate homes
# all sit at a detached HEAD on the default branch, while the PRIMARY checkout
# (FM_ROOT) is a normal checkout on a real branch. The "tangle" is a crewmate
# branching/committing in the primary instead of its own worktree, stranding the
# primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the opened worktree is isolated.
#   GUARD 2 (detection)  - fm-guard alarms when the primary is on a feature branch,
#            and stays silent on the default branch or a detached HEAD.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the brief assertion ordering, and the fm-spawn abort - all hermetic over temp
# git repos and a stub `herdr` on PATH. (Upstream's fm-bootstrap TANGLE line has
# no analogue here: this fork has no fm-bootstrap; the guard covers detection.)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tangle-tests.XXXXXX")

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3: missing '$2' in: $1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: unexpected '$2' in: $1" ;; esac; }
assert_grep() { grep -qF "$2" "$1" || fail "$3"; }
expect_code() { [ "$2" = "$1" ] || fail "$3: expected exit $1, got $2"; }

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/lib-repo")

  git -C "$repo" checkout -q main
  out=$(fm_primary_tangle_branch "$repo" || true)
  [ -z "$out" ] || fail "default branch wrongly reported a tangle: '$out'"

  git -C "$repo" checkout -q -B fm/readme-restructure-d3
  out=$(fm_primary_tangle_branch "$repo" || true)
  [ "$out" = fm/readme-restructure-d3 ] || fail "feature branch not reported: '$out'"

  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q --detach
  out=$(fm_primary_tangle_branch "$repo" || true)
  [ -z "$out" ] || fail "detached HEAD wrongly reported a tangle: '$out'"

  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2: fm-guard banner -----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  pass "fm-guard: bordered tangle banner fires only for a feature branch in the primary"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  [ -f "$brief" ] || fail "brief was not scaffolded"
  assert_grep "$brief" "blocked: launched in primary checkout, not an isolated worktree" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "$brief" "The path check is authoritative" "brief must make the path check authoritative"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  { [ -n "$iso" ] && [ -n "$br" ]; } || fail "brief missing assertion ($iso) or branch step ($br)"
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A stub `herdr` whose `worktree create --json` reports FM_FAKE_WT as the opened
# worktree path (so fm-spawn's isolation guard runs against a path we control),
# and whose `agent start` returns a pane id (so the isolated proceed case can
# launch). Everything else is a silent no-op. Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "worktree create")
    printf '{"result":{"worktree":{"path":"%s","open_workspace_id":"ws-1"},"root_pane":{"pane_id":"rp-1"}}}\n' "${FM_FAKE_WT:-}"
    ;;
  "agent start")
    printf '{"result":{"agent":{"pane_id":"ap-1"}}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5
  mkdir -p "$home/data/$id" "$home/state"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_WT="$wt" CLAUDE_CONFIG_DIR="$home/claude" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data" "$home/claude"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the opened worktree resolves to a plain non-git directory.
  # (The suite runs under `set -u` only, so a non-zero spawn does not abort here.)
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  [ ! -f "$home/state/abort-notgit-dd4.meta" ] || fail "aborted spawn must not record meta"

  # Abort: the opened worktree resolves INTO the primary checkout (a subdir).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the opened worktree resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the opened worktree is a genuine, isolated worktree"
}

test_lib_classification
test_guard_banner
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
