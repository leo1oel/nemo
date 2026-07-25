#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh scaffolds. Focused on contract wording the
# supervisor relies on, since the brief/charter text IS the crewmate/secondmate
# instruction. Ports of upstream fm-brief changes land their assertions here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief.XXXXXX")

scaffold_secondmate() {  # <id> -> prints brief path
  local id=$1 home="$TMP/$1-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_SECONDMATE_CHARTER="own $id reliability" \
    "$BRIEF" "$id" --secondmate demo >/dev/null 2>&1 || return 1
  printf '%s\n' "$home/data/$id/brief.md"
}

# A marked from-firstmate request needs one correlated answer, not a receipt: the
# charter must forbid a generic working: start acknowledgement (upstream #926,
# adapted to this fork's key-free status model).
test_secondmate_charter_forbids_start_ack() {
  local brief
  brief=$(scaffold_secondmate wid-a1) || fail "secondmate scaffold failed"
  [ -f "$brief" ] || fail "no charter brief scaffolded at $brief"
  grep -qF 'merely to confirm the request arrived' "$brief" \
    || fail "charter must forbid a generic working: start acknowledgement"
  grep -qF 'marked from-firstmate request' "$brief" \
    || fail "charter lost its marked-request return contract"
  pass "fm-brief: secondmate charter forbids a generic start acknowledgement for a marked request"
}

test_secondmate_charter_forbids_start_ack
