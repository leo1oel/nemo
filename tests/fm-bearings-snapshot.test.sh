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

# Seed a valid seeded secondmate home with a backlog read from stdin.
make_secondmate_home() {  # <home> <id>  (backlog on stdin)
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/data" "$home/bin"
  printf '%s' "$id" > "$home/.fm-secondmate-home"
  printf '# secondmate home\n' > "$home/AGENTS.md"
  cat > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

register_secondmate() {  # <main-home> <id> <home-path>
  local main=$1 id=$2 home=$3
  printf 'kind=secondmate\nhome=%s\nhandle=fmpane-%s\n' "$home" "$id" > "$main/state/$id.meta"
  printf -- '- %s - scope (home: %s; scope: work; projects: demo; added 2026-07-14)\n' "$id" "$home" >> "$main/data/secondmates.md"
}

# Bearings surfaces each registered secondmate's authoritative home state: its
# in-flight/held work and Done land under the secondmate's owner, and a home that
# could not be read shows as state unknown with an omitted disclosure. This uses the
# deterministic externally_held / unknown states (no live child backend needed).
test_bearings_secondmate_surfacing() {
  local main sm out
  main="$TMP/main-sm"; mkdir -p "$main/state" "$main/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$main/data/backlog.md"
  : > "$main/data/secondmates.md"
  sm=$(make_secondmate_home "$TMP/sm-good" mate-x <<'MD'
## In flight

## Queued
- [ ] q1 - a queued feature (repo: demo) blocked-by: dep7 - waits on dep7

## Done
- [x] mate-done - a merge the mate managed - https://github.com/o/r/pull/9 (repo: demo) (merged 2026-07-12)
MD
)
  register_secondmate "$main" mate-x "$sm"
  register_secondmate "$main" mate-bad "$TMP/no-such-home"
  out=$(run_bearings "$main" -- --json) || fail "bearings failed: $out"
  printf '%s' "$out" | jq -e 'has("secondmates")' >/dev/null \
    || fail "bearings must project a secondmates surface: $out"
  printf '%s' "$out" | jq -e '.secondmates[] | select(.id == "mate-x") | .state == "externally_held"' >/dev/null \
    || fail "a valid secondmate home must surface its authoritative state: $out"
  printf '%s' "$out" | jq -e '.secondmates[] | select(.id == "mate-bad") | .state == "unknown" and (.reason | test("invalid home"))' >/dev/null \
    || fail "an unreadable secondmate home must surface as unknown: $out"
  printf '%s' "$out" | jq -e '.gates[] | select(.id == "q1") | .owner == "mate-x"' >/dev/null \
    || fail "a secondmate's queued item must surface as a gate owned by that secondmate: $out"
  printf '%s' "$out" | jq -e '.landed[] | select(.id == "mate-done") | .owner == "mate-x"' >/dev/null \
    || fail "a secondmate's Done must land under that secondmate's owner: $out"
  printf '%s' "$out" | jq -e '[.omitted[] | select(.surface | test("secondmate home state unavailable"))] | length == 1' >/dev/null \
    || fail "an unreadable secondmate home must be disclosed in omitted: $out"
  pass "bearings-snapshot: surfaces each secondmate's authoritative home state, ownership, and unreadable homes"
}

# The default landed baseline is balanced across homes (round-robin over
# deterministic home order), not global newest-first, so a home with the newest
# dates cannot crowd every other home out of a tight overall cap.
test_bearings_landed_round_robin() {
  local main sm out
  main="$TMP/main-rr"; mkdir -p "$main/state" "$main/data"
  : > "$main/data/secondmates.md"
  cat > "$main/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
- [x] main-new1 - main newest - https://github.com/o/r/pull/21 (merged 2026-07-20)
- [x] main-new2 - main second - https://github.com/o/r/pull/22 (merged 2026-07-19)
MD
  sm=$(make_secondmate_home "$TMP/sm-rr" mate-x <<'MD'
## In flight

## Queued

## Done
- [x] mate-old1 - mate newest - https://github.com/o/r/pull/31 (repo: demo) (merged 2026-07-10)
- [x] mate-old2 - mate second - https://github.com/o/r/pull/32 (repo: demo) (merged 2026-07-09)
MD
)
  register_secondmate "$main" mate-x "$sm"
  out=$(run_bearings "$main" "FM_BEARINGS_LANDED=2" "FM_BEARINGS_LANDED_PER_HOME=6" -- --json) || fail "bearings failed: $out"
  # Global newest-first would take both from the main home; round-robin takes one per home.
  printf '%s' "$out" | jq -e '(.landed | length) == 2 and ((.landed | map(.owner) | sort) == ["(main)","mate-x"])' >/dev/null \
    || fail "default landed must be balanced one-per-home, not global newest-first: $(printf '%s' "$out" | jq -c '.landed')"
  pass "bearings-snapshot: default landed baseline is balanced round-robin across homes"
}

test_projection_schema
test_local_only_default
test_landed_rollup
test_bearings_secondmate_surfacing
test_bearings_landed_round_robin
