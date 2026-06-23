#!/usr/bin/env bash
# Behavior test for bin/fm-send.sh — verified submit (incident afk-invx-i5).
# fm-send types the steer ONCE, submits with Enter, and verifies the composer
# cleared via the SHARED border-aware detector in bin/fm-herdr-lib.sh. A
# positively-confirmed swallow (the text is still sitting in the composer after
# all retries) must exit NON-ZERO, so a steer that does not land is no longer
# silent. A clean submit exits 0. The herdr command is stubbed on PATH (same
# bordered-composer shape as the daemon tests); nothing touches a live server.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# Build a sandbox: an EMPTY state dir (so fm-guard.sh stays silent — no meta in
# flight) and a stub `herdr` that simulates a bordered claude composer in a file.
#   send-text  -> composer becomes "│ > <text> │"
#   send-keys enter -> composer clears to "│ > │", UNLESS $FM_FAKE_SWALLOW exists
#                      (then the text stays — a swallowed Enter). FM_FAKE_PERSIST
#                      keeps it across all retries; otherwise it clears after one.
mk_env() {
  local fb
  TMP=$(mktemp -d)
  fb="$TMP/bin"; mkdir -p "$TMP/state" "$fb"
  printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$TMP/composer"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "$1 $2" in
  "pane read")
    printf 'history\n\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90\n'
    cat "$COMPOSER" 2>/dev/null
    printf '\xe2\x94\x94\xe2\x94\x80\xe2\x94\x98\n  Opus 4.8 | Context 0%%\n  bypass on\n'
    ;;
  "pane send-text")
    [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
    printf '\xe2\x94\x82 > %s \xe2\x94\x82\n' "$4" > "$COMPOSER"
    ;;
  "pane send-keys")
    shift 3
    for k in "$@"; do
      case "$k" in
        enter|Enter)
          if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
            [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
          else
            printf '\xe2\x94\x82 > \xe2\x94\x82\n' > "$COMPOSER"
          fi
          ;;
      esac
    done
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
}

test_clean_submit_exits_zero() {
  mk_env
  PATH="$TMP/bin:$PATH" FM_STATE_OVERRIDE="$TMP/state" FM_FAKE_COMPOSER="$TMP/composer" \
    FM_SEND_SLEEP=0 FM_SEND_RETRIES=3 \
    "$SEND" p1 "hello crewmate" >/dev/null 2>&1 \
    || fail "clean submit (composer cleared) should exit 0"
  rm -rf "$TMP"; TMP=
  pass "fm-send exits 0 on a verified (composer-cleared) submit"
}

test_confirmed_swallow_exits_nonzero() {
  mk_env
  : > "$TMP/swallow"
  if PATH="$TMP/bin:$PATH" FM_STATE_OVERRIDE="$TMP/state" FM_FAKE_COMPOSER="$TMP/composer" \
       FM_FAKE_SWALLOW="$TMP/swallow" FM_FAKE_PERSIST_SWALLOW=1 \
       FM_SEND_SLEEP=0 FM_SEND_RETRIES=3 \
       "$SEND" p1 "steer that gets swallowed" 2>/dev/null; then
    fail "a positively-confirmed swallow must exit non-zero"
  fi
  rm -rf "$TMP"; TMP=
  pass "fm-send exits non-zero on a confirmed swallow (text left in composer)"
}

test_clean_submit_exits_zero
test_confirmed_swallow_exits_nonzero
