#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot (bin/fm-fleet-snapshot.sh) and
# its human renderer (bin/fm-fleet-view.sh).
#
# The snapshot is the fork-adapted foundation of bearings: it reads meta with a
# plain grep helper, derives endpoint presence from fm_herdr_pane_exists, and
# tracks open decisions with a last-unresolved-line model (the fork has no
# [key=...] decision markers). This suite proves the JSON schema, backlog
# parsing, a task row's kind/endpoint/current_state, the open-decision hint and
# its lifecycle clearing, and that the view renders the snapshot.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq not found"; exit 0; }

TMP=
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-snapshot.XXXXXX")

# A fixture home with a crafted backlog and no task metas: exercises the
# backend-free path (schema, roots, backlog parsing) against the REAL snapshot.
make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
  cat > "$home/data/backlog.md" <<'MD'
## In flight
- [ ] fix-login-k3 - wire the login guard (repo: yourapp, since 2026-07-10)

## Queued
- [ ] add-tests-q7 - cover the guard (repo: yourapp) blocked-by: fix-login-k3 - waits on the guard

## Done
- [x] old-ship-a1 - earlier change - https://github.com/leo1oel/yourapp/pull/12 (merged 2026-07-09)
MD
  printf '%s\n' "$home"
}

run_snapshot() {  # <home> [ASSIGN...]
  local home=$1; shift
  env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_CONFIG_OVERRIDE=$home/config" "FM_PROJECTS_OVERRIDE=$home/projects" "$@" \
      "$SNAPSHOT" --json 2>&1
}

test_schema_and_backlog() {
  local home out
  home=$(make_home "$TMP/home-a")
  out=$(run_snapshot "$home") || fail "snapshot exited non-zero: $out"
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "snapshot schema wrong: $(printf '%s' "$out" | head -3)"
  # Backlog records preserve section state and metadata.
  printf '%s' "$out" | jq -e '.backlog.records | map(.state) | (index("in_flight") and index("queued") and index("done"))' >/dev/null \
    || fail "backlog sections not all parsed"
  printf '%s' "$out" | jq -e '.backlog.records[] | select(.state=="queued") | .blocked_by == "fix-login-k3"' >/dev/null \
    || fail "queued blocked_by not parsed"
  printf '%s' "$out" | jq -e '.backlog.records[] | select(.state=="done") | .links[0] | test("/pull/12")' >/dev/null \
    || fail "done PR link not parsed"
  pass "fleet-snapshot: schema fm-fleet-snapshot.v1 and In flight/Queued/Done backlog parsing"
}

# A fake bin/ with the REAL snapshot + its libs + a stub fm-crew-state, plus a
# stub herdr on PATH, so a task row's endpoint and current_state are
# deterministic without a live backend.
make_fake_bin() {
  local dir=$1 crew_state=$2 fb
  fb="$dir/bin"; mkdir -p "$fb"
  cp "$SNAPSHOT" "$fb/fm-fleet-snapshot.sh"
  cp "$ROOT/bin/fm-herdr-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-ff-lib.sh" "$fb/"
  chmod +x "$fb/fm-fleet-snapshot.sh"
  cat > "$fb/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$crew_state'
SH
  chmod +x "$fb/fm-crew-state.sh"
  printf '%s\n' "$fb"
}

# stub herdr: `herdr pane get <handle>` exits 0 only for the known live handle.
make_fake_herdr() {
  local dir=$1 live=$2 hb
  hb="$dir/herdrbin"; mkdir -p "$hb"
  cat > "$hb/herdr" <<SH
#!/usr/bin/env bash
if [ "\$1" = pane ] && [ "\$2" = get ] && [ "\$3" = '$live' ]; then exit 0; fi
exit 1
SH
  chmod +x "$hb/herdr"
  printf '%s\n' "$hb"
}

test_task_row_and_open_decision() {
  local home fb hb out
  home="$TMP/home-b"; mkdir -p "$home/state" "$home/data"
  : > "$home/data/backlog.md"
  # A ship task whose pane is live and whose status log ends on an unresolved
  # needs-decision (crew-state is a non-authoritative none read, so the snapshot
  # must NOT clear the open decision).
  printf 'handle=%%7\nkind=ship\nmode=no-mistakes\nproject=%s/proj\n' "$home" > "$home/state/pick-x2.meta"
  printf 'working: started\nneeds-decision: choose A or B\n' > "$home/state/pick-x2.status"
  fb=$(make_fake_bin "$TMP/fake-b" 'state: unknown · source: none · no run')
  hb=$(make_fake_herdr "$TMP/fake-b" '%7')
  out=$(env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
        "FM_CONFIG_OVERRIDE=$home/config" "FM_PROJECTS_OVERRIDE=$home/projects" \
        "PATH=$hb:$PATH" "$fb/fm-fleet-snapshot.sh" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '.tasks | length == 1' >/dev/null || fail "expected one task row: $out"
  printf '%s' "$out" | jq -e '.tasks[0].kind == "ship"' >/dev/null || fail "task kind wrong"
  printf '%s' "$out" | jq -e '.tasks[0].endpoint.exists == true' >/dev/null \
    || fail "endpoint.exists should be true for a live pane"
  printf '%s' "$out" | jq -e '.tasks[0].hints.pending_decision == true' >/dev/null \
    || fail "an unresolved needs-decision must set hints.pending_decision"
  pass "fleet-snapshot: task row records kind, live endpoint, and an unresolved open decision"
}

test_open_decision_cleared_when_resumed() {
  local home fb hb out
  home="$TMP/home-c"; mkdir -p "$home/state" "$home/data"
  : > "$home/data/backlog.md"
  printf 'handle=%%7\nkind=ship\nmode=no-mistakes\n' > "$home/state/pick-x2.meta"
  printf 'needs-decision: choose A or B\n' > "$home/state/pick-x2.status"
  # crew-state now authoritatively working via run-step: the stale needs-decision
  # log line must be cleared (the crew provably resumed past the gate).
  fb=$(make_fake_bin "$TMP/fake-c" 'state: working · source: run-step · fixing')
  hb=$(make_fake_herdr "$TMP/fake-c" '%7')
  out=$(env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
        "FM_CONFIG_OVERRIDE=$home/config" "FM_PROJECTS_OVERRIDE=$home/projects" \
        "PATH=$hb:$PATH" "$fb/fm-fleet-snapshot.sh" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '.tasks[0].hints.pending_decision == false' >/dev/null \
    || fail "a resumed run-step working state must clear the stale needs-decision"
  pass "fleet-snapshot: a provably-resumed task clears its stale open decision"
}

test_fleet_view_renders() {
  local home out
  home=$(make_home "$TMP/home-v")
  out=$(env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
        "FM_CONFIG_OVERRIDE=$home/config" "FM_PROJECTS_OVERRIDE=$home/projects" \
        "$VIEW" 2>&1) || fail "fleet-view failed: $out"
  printf '%s' "$out" | grep -q '# Fleet View' || fail "fleet-view missing title"
  printf '%s' "$out" | grep -q '## Queued' || fail "fleet-view missing Queued section"
  pass "fleet-view: renders the snapshot as a human fleet table"
}

test_schema_and_backlog
test_task_row_and_open_decision
test_open_decision_cleared_when_resumed
test_fleet_view_renders
