#!/usr/bin/env bash
# Behavior tests for bin/fm-review-diff.sh:
#   (a) no pr= recorded -> diff compares the local branch (unchanged path)
#   (b) pr_head= recorded and present in the worktree odb -> compare ref is the
#       PR head, so review sees fix-round commits the local branch lags behind
#   (c) pr= recorded but the head is unresolvable -> loud warning + fallback to
#       the local branch (never a hard failure)
#   (d) pr_head= absent -> the PR number is parsed from pr= and refs/pull/<n>/head
#       is fetched from origin
#
# The real script is symlinked into a fake root (its FM_ROOT/state resolve from
# BASH_SOURCE) beside a stub fm-guard; repos are real throwaway git repos.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-review-diff-tests.XXXXXX")

# make_case <name> <id> -> case dir with fake root, origin bare repo, project
# clone, and a crewmate worktree clone on branch fm/<id> holding one commit.
make_case() {
  local d="$TMP_ROOT/$1" id=$2
  mkdir -p "$d/root/bin" "$d/root/state"
  ln -s "$ROOT/bin/fm-review-diff.sh" "$d/root/bin/fm-review-diff.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/root/bin/fm-guard.sh"
  chmod +x "$d/root/bin/fm-guard.sh"
  git init -q --bare "$d/origin.git"
  git init -q -b main "$d/seed"
  ( cd "$d/seed" && echo base > base.txt && git add . && git commit -q -m base \
    && git remote add origin "$d/origin.git" && git push -q origin main ) || fail "$1: seed setup failed"
  git clone -q "$d/origin.git" "$d/proj"
  git clone -q "$d/origin.git" "$d/wt"
  ( cd "$d/wt" && git checkout -q -b "fm/$id" \
    && echo change > work.txt && git add . && git commit -q -m "crew change" ) || fail "$1: worktree setup failed"
  cat > "$d/root/state/$id.meta" <<EOF
handle=p1
worktree=$d/wt
project=$d/proj
kind=ship
mode=no-mistakes
EOF
  printf '%s\n' "$d"
}

run_review_diff() {  # <case-dir> <id> [flags...]
  local d=$1; shift
  "$d/root/bin/fm-review-diff.sh" "$@"
}

test_no_pr_uses_local_branch() {
  local d out
  d=$(make_case no-pr rd-a1)
  out=$(run_review_diff "$d" rd-a1 --stat 2>&1) || fail "no-pr: review-diff failed: $out"
  printf '%s' "$out" | grep -qF 'work.txt' || fail "no-pr: branch change missing from diff"
  printf '%s' "$out" | grep -q 'warning: PR head unavailable' && fail "no-pr: unexpected PR warning"
  pass "without pr= the diff compares the local branch"
}

test_recorded_pr_head_wins() {
  local d out pr_head
  d=$(make_case recorded-head rd-b1)
  # Simulate a no-mistakes fix round: one more commit exists as the PR head,
  # while the local branch lags one commit behind it.
  ( cd "$d/wt" && echo fix > fixround.txt && git add . && git commit -q -m "fix round" )
  pr_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard HEAD~1
  cat >> "$d/root/state/rd-b1.meta" <<EOF
pr=https://github.com/example/repo/pull/12
pr_head=$pr_head
EOF
  out=$(run_review_diff "$d" rd-b1 --stat 2>&1) || fail "recorded-head: review-diff failed: $out"
  printf '%s' "$out" | grep -qF 'fixround.txt' || fail "recorded-head: PR-head-only commit missing (compared the lagging branch?)"
  pass "a reachable recorded pr_head= becomes the compare ref"
}

test_unresolvable_pr_falls_back_with_warning() {
  local d out
  d=$(make_case unresolvable rd-c1)
  cat >> "$d/root/state/rd-c1.meta" <<EOF
pr=https://github.com/example/repo/pull/9999
pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
EOF
  out=$(run_review_diff "$d" rd-c1 --stat 2>&1) || fail "unresolvable: fallback should not hard-fail: $out"
  printf '%s' "$out" | grep -q 'warning: PR head unavailable' || fail "unresolvable: missing fallback warning"
  printf '%s' "$out" | grep -qF 'work.txt' || fail "unresolvable: local-branch fallback diff missing"
  pass "an unresolvable PR head warns loudly and falls back to the local branch"
}

test_refs_pull_head_fetched() {
  local d out pr_head
  d=$(make_case pull-ref rd-d1)
  # Publish a PR head only as refs/pull/7/head on origin; the worktree has
  # neither the object nor a recorded pr_head=, so it must fetch the ref.
  ( cd "$d/seed" && git checkout -q -b prwork && echo pr > prref.txt && git add . \
    && git commit -q -m "pr head commit" && git push -q origin "HEAD:refs/pull/7/head" \
    && git checkout -q main )
  pr_head=$(git -C "$d/origin.git" rev-parse refs/pull/7/head)
  [ -n "$pr_head" ] || fail "pull-ref: origin ref setup failed"
  echo "pr=https://github.com/example/repo/pull/7" >> "$d/root/state/rd-d1.meta"
  out=$(run_review_diff "$d" rd-d1 --stat 2>&1) || fail "pull-ref: review-diff failed: $out"
  printf '%s' "$out" | grep -qF 'prref.txt' || fail "pull-ref: refs/pull head content missing from diff"
  printf '%s' "$out" | grep -q 'warning: PR head unavailable' && fail "pull-ref: fetch path wrongly warned"
  pass "a missing pr_head= is resolved by fetching refs/pull/<n>/head"
}

test_no_pr_uses_local_branch
test_recorded_pr_head_wins
test_unresolvable_pr_falls_back_with_warning
test_refs_pull_head_fetched
