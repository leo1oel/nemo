#!/usr/bin/env bash
# Behavior tests for the bearings projection (bin/fm-bearings-snapshot.sh), the
# "pick up where I left off" view over the canonical fleet snapshot.
#
# It projects fm-fleet-snapshot.sh down to the fields a catch-up read needs and
# is LOCAL-ONLY by default (zero network/gh). This suite proves the projected
# schema, the local-only default (a stubbed gh is never invoked), and the landed
# roll-up from the Done backlog.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq not found"; exit 0; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings.XXXXXX")

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
- [x] shipped-a1 - the earlier change - https://github.com/leo1oel/yourapp/pull/12 (merged 2026-07-09)
- [x] scouted-b2 - the investigation - data/scouted-b2/report.md (reported 2026-07-08)
MD
  printf '%s\n' "$home"
}

# A gh stub that records any invocation, to prove the local-only default path
# never touches the network.
make_gh_marker_bin() {
  local dir=$1 marker=$2 gb
  gb="$dir/ghbin"; mkdir -p "$gb"
  cat > "$gb/gh" <<SH
#!/usr/bin/env bash
printf 'gh called: %s\n' "\$*" >> '$marker'
exit 0
SH
  chmod +x "$gb/gh"
  printf '%s\n' "$gb"
}

run_bearings() {  # <home> [ASSIGN...] -- <args...>
  local home=$1; shift
  local assigns=() ; while [ "$1" != "--" ]; do assigns+=("$1"); shift; done; shift
  env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_CONFIG_OVERRIDE=$home/config" "FM_PROJECTS_OVERRIDE=$home/projects" "${assigns[@]}" \
      "$BEARINGS" "$@" 2>&1
}

test_projection_schema() {
  local home out
  home=$(make_home "$TMP/home-a")
  out=$(run_bearings "$home" -- --json) || fail "bearings --json failed: $out"
  printf '%s' "$out" | jq -e '.schema == "fm-bearings.v1"' >/dev/null \
    || fail "bearings schema wrong: $(printf '%s' "$out" | head -3)"
  printf '%s' "$out" | jq -e 'has("in_flight") and has("landed") and has("gates") and has("prs")' >/dev/null \
    || fail "bearings projection missing a required surface"
  pass "bearings-snapshot: projects the fm-bearings.v1 schema with the catch-up surfaces"
}

test_local_only_default() {
  local home marker gb out
  home=$(make_home "$TMP/home-b")
  marker="$TMP/gh-called"
  gb=$(make_gh_marker_bin "$TMP/ghmark" "$marker")
  out=$(run_bearings "$home" "PATH=$gb:$PATH" -- --json) || fail "bearings failed: $out"
  [ ! -e "$marker" ] || fail "the default bearings snapshot invoked gh (must be local-only): $(cat "$marker")"
  printf '%s' "$out" | jq -e '.prs | test("not_requested")' >/dev/null \
    || fail "the local-only default must state prs were not requested"
  pass "bearings-snapshot: local-only by default - no gh/network call, prs marked not_requested"
}

test_landed_rollup() {
  local home out
  home=$(make_home "$TMP/home-c")
  out=$(run_bearings "$home" -- --json) || fail "bearings failed: $out"
  printf '%s' "$out" | jq -e '.landed | map(.id) | index("shipped-a1")' >/dev/null \
    || fail "a merged Done PR must appear in landed[]"
  printf '%s' "$out" | jq -e '.landed | map(.id) | index("scouted-b2")' >/dev/null \
    || fail "a completed Done scout must appear in landed[]"
  pass "bearings-snapshot: rolls up merged PRs and completed scouts from the Done backlog"
}

test_projection_schema
test_local_only_default
test_landed_rollup
