#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: PR merges must record pr= and any available
# pr_head= in task metadata before calling gh-axi pr merge.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-merge-tests.XXXXXX")

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin"
  touch "$case_dir/state/.last-watcher-beat"
  cat > "$case_dir/state/task-x1.meta" <<EOF
handle=pane-1
workspace=ws-1
worktree=$case_dir/wt
project=$case_dir/project
kind=ship
mode=no-mistakes
EOF
  printf '%s\n' "$case_dir"
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head'; exit 0 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_records_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "records-before-merge: expected success, got $rc"
  grep -qxF 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    || fail "records-before-merge: pr= was not recorded"
  grep -qxF 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    || fail "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge https://github.com/example/repo/pull/9' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked"
  pass "fm-pr-merge records pr= and pr_head= before merging"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 1 ] || fail "merge-fails: expected gh-axi failure to propagate, got $rc"
  grep -qxF 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    || fail "merge-fails: pr= should be recorded before merge failure"
  pass "fm-pr-merge propagates merge failure after recording metadata"
}

test_extra_args_forwarded() {
  local case_dir
  case_dir=$(make_case extra-args)
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge https://github.com/example/repo/pull/15 --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: merge flags were not forwarded"
  pass "fm-pr-merge forwards extra gh-axi merge flags"
}

test_missing_meta_refuses_before_merge() {
  local case_dir rc
  case_dir="$TMP_ROOT/missing-meta"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 1 ] || fail "missing-meta: expected refusal, got $rc"
  grep -qF 'no meta for task missing-x1' "$case_dir/stderr" \
    || fail "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi was invoked"
  [ ! -e "$case_dir/state/missing-x1.check.sh" ] || fail "missing-meta: check poll was armed"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_records_before_merging
test_merge_failure_propagates_after_recording
test_extra_args_forwarded
test_missing_meta_refuses_before_merge
