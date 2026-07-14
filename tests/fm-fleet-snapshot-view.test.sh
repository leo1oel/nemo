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

# Seed a valid seeded secondmate home (marker, firstmate-home markers, bin/, and a
# backlog read from stdin). Callers add state metas afterwards for a live child.
make_secondmate_home() {  # <home> <id>  (backlog on stdin)
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/data" "$home/bin"
  printf '%s' "$id" > "$home/.fm-secondmate-home"
  printf '# secondmate home\n' > "$home/AGENTS.md"
  cat > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# Register a secondmate in the MAIN home's state meta + registry table.
register_secondmate() {  # <main-home> <id> <home-path>
  local main=$1 id=$2 home=$3
  printf 'kind=secondmate\nhome=%s\nhandle=fmpane-%s\n' "$home" "$id" > "$main/state/$id.meta"
  printf -- '- %s - scope (home: %s; scope: work; projects: demo; added 2026-07-14)\n' "$id" "$home" >> "$main/data/secondmates.md"
}

# --secondmate-home-summary projects one home's own authoritative state (bounded),
# with a validity verdict and a derived state - no nested recursion, no crew backend
# needed when the home carries only backlog.
test_secondmate_home_summary_mode() {
  local sm out
  sm=$(make_secondmate_home "$TMP/sm-summary" mate-s <<'MD'
## In flight
## Queued
- [ ] q1 - queued feature (repo: demo) blocked-by: dep7 - waits on dep7
## Done
- [x] mate-done - a merge the mate managed - https://github.com/o/r/pull/9 (repo: demo) (merged 2026-07-12)
MD
)
  out=$(env "FM_HOME=$sm" "FM_STATE_OVERRIDE=$sm/state" "FM_DATA_OVERRIDE=$sm/data" \
        "FM_CONFIG_OVERRIDE=$sm/config" "FM_PROJECTS_OVERRIDE=$sm/projects" \
        "$SNAPSHOT" --secondmate-home-summary 2>&1) || fail "summary mode failed: $out"
  printf '%s' "$out" | jq -e '.schema == "fm-secondmate-home-summary.v1"' >/dev/null \
    || fail "summary schema wrong: $out"
  printf '%s' "$out" | jq -e '.valid == true and .state == "externally_held"' >/dev/null \
    || fail "an idle home with a blocked-queued item must be a valid externally_held: $out"
  printf '%s' "$out" | jq -e '(.holds | length) == 1 and .holds[0].id == "q1" and (.landed | length) == 1 and .landed[0].id == "mate-done"' >/dev/null \
    || fail "summary holds/landed wrong: $out"
  printf '%s' "$out" | jq -e '.counts.landed == 1 and .counts.queued == 1' >/dev/null \
    || fail "summary counts wrong: $out"
  pass "fleet-snapshot: --secondmate-home-summary projects a valid bounded home state"
}

# A structured in-flight backlog item with no child metadata is an inconsistency
# the parent must not trust: the summary is invalid and the state unknown.
test_secondmate_home_summary_invalid() {
  local sm out
  sm=$(make_secondmate_home "$TMP/sm-invalid" mate-i <<'MD'
## In flight
- [ ] ghost-task - a task with no child metadata (repo: demo, since 2026-07-14)
## Queued
## Done
MD
)
  out=$(env "FM_HOME=$sm" "FM_STATE_OVERRIDE=$sm/state" "FM_DATA_OVERRIDE=$sm/data" \
        "FM_CONFIG_OVERRIDE=$sm/config" "FM_PROJECTS_OVERRIDE=$sm/projects" \
        "$SNAPSHOT" --secondmate-home-summary 2>&1) || fail "summary mode failed: $out"
  printf '%s' "$out" | jq -e '.valid == false and .state == "unknown" and (.reason | test("no child metadata"))' >/dev/null \
    || fail "an in-flight item with no child metadata must invalidate the summary: $out"
  pass "fleet-snapshot: --secondmate-home-summary marks an inconsistent home unknown with a reason"
}

# The parent recursively derives each registered secondmate's authoritative state
# from its own home; an unreadable home is demoted to unknown, never trusted.
test_secondmate_current_recursion() {
  local main sm out
  main="$TMP/main-rec"; mkdir -p "$main/state" "$main/data"
  printf '## In flight\n## Queued\n## Done\n' > "$main/data/backlog.md"
  : > "$main/data/secondmates.md"
  sm=$(make_secondmate_home "$TMP/sm-rec" mate-v <<'MD'
## In flight
## Queued
- [ ] q1 - queued feature (repo: demo) blocked-by: dep7 - waits
## Done
- [x] mate-done - a merge - https://github.com/o/r/pull/9 (repo: demo) (merged 2026-07-12)
MD
)
  register_secondmate "$main" mate-v "$sm"
  register_secondmate "$main" mate-bad "$TMP/no-such-home"
  out=$(env "FM_HOME=$main" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$main/state" "FM_DATA_OVERRIDE=$main/data" \
        "FM_CONFIG_OVERRIDE=$main/config" "FM_PROJECTS_OVERRIDE=$main/projects" \
        "$SNAPSHOT" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '.secondmate_current.total_registered == 2 and .secondmate_current.truncated == 0' >/dev/null \
    || fail "both registered secondmates must be counted: $out"
  printf '%s' "$out" | jq -e '.secondmate_current.records[] | select(.id == "mate-v") | .valid == true and .current.state == "externally_held" and (.landed[0].id == "mate-done")' >/dev/null \
    || fail "a valid secondmate must contribute its authoritative home state: $out"
  printf '%s' "$out" | jq -e '.secondmate_current.records[] | select(.id == "mate-bad") | .current.state == "unknown" and (.current.reason | test("invalid home"))' >/dev/null \
    || fail "an unreadable secondmate home must be demoted to unknown: $out"
  pass "fleet-snapshot: secondmate_current recursively derives each home's authoritative state"
}

# A live working child inside a secondmate home surfaces as active_child_work. The
# recursion re-runs the same snapshot, so the fake-bin stub crew-state drives the
# child's state deterministically without a real backend.
test_secondmate_current_active_child() {
  local main sm fb hb out
  main="$TMP/main-act"; mkdir -p "$main/state" "$main/data"
  printf '## In flight\n## Queued\n## Done\n' > "$main/data/backlog.md"
  : > "$main/data/secondmates.md"
  sm=$(make_secondmate_home "$TMP/sm-act" mate-w <<'MD'
## In flight
- [ ] task-a - do the thing (repo: demo, since 2026-07-14)
## Queued
## Done
MD
)
  printf 'handle=%%9\nkind=ship\nproject=%s/proj\nworktree=%s/wt\n' "$sm" "$sm" > "$sm/state/task-a.meta"
  printf 'working: started\n' > "$sm/state/task-a.status"
  register_secondmate "$main" mate-w "$sm"
  fb=$(make_fake_bin "$TMP/fake-act" 'state: working · source: run-step · building')
  hb=$(make_fake_herdr "$TMP/fake-act" '%9')
  out=$(env "FM_HOME=$main" "FM_ROOT_OVERRIDE=$TMP/fake-act" "FM_STATE_OVERRIDE=$main/state" "FM_DATA_OVERRIDE=$main/data" \
        "FM_CONFIG_OVERRIDE=$main/config" "FM_PROJECTS_OVERRIDE=$main/projects" \
        "PATH=$hb:$PATH" "$fb/fm-fleet-snapshot.sh" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '.secondmate_current.records[] | select(.id == "mate-w") | .valid == true and .current.state == "active_child_work" and (.active_children[0].id == "task-a")' >/dev/null \
    || fail "a live working child must surface as active_child_work: $out"
  pass "fleet-snapshot: secondmate_current reflects a live working child as active_child_work"
}

# The count bound reads only that many homes (disclosing the rest as truncated), and
# a per-home summary over the byte bound is demoted to unknown rather than trusted.
test_secondmate_current_bounds() {
  local main sm1 sm2 out
  main="$TMP/main-bound"; mkdir -p "$main/state" "$main/data"
  printf '## In flight\n## Queued\n## Done\n' > "$main/data/backlog.md"
  : > "$main/data/secondmates.md"
  sm1=$(make_secondmate_home "$TMP/sm-b1" mate-1 <<'MD'
## In flight
## Queued
## Done
MD
)
  sm2=$(make_secondmate_home "$TMP/sm-b2" mate-2 <<'MD'
## In flight
## Queued
## Done
MD
)
  register_secondmate "$main" mate-1 "$sm1"
  register_secondmate "$main" mate-2 "$sm2"
  out=$(env "FM_HOME=$main" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$main/state" "FM_DATA_OVERRIDE=$main/data" \
        "FM_CONFIG_OVERRIDE=$main/config" "FM_PROJECTS_OVERRIDE=$main/projects" \
        "FM_SNAPSHOT_SECONDMATES=1" "$SNAPSHOT" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '.secondmate_current.total_registered == 2 and .secondmate_current.truncated == 1 and (.secondmate_current.records | length == 1)' >/dev/null \
    || fail "FM_SNAPSHOT_SECONDMATES=1 must read one home and disclose one truncated: $out"
  out=$(env "FM_HOME=$main" "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$main/state" "FM_DATA_OVERRIDE=$main/data" \
        "FM_CONFIG_OVERRIDE=$main/config" "FM_PROJECTS_OVERRIDE=$main/projects" \
        "FM_SNAPSHOT_SECONDMATE_MAX_BYTES=1" "$SNAPSHOT" --json 2>&1) || fail "snapshot failed: $out"
  printf '%s' "$out" | jq -e '[.secondmate_current.records[] | select(.current.state == "unknown" and (.current.reason | test("byte limit")))] | length == 2' >/dev/null \
    || fail "a home summary over the byte bound must be demoted to unknown: $out"
  pass "fleet-snapshot: secondmate_current honors the count bound and the per-home byte bound"
}

test_snapshot_rejects_bad_bound() {
  local home out rc
  home=$(make_home "$TMP/home-bb")
  out=$(env "FM_HOME=$home" "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
        "FM_SNAPSHOT_SECONDMATES=-3" "$SNAPSHOT" --json 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a negative FM_SNAPSHOT_SECONDMATES must exit 2 (got $rc): $out"
  printf '%s' "$out" | grep -q 'must be a non-negative integer' || fail "a bad bound must explain itself: $out"
  pass "fleet-snapshot: rejects a malformed cross-home bound"
}

test_schema_and_backlog
test_task_row_and_open_decision
test_open_decision_cleared_when_resumed
test_fleet_view_renders
test_secondmate_home_summary_mode
test_secondmate_home_summary_invalid
test_secondmate_current_recursion
test_secondmate_current_active_child
test_secondmate_current_bounds
test_snapshot_rejects_bad_bound
