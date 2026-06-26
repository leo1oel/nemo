#!/usr/bin/env bash
# fm-send from-firstmate marker for secondmate targets (herdr backend).
#
# A secondmate is itself a firstmate, so a request relayed to it lands in its own
# chat - which the main firstmate never reads (the only channel back is the terse
# status file). fm-send therefore prepends a from-firstmate marker
# (bin/fm-marker-lib.sh) when, and only when, the resolved target is a bare
# `fm-<id>` whose meta records kind=secondmate, so the secondmate can recognize
# the request and route its reply via the status path. These tests pin that
# behavior hermetically (a stubbed `herdr` on PATH logs the exact send-text bytes;
# nothing touches a live server):
#   1. A send to a kind=secondmate target prepends the marker to the literal text.
#   2. A send to a crewmate (kind=ship) target sends the bare text, no marker.
#   3. The --key path never carries the marker.
#   4. The marker is exactly "[fm-from-firstmate]" + ASCII 0x1f, and the
#      fm_message_from_firstmate detector keys on that untypable sequence.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
SEND="$ROOT/bin/fm-send.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-marker-tests.XXXXXX")

# A stub `herdr` that logs the exact text of every `pane send-text` to FM_SEND_LOG
# and simulates a bordered claude composer that clears on Enter, so fm-send's verify
# path reaches a clean "empty" verdict on the first retry. Only send-text is logged;
# Enter (send-keys) and the --key path are not, so the log holds exactly what was
# typed into the composer.
make_stub() {
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "${1:-} ${2:-}" in
  "pane read")
    printf 'history\n\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90\n'
    cat "$COMPOSER" 2>/dev/null
    printf '\xe2\x94\x94\xe2\x94\x80\xe2\x94\x98\n  Opus 4.8 | Context 0%%\n  bypass on\n'
    ;;
  "pane send-text")
    printf '%s' "${4:-}" >> "${FM_SEND_LOG:?FM_SEND_LOG unset}"
    printf '\xe2\x94\x82 > %s \xe2\x94\x82\n' "${4:-}" > "$COMPOSER"
    ;;
  "pane send-keys")
    shift 3 2>/dev/null || true
    for k in "$@"; do
      case "$k" in enter|Enter) printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$COMPOSER" ;; esac
    done
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
}

# A fresh home with a fakebin (herdr stub), an empty state/, and a composer file.
# Echoes the home dir.
setup_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/fakebin"
  make_stub "$home/fakebin"
  printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$home/composer"
  printf '%s\n' "$home"
}

# run_send <home> <log> -- <fm-send args...>. FM_ROOT_OVERRIDE points fm-guard at the
# non-git home so its worktree-tangle check stays silent; FM_STATE_OVERRIDE is where
# fm-send resolves the target meta. FM_SEND_SETTLE=0 keeps the run fast.
run_send() {
  local home=$1 log=$2; shift 2
  : > "$log"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_FAKE_COMPOSER="$home/composer" FM_SEND_LOG="$log" \
    FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

test_secondmate_target_is_marked() {
  local home log rc got
  home=$(setup_home sm); log="$home/send.log"
  printf 'handle=pane-d\nkind=secondmate\n' > "$home/state/domain.meta"
  run_send "$home" "$log" fm-domain "audit the build"; rc=$?
  [ "$rc" = 0 ] || fail "send to a secondmate target should succeed (rc=$rc)"
  got=$(cat "$log")
  if [ "$got" != "${FM_FROMFIRST_MARK}audit the build" ]; then
    fail "secondmate send should be marker+text; got bytes: $(printf '%s' "$got" | od -An -c | tr -s ' ')"
  fi
  pass "fm-send: a kind=secondmate target gets the from-firstmate marker prepended"
}

test_crewmate_target_is_not_marked() {
  local home log rc got
  home=$(setup_home crew); log="$home/send.log"
  printf 'handle=pane-b\nkind=ship\n' > "$home/state/build.meta"
  run_send "$home" "$log" fm-build "fix the test"; rc=$?
  [ "$rc" = 0 ] || fail "send to a crewmate target should succeed (rc=$rc)"
  got=$(cat "$log")
  [ "$got" = "fix the test" ] || fail "crewmate send should be bare text; got: $(printf '%s' "$got" | od -An -c | tr -s ' ')"
  pass "fm-send: a kind=ship target is sent bare, with no marker"
}

test_key_path_is_not_marked() {
  local home log rc got
  home=$(setup_home key); log="$home/send.log"
  printf 'handle=pane-d\nkind=secondmate\n' > "$home/state/domain.meta"
  run_send "$home" "$log" fm-domain --key Escape; rc=$?
  [ "$rc" = 0 ] || fail "the --key path should succeed (rc=$rc)"
  got=$(cat "$log")
  [ -z "$got" ] || fail "the --key path must not send-text (and so never marks); got: $(printf '%s' "$got" | od -An -c)"
  pass "fm-send: the --key path never carries the marker"
}

test_marker_bytes_and_detector() {
  local expected
  expected="[fm-from-firstmate]$(printf '\037')"
  [ "$FM_FROMFIRST_MARK" = "$expected" ] || fail "FM_FROMFIRST_MARK is not the label + ASCII 0x1f"
  fm_message_from_firstmate "${FM_FROMFIRST_MARK}do the work" || fail "detector missed a marked message"
  fm_message_from_firstmate "[fm-from-firstmate] typed by hand" && fail "detector matched label text without the 0x1f separator"
  fm_message_from_firstmate "ordinary captain message" && fail "detector matched an unmarked message"
  pass "fm-marker-lib: marker is label + 0x1f and the detector keys on the untypable sequence"
}

test_secondmate_target_is_marked
test_crewmate_target_is_not_marked
test_key_path_is_not_marked
test_marker_bytes_and_detector
