#!/usr/bin/env bash
# Behavior tests for bin/fm-backlog-handoff.sh block moves:
#   (a) an item with an indented multi-line body moves as ONE block - header
#       plus body - leaving nothing orphaned in the main backlog
#   (b) a neighboring non-matched item keeps its own indented body in place
#   (c) fm_pid_identity is locale-invariant (LC_ALL pinned), so the watcher
#       guards accept a live watcher recorded under a different locale
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-backlog-handoff-tests.XXXXXX")

test_moves_full_item_block() {
  local d="$TMP_ROOT/block-move" home out
  home="$d/home-sm-x1"
  mkdir -p "$d/root/data" "$home/data" "$home/bin"
  printf 'sm-x1' > "$home/.fm-secondmate-home"
  echo agents > "$home/AGENTS.md"
  cat > "$d/root/data/secondmates.md" <<EOF
- sm-x1 - triage duty (home: $home; scope: triage; projects: proj-a; added 2026-07-10)
EOF
  cat > "$d/root/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] move-me-a1 - fix the parser (repo: proj-a)
  ## Intent
  Parser drops trailing commas.
  blocked-by: none - ready when picked up
- [ ] stay-here-b2 - tune the cache (repo: proj-b)
  Body note that must stay with the kept item.

## Done
EOF
  out=$(FM_ROOT_OVERRIDE="$d/root" FM_DATA_OVERRIDE="$d/root/data" "$HANDOFF" sm-x1 move-me-a1 2>&1) \
    || fail "block-move: handoff failed: $out"
  grep -qF 'move-me-a1' "$d/root/data/backlog.md" && fail "block-move: moved header still in main backlog"
  grep -qF 'Parser drops trailing commas.' "$d/root/data/backlog.md" && fail "block-move: body orphaned in main backlog"
  grep -qF '## Intent' "$d/root/data/backlog.md" && fail "block-move: indented body heading orphaned in main backlog"
  grep -qF 'move-me-a1' "$home/data/backlog.md" || fail "block-move: header missing from secondmate backlog"
  grep -qF 'Parser drops trailing commas.' "$home/data/backlog.md" || fail "block-move: body missing from secondmate backlog"
  grep -qF 'blocked-by: none' "$home/data/backlog.md" || fail "block-move: body tail missing from secondmate backlog"
  grep -qF 'stay-here-b2' "$d/root/data/backlog.md" || fail "block-move: kept item header lost"
  grep -qF 'Body note that must stay' "$d/root/data/backlog.md" || fail "block-move: kept item body lost"
  grep -qF 'Body note that must stay' "$home/data/backlog.md" && fail "block-move: kept item body leaked to secondmate"
  pass "handoff moves the full item block and keeps neighbors' bodies in place"
}

test_pid_identity_locale_invariant() {
  local a b
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  a=$(LC_ALL=C fm_pid_identity $$) || fail "locale: identity read failed under C"
  b=$(LC_ALL=ko_KR.UTF-8 fm_pid_identity $$ 2>/dev/null) || fail "locale: identity read failed under ko_KR"
  [ "$a" = "$b" ] || fail "locale: identity differs across locales: '$a' vs '$b'"
  pass "fm_pid_identity is locale-invariant"
}

# A registry line whose summary/scope prose contains a parenthetical BEFORE the
# structured (home: ...) field must still resolve the home. The old ^[^(]* prefix
# stopped at that first parenthesis and reported the entry as having no home.
test_resolves_home_after_parenthetical() {
  local d="$TMP_ROOT/paren-home" home out
  home="$d/home-sm-x2"
  mkdir -p "$d/root/data" "$home/data" "$home/bin"
  printf 'sm-x2' > "$home/.fm-secondmate-home"
  echo agents > "$home/AGENTS.md"
  cat > "$d/root/data/secondmates.md" <<EOF
- sm-x2 - triage duty (legacy alias kept) (home: $home; scope: triage; projects: proj-a; added 2026-07-10)
EOF
  cat > "$d/root/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] move-me-c3 - fix the parser (repo: proj-a)

## Done
EOF
  out=$(FM_ROOT_OVERRIDE="$d/root" FM_DATA_OVERRIDE="$d/root/data" "$HANDOFF" sm-x2 move-me-c3 2>&1) \
    || fail "paren-home: handoff failed (home not resolved past the parenthetical?): $out"
  grep -qF 'move-me-c3' "$home/data/backlog.md" || fail "paren-home: item not moved into the secondmate home"
  grep -qF 'move-me-c3' "$d/root/data/backlog.md" && fail "paren-home: moved item still in main backlog"
  pass "handoff resolves the secondmate home when a parenthetical precedes the (home: ...) field"
}

test_moves_full_item_block
test_pid_identity_locale_invariant
test_resolves_home_after_parenthetical
