#!/usr/bin/env bash
# Behavior tests for crew dispatch profiles (--model/--effort) on the herdr fork:
#   (a) --effort rejects values outside low|medium|high|xhigh|max|default
#   (b) --model/--effort land in the Claude launch command and in meta
#   (c) the literal `default` satisfies the backstop without emitting a flag
#   (d) config/crew-dispatch.json enforces an explicit profile on template
#       crewmate/scout spawns (the consultation backstop)
#   (e) an invalid dispatch file warns loudly and is not enforced
#   (f) raw launch commands are exempt from the backstop
#   (g) secondmate spawns are exempt and resolve config/secondmate-profile pins
#       (explicit flags still win)
#   (h) a secondmate spawn propagates config/crew-dispatch.json into the home
#       (and mirrors primary absence by removing a stale home copy)
#   (i) fm-config-push.sh pushes inheritable config to live secondmate homes
#   (j) batch dispatch forwards shared --model/--effort to every pair
#
# The real fm-spawn.sh runs with FM_ROOT_OVERRIDE pointing at a fake root whose
# bin/ stubs fm-guard/fm-fleet-sync/fm-project-mode/fm-backend, so no herdr,
# panes, or worktrees are touched. The backend stub logs the launch command it
# received, which is where the profile flags must appear.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
PUSH="$ROOT/bin/fm-config-push.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
TASK_TMP_IDS=""

cleanup() {
  local id
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
  for id in $TASK_TMP_IDS; do
    rm -rf "/tmp/fm-$id"
  done
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-dispatch-tests.XXXXXX")

track_task_tmp() { TASK_TMP_IDS="$TASK_TMP_IDS $1"; }

# make_case <name> -> case dir with fake root (stub bin/, state/, config/, data/),
# a project git repo at proj/, a worktree git repo at wt/, and a claude config dir.
make_case() {
  local d="$TMP_ROOT/$1" fakebin
  fakebin="$d/root/bin"
  mkdir -p "$d/root/state" "$d/root/config" "$d/root/data" "$fakebin" "$d/claudecfg"
  git -C "$d" init -q proj && git -C "$d/proj" commit -q --allow-empty -m init
  git -C "$d" init -q wt && git -C "$d/wt" commit -q --allow-empty -m init
  # Symlink the REAL spawn script (and the libs it sources relative to itself)
  # so batch dispatch's `$FM_ROOT/bin/fm-spawn.sh` re-exec runs actual code.
  ln -s "$ROOT/bin/fm-spawn.sh" "$fakebin/fm-spawn.sh"
  ln -s "$ROOT/bin/fm-ff-lib.sh" "$fakebin/fm-ff-lib.sh"
  ln -s "$ROOT/bin/fm-config-inherit-lib.sh" "$fakebin/fm-config-inherit-lib.sh"
  cat > "$fakebin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/fm-project-mode.sh" <<'SH'
#!/usr/bin/env bash
echo no-mistakes
SH
  cat > "$fakebin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  open)
    printf 'worktree=%s\nworkspace=ws-1\nrootpane=\n' "$FM_TEST_WT"
    ;;
  launch)
    # launch <id> <workspace> <worktree> <launch-cmd> [rootpane]: the command is $5.
    printf '%s\n' "$5" >> "$FM_TEST_LAUNCH_LOG"
    echo handle=p1
    ;;
esac
exit 0
SH
  chmod +x "$fakebin"/*.sh
  printf '%s\n' "$d"
}

write_brief() {  # <case-dir> <id>
  mkdir -p "$1/root/data/$2"
  echo "task brief" > "$1/root/data/$2/brief.md"
}

valid_dispatch_json() {
  cat <<'JSON'
{"rules":[{"when":"trivial edit","use":{"model":"haiku","effort":"low"}}],"default":{"model":"default"}}
JSON
}

# Seeded secondmate home OUTSIDE the fake root, with charter, markers, and the
# firstmate-home shape validate_firstmate_home_for_spawn expects.
make_home() {  # <case-dir> <id> -> home path
  local d=$1 id=$2 home="$1/home-$2"
  mkdir -p "$home/data" "$home/bin"
  echo "charter" > "$home/data/charter.md"
  echo "AGENTS" > "$home/AGENTS.md"
  printf '%s' "$id" > "$home/.fm-secondmate-home"
  printf 'ws-home-%s' "$id" > "$home/.fm-secondmate-home.workspace"
  printf '%s\n' "$home"
}

run_spawn() {  # <case-dir> <args...>
  local d=$1
  shift
  FM_SPAWN_NO_GUARD='' \
  FM_ROOT_OVERRIDE="$d/root" \
  FM_TEST_WT="$d/wt" \
  FM_TEST_LAUNCH_LOG="$d/launch.log" \
  CLAUDE_CONFIG_DIR="$d/claudecfg" \
    "$SPAWN" "$@"
}

test_rejects_bad_effort() {
  local d rc
  d=$(make_case bad-effort)
  set +e
  run_spawn "$d" bad-effort-x1 "$d/proj" --effort turbo > "$d/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "bad-effort: expected refusal, got $rc"
  grep -q -- '--effort must be one of' "$d/out" || fail "bad-effort: no vocabulary error"
  pass "fm-spawn rejects an unknown --effort value"
}

test_flags_reach_launch_and_meta() {
  local d
  d=$(make_case flags-launch)
  write_brief "$d" flags-x1
  track_task_tmp flags-x1
  : > "$d/launch.log"
  run_spawn "$d" flags-x1 "$d/proj" --model sonnet --effort low > "$d/out" 2>&1 \
    || fail "flags-launch: spawn failed: $(cat "$d/out")"
  grep -qF -- "--model 'sonnet' --effort 'low'" "$d/launch.log" \
    || fail "flags-launch: profile flags missing from launch command: $(cat "$d/launch.log")"
  grep -qxF 'model=sonnet' "$d/root/state/flags-x1.meta" || fail "flags-launch: model= not in meta"
  grep -qxF 'effort=low' "$d/root/state/flags-x1.meta" || fail "flags-launch: effort= not in meta"
  pass "explicit --model/--effort reach the Claude launch command and meta"
}

test_default_emits_no_flag() {
  local d
  d=$(make_case default-noflag)
  write_brief "$d" default-x1
  track_task_tmp default-x1
  : > "$d/launch.log"
  run_spawn "$d" default-x1 "$d/proj" --model default > "$d/out" 2>&1 \
    || fail "default-noflag: spawn failed: $(cat "$d/out")"
  grep -qF -- '--model' "$d/launch.log" && fail "default-noflag: literal default leaked a --model flag"
  grep -qxF 'model=default' "$d/root/state/default-x1.meta" || fail "default-noflag: model= not recorded"
  pass "--model default satisfies dispatch without emitting a launch flag"
}

test_backstop_refuses_unprofiled_spawn() {
  local d rc
  d=$(make_case backstop)
  valid_dispatch_json > "$d/root/config/crew-dispatch.json"
  set +e
  run_spawn "$d" backstop-x1 "$d/proj" > "$d/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "backstop: expected refusal, got $rc"
  grep -q 'crew-dispatch.json is active' "$d/out" || fail "backstop: refusal did not explain the backstop"
  [ ! -s "$d/launch.log" ] || fail "backstop: launch happened despite refusal"
  set +e
  run_spawn "$d" backstop-x2 "$d/proj" --scout > "$d/out2" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "backstop: scout spawn should also refuse, got $rc"
  pass "crew-dispatch.json enforces an explicit profile on crew and scout spawns"
}

test_invalid_dispatch_warns_not_enforced() {
  local d
  d=$(make_case invalid-dispatch)
  write_brief "$d" invalid-x1
  track_task_tmp invalid-x1
  echo '{not json' > "$d/root/config/crew-dispatch.json"
  : > "$d/launch.log"
  run_spawn "$d" invalid-x1 "$d/proj" > "$d/out" 2>&1 \
    || fail "invalid-dispatch: spawn should proceed despite invalid file: $(cat "$d/out")"
  grep -q 'CREW_DISPATCH: invalid' "$d/out" || fail "invalid-dispatch: no loud invalid-file warning"
  pass "an invalid dispatch file warns loudly and is not enforced"
}

test_raw_launch_exempt_from_backstop() {
  local d
  d=$(make_case raw-exempt)
  write_brief "$d" raw-x1
  track_task_tmp raw-x1
  valid_dispatch_json > "$d/root/config/crew-dispatch.json"
  : > "$d/launch.log"
  run_spawn "$d" raw-x1 "$d/proj" 'FOO=1 mycustom-agent run' > "$d/out" 2>&1 \
    || fail "raw-exempt: raw launch should bypass the backstop: $(cat "$d/out")"
  grep -qF 'mycustom-agent run' "$d/launch.log" || fail "raw-exempt: raw command did not reach launch"
  pass "raw launch commands are exempt from the dispatch backstop"
}

test_secondmate_pin_resolves_profile() {
  local d home
  d=$(make_case sm-pin)
  home=$(make_home "$d" sm-pin-x1)
  track_task_tmp sm-pin-x1
  printf 'sonnet high\n' > "$d/root/config/secondmate-profile"
  : > "$d/launch.log"
  run_spawn "$d" sm-pin-x1 "$home" --secondmate > "$d/out" 2>&1 \
    || fail "sm-pin: secondmate spawn failed: $(cat "$d/out")"
  grep -qF -- "--model 'sonnet' --effort 'high'" "$d/launch.log" \
    || fail "sm-pin: pin did not reach the launch command: $(cat "$d/launch.log")"
  grep -qxF 'model=sonnet' "$d/root/state/sm-pin-x1.meta" || fail "sm-pin: model= not in meta"
  pass "config/secondmate-profile pins the secondmate launch profile"
}

test_secondmate_explicit_flags_beat_pin() {
  local d home
  d=$(make_case sm-override)
  home=$(make_home "$d" sm-ovr-x1)
  track_task_tmp sm-ovr-x1
  printf 'sonnet high\n' > "$d/root/config/secondmate-profile"
  : > "$d/launch.log"
  run_spawn "$d" sm-ovr-x1 "$home" --secondmate --model haiku > "$d/out" 2>&1 \
    || fail "sm-override: secondmate spawn failed: $(cat "$d/out")"
  grep -qF -- "--model 'haiku'" "$d/launch.log" || fail "sm-override: explicit --model lost to the pin"
  grep -qF -- "--effort 'high'" "$d/launch.log" || fail "sm-override: unpinned axis should still come from the file"
  pass "explicit spawn flags beat the secondmate-profile pin per axis"
}

test_secondmate_exempt_from_backstop_and_inherits() {
  local d home
  d=$(make_case sm-inherit)
  home=$(make_home "$d" sm-inh-x1)
  track_task_tmp sm-inh-x1
  valid_dispatch_json > "$d/root/config/crew-dispatch.json"
  : > "$d/launch.log"
  run_spawn "$d" sm-inh-x1 "$home" --secondmate > "$d/out" 2>&1 \
    || fail "sm-inherit: secondmate spawn should be exempt from the backstop: $(cat "$d/out")"
  cmp -s "$d/root/config/crew-dispatch.json" "$home/config/crew-dispatch.json" \
    || fail "sm-inherit: crew-dispatch.json was not propagated into the home"
  pass "secondmate spawns bypass the backstop and inherit crew-dispatch.json"
}

test_secondmate_mirrors_primary_absence() {
  local d home
  d=$(make_case sm-absence)
  home=$(make_home "$d" sm-abs-x1)
  track_task_tmp sm-abs-x1
  mkdir -p "$home/config"
  echo '{"rules":[]}' > "$home/config/crew-dispatch.json"
  : > "$d/launch.log"
  run_spawn "$d" sm-abs-x1 "$home" --secondmate > "$d/out" 2>&1 \
    || fail "sm-absence: secondmate spawn failed: $(cat "$d/out")"
  [ ! -e "$home/config/crew-dispatch.json" ] \
    || fail "sm-absence: stale home copy survived although the primary has no dispatch file"
  pass "a secondmate spawn mirrors primary config absence into the home"
}

test_config_push_reaches_live_homes() {
  local d home
  d=$(make_case push)
  home=$(make_home "$d" push-x1)
  valid_dispatch_json > "$d/root/config/crew-dispatch.json"
  cat > "$d/root/state/push-x1.meta" <<EOF
handle=p9
kind=secondmate
home=$home
EOF
  FM_ROOT_OVERRIDE="$d/root" "$PUSH" > "$d/out" 2>&1 \
    || fail "push: fm-config-push failed: $(cat "$d/out")"
  grep -q 'crew-dispatch.json: pushed' "$d/out" || fail "push: no pushed report line: $(cat "$d/out")"
  cmp -s "$d/root/config/crew-dispatch.json" "$home/config/crew-dispatch.json" \
    || fail "push: file did not land in the home"
  pass "fm-config-push pushes inheritable config to live secondmate homes"
}

test_batch_forwards_shared_flags() {
  local d rc
  d=$(make_case batch-flags)
  valid_dispatch_json > "$d/root/config/crew-dispatch.json"
  # Without flags each pair must die at the backstop; with a shared profile the
  # pairs get past it (and fail later at the missing brief), proving forwarding.
  set +e
  run_spawn "$d" bf-a-x1="$d/proj" > "$d/out-none" 2>&1
  set -e
  grep -q 'crew-dispatch.json is active' "$d/out-none" || fail "batch-flags: unprofiled pair did not hit the backstop"
  set +e
  run_spawn "$d" bf-b-x1="$d/proj" --model default > "$d/out-flag" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "batch-flags: pair with no brief should still fail later"
  grep -q 'crew-dispatch.json is active' "$d/out-flag" && fail "batch-flags: shared --model was not forwarded to the pair"
  grep -q 'no brief' "$d/out-flag" || fail "batch-flags: expected the missing-brief failure after passing the backstop"
  pass "batch dispatch forwards shared --model/--effort to every pair"
}

test_rejects_bad_effort
test_flags_reach_launch_and_meta
test_default_emits_no_flag
test_backstop_refuses_unprofiled_spawn
test_invalid_dispatch_warns_not_enforced
test_raw_launch_exempt_from_backstop
test_secondmate_pin_resolves_profile
test_secondmate_explicit_flags_beat_pin
test_secondmate_exempt_from_backstop_and_inherits
test_secondmate_mirrors_primary_absence
test_config_push_reaches_live_homes
test_batch_forwards_shared_flags
