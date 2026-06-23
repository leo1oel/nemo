#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # PATH/env exported into subshells per case is intentional
# Behavior tests for the persistent-secondmate lifecycle on the herdr backend.
#
# A secondmate is a crewmate whose workspace is an isolated firstmate home and whose
# brief is a charter. On herdr, a secondmate home is a herdr worktree of the firstmate
# repo ($FM_ROOT); herdr never recycles a worktree, so persistence is automatic and
# there is no lease/return bookkeeping. These tests drive the REAL scripts
# (bin/fm-home-seed.sh, fm-spawn.sh, fm-teardown.sh, fm-backlog-handoff.sh) against a
# stub `herdr` on PATH so nothing touches a live herdr server. The stub mirrors the
# real herdr 0.7.0 socket CLI shape used by bin/fm-backend.sh and fm-home-seed.sh:
#   - `worktree create ... --json` -> {result:{worktree:{path,open_workspace_id}}}
#       and actually `git worktree add`s the home so it is a real firstmate home.
#   - `agent start ...`            -> {result:{agent:{pane_id}}}
#   - `worktree remove --workspace <ws> --force` -> records the removed workspace
#   - `workspace create ... --json` / `workspace close <ws>` (plain-dir homes)
# Lifecycle covered: seed a herdr-provisioned home (-), register in data/secondmates.md,
# `validate` rejecting dup ids / dup homes / overlap, spawn (kind=secondmate with
# home=/home_workspace= in meta), backlog handoff of an in-scope item, and explicit
# retirement/teardown via the stubbed `herdr worktree remove`.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$ROOT/bin/fm-home-seed.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HANDOFF="$ROOT/bin/fm-backlog-handoff.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=

# Build a sandbox containing:
#   $SANDBOX/firstmate   a self-contained firstmate repo (git) used as FM_ROOT_OVERRIDE:
#                        the real bin/, a minimal AGENTS.md, and a registered project.
#   $SANDBOX/home        the active (main) firstmate home (FM_HOME): its own data/state.
#   $SANDBOX/bin/herdr   a stub herdr that fakes worktree/agent/workspace ops.
# Echoes the sandbox root.
mk_sandbox() {
  local sb fm home stub
  sb=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate.XXXXXX")
  fm="$sb/firstmate"; home="$sb/home"; stub="$sb/bin"
  mkdir -p "$fm" "$home/data" "$home/state" "$home/config" "$home/projects" "$stub"

  # A self-contained firstmate repo: real bin/ (so the secondmate's clone has the
  # scripts), a minimal AGENTS.md + bin marker so home validation passes, and one
  # registered no-mistakes project with an origin so seeding can clone it.
  cp -R "$ROOT/bin" "$fm/bin"
  printf '# Firstmate\n' > "$fm/AGENTS.md"
  printf 'firstmate repo\n' > "$fm/README.md"
  ( cd "$fm" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )

  # An upstream project the secondmate route can clone from, plus its registry line.
  local proj="$sb/upstream-proj"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q && printf 'x\n' > f && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
  # The active home owns the project clone + registry that fm-project-mode reads.
  # direct-PR (not no-mistakes) so seeding clones the project without invoking the real
  # `no-mistakes init` (which would create persistent gate state outside the sandbox).
  git clone -q "$proj" "$home/projects/widget"
  printf -- '- widget [direct-PR] - widget project (added 2026-01-01)\n' > "$home/data/projects.md"
  printf '## In flight\n\n## Queued\n- [ ] wid-fix-a1 fix the widget (added 2026-01-01)\n- [ ] other-b2 unrelated (added 2026-01-01)\n\n## Done\n' > "$home/data/backlog.md"

  cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
# Minimal herdr stub: just enough of the 0.7.0 socket CLI for the secondmate scripts.
log="${HERDR_STUB_LOG:-/dev/null}"
sub="$1 $2"; shift 2 || true
case "$sub" in
  "worktree create")
    cwd=""; branch=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift 2 ;;
        --branch) branch=$2; shift 2 ;;
        --label|--env) shift 2 ;;
        *) shift ;;
      esac
    done
    n=$(cat "${HERDR_STUB_STATE:-/tmp}/.wt-seq" 2>/dev/null || echo 0); n=$((n+1))
    echo "$n" > "${HERDR_STUB_STATE:-/tmp}/.wt-seq"
    wt="${HERDR_STUB_STATE:-/tmp}/wt-$n"
    # Real worktree of the repo at --cwd so the home is a genuine firstmate home.
    git -C "$cwd" worktree add -q -b "$branch" "$wt" HEAD
    echo "worktree create cwd=$cwd branch=$branch -> $wt ws=ws-$n" >> "$log"
    printf '{"result":{"worktree":{"path":"%s","open_workspace_id":"ws-%s"}}}\n' "$wt" "$n"
    ;;
  "agent start")
    n=$(cat "${HERDR_STUB_STATE:-/tmp}/.pane-seq" 2>/dev/null || echo 0); n=$((n+1))
    echo "$n" > "${HERDR_STUB_STATE:-/tmp}/.pane-seq"
    echo "agent start -> pane-$n" >> "$log"
    printf '{"result":{"agent":{"pane_id":"pane-%s"}}}\n' "$n"
    ;;
  "workspace create")
    n=$(cat "${HERDR_STUB_STATE:-/tmp}/.ws-seq" 2>/dev/null || echo 0); n=$((n+1))
    echo "$n" > "${HERDR_STUB_STATE:-/tmp}/.ws-seq"
    echo "workspace create -> plain-ws-$n" >> "$log"
    printf '{"result":{"workspace":{"workspace_id":"plain-ws-%s"}}}\n' "$n"
    ;;
  "workspace close")
    echo "workspace close $1" >> "$log"
    ;;
  "worktree remove")
    ws=""
    while [ $# -gt 0 ]; do case "$1" in --workspace) ws=$2; shift 2 ;; *) shift ;; esac; done
    echo "worktree remove ws=$ws" >> "${HERDR_STUB_REMOVED:-$log}"
    ;;
  "pane close"|"pane send-text"|"pane send-keys") : ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$stub/herdr"
  printf '%s\n' "$sb"
}

# Run a real fm script with the sandbox env applied. FM_ROOT_OVERRIDE points the script
# at the self-contained firstmate repo; FM_HOME at the active home; PATH carries the stub.
run_fm() {
  local sb=$1; shift
  PATH="$sb/bin:$PATH" \
    FM_ROOT_OVERRIDE="$sb/firstmate" \
    FM_HOME="$sb/home" \
    FM_SPAWN_NO_GUARD=1 \
    HERDR_STUB_STATE="$sb" \
    "$@"
}

reg_line() { grep -E "^- $2( |$)" "$1/home/data/secondmates.md" 2>/dev/null | tail -1; }

# --- seed a herdr-provisioned home, register, and validate ------------------

test_seed_and_register() {
  local sb; sb=$(mk_sandbox); SANDBOX=$sb
  local out
  out=$(FM_SECONDMATE_CHARTER="Own widget reliability" \
        FM_SECONDMATE_SCOPE="widget reliability and incidents" \
        run_fm "$sb" "$SEED" wid-sm-z1 - widget 2>&1) || fail "seed failed: $out"
  local home; home=$(printf '%s\n' "$out" | sed -n 's/^home=//p')
  [ -n "$home" ] || fail "seed printed no home= ($out)"
  [ -d "$home" ] || fail "seed home dir missing: $home"
  [ -f "$home/.fm-secondmate-home" ] || fail "marker not written"
  [ "$(cat "$home/.fm-secondmate-home")" = wid-sm-z1 ] || fail "marker id wrong"
  [ -f "$home/.fm-secondmate-home.workspace" ] || fail "workspace marker not written for - home"
  [ -f "$home/data/charter.md" ] || fail "charter not copied into home"
  [ -d "$home/projects/widget" ] || fail "project not cloned into home"
  local line; line=$(reg_line "$sb" wid-sm-z1)
  [ -n "$line" ] || fail "registry line not written"
  printf '%s\n' "$line" | grep -F 'scope: widget reliability and incidents' >/dev/null || fail "registry scope missing"
  printf '%s\n' "$line" | grep -F 'projects: widget' >/dev/null || fail "registry projects missing"
  rm -rf "$sb"; SANDBOX=
  pass "seed - provisions a herdr home, copies charter, clones project, registers route"
}

# --- validate rejects dup ids, dup homes, and overlapping homes -------------

test_validate_rejects_conflicts() {
  local sb; sb=$(mk_sandbox); SANDBOX=$sb
  local reg="$sb/home/data/secondmates.md"

  # duplicate home (two ids -> same home)
  printf -- '- a-z1 - x (home: %s/h1; scope: s; projects: p; added 2026-01-01)\n' "$sb" > "$reg"
  printf -- '- b-z2 - y (home: %s/h1; scope: s; projects: p; added 2026-01-01)\n' "$sb" >> "$reg"
  run_fm "$sb" "$SEED" validate >/dev/null 2>&1 && fail "validate accepted duplicate homes"

  # duplicate id (same id -> two homes)
  printf -- '- a-z1 - x (home: %s/h1; scope: s; projects: p; added 2026-01-01)\n' "$sb" > "$reg"
  printf -- '- a-z1 - x (home: %s/h2; scope: s; projects: p; added 2026-01-01)\n' "$sb" >> "$reg"
  run_fm "$sb" "$SEED" validate >/dev/null 2>&1 && fail "validate accepted duplicate ids"

  # overlapping (nested) homes
  printf -- '- a-z1 - x (home: %s/h1; scope: s; projects: p; added 2026-01-01)\n' "$sb" > "$reg"
  printf -- '- b-z2 - y (home: %s/h1/nested; scope: s; projects: p; added 2026-01-01)\n' "$sb" >> "$reg"
  run_fm "$sb" "$SEED" validate >/dev/null 2>&1 && fail "validate accepted overlapping homes"

  # a clean registry validates
  printf -- '- a-z1 - x (home: %s/h1; scope: s; projects: p; added 2026-01-01)\n' "$sb" > "$reg"
  printf -- '- b-z2 - y (home: %s/h2; scope: s; projects: p; added 2026-01-01)\n' "$sb" >> "$reg"
  run_fm "$sb" "$SEED" validate >/dev/null 2>&1 || fail "validate rejected a clean registry"

  rm -rf "$sb"; SANDBOX=
  pass "validate rejects duplicate ids, duplicate homes, and overlapping homes"
}

# --- spawn a secondmate: kind=secondmate, home=/home_workspace= in meta -----

test_spawn_secondmate() {
  local sb; sb=$(mk_sandbox); SANDBOX=$sb
  local out
  out=$(FM_SECONDMATE_CHARTER="Own widget reliability" \
        FM_SECONDMATE_SCOPE="widget work" \
        run_fm "$sb" "$SEED" wid-sm-z3 - widget 2>&1) || fail "seed failed: $out"

  out=$(run_fm "$sb" "$SPAWN" wid-sm-z3 --secondmate 2>&1) || fail "spawn failed: $out"
  printf '%s\n' "$out" | grep -F 'kind=secondmate' >/dev/null || fail "spawn did not report kind=secondmate ($out)"
  printf '%s\n' "$out" | grep -F 'mode=secondmate' >/dev/null || fail "spawn did not report mode=secondmate"

  local meta="$sb/home/state/wid-sm-z3.meta"
  [ -f "$meta" ] || fail "no meta written for secondmate"
  grep -q '^kind=secondmate$' "$meta" || fail "meta kind not secondmate"
  grep -q '^mode=secondmate$' "$meta" || fail "meta mode not secondmate"
  grep -q '^yolo=off$' "$meta" || fail "meta yolo not off"
  grep -q '^home=' "$meta" || fail "meta missing home="
  grep -q '^home_workspace=ws-' "$meta" || fail "meta missing home_workspace="
  grep -q '^projects=widget$' "$meta" || fail "meta projects not recorded"
  grep -q '^handle=pane-' "$meta" || fail "meta missing handle="

  rm -rf "$sb"; SANDBOX=
  pass "spawn --secondmate launches in the home and records kind/home/home_workspace/projects"
}

# --- backlog handoff routes an in-scope item into the secondmate home -------

test_backlog_handoff() {
  local sb; sb=$(mk_sandbox); SANDBOX=$sb
  local out home
  out=$(FM_SECONDMATE_CHARTER="Own widget reliability" \
        FM_SECONDMATE_SCOPE="widget work" \
        run_fm "$sb" "$SEED" wid-sm-z4 - widget 2>&1) || fail "seed failed: $out"
  home=$(printf '%s\n' "$out" | sed -n 's/^home=//p')

  out=$(run_fm "$sb" "$HANDOFF" wid-sm-z4 wid-fix-a1 2>&1) || fail "handoff failed: $out"
  # The in-scope item moves into the secondmate home backlog...
  grep -F 'wid-fix-a1' "$home/data/backlog.md" >/dev/null || fail "item not handed off into secondmate backlog"
  # ...and is removed from the main backlog, while the unrelated item stays.
  grep -F 'wid-fix-a1' "$sb/home/data/backlog.md" >/dev/null && fail "item not removed from main backlog"
  grep -F 'other-b2' "$sb/home/data/backlog.md" >/dev/null || fail "unrelated item wrongly removed from main backlog"

  # Idempotent: a second handoff of the same key is a no-op success.
  run_fm "$sb" "$HANDOFF" wid-sm-z4 wid-fix-a1 >/dev/null 2>&1 || fail "second handoff (idempotent) failed"

  rm -rf "$sb"; SANDBOX=
  pass "backlog handoff moves an in-scope item into the secondmate home and is idempotent"
}

# --- teardown: refuse with in-flight child, then retire via herdr worktree remove

test_teardown_retires_home() {
  local sb; sb=$(mk_sandbox); SANDBOX=$sb
  local out home ws meta
  out=$(FM_SECONDMATE_CHARTER="Own widget reliability" \
        FM_SECONDMATE_SCOPE="widget work" \
        run_fm "$sb" "$SEED" wid-sm-z5 - widget 2>&1) || fail "seed failed: $out"
  out=$(run_fm "$sb" "$SPAWN" wid-sm-z5 --secondmate 2>&1) || fail "spawn failed: $out"
  meta="$sb/home/state/wid-sm-z5.meta"
  home=$(grep '^home=' "$meta" | cut -d= -f2-)
  ws=$(grep '^home_workspace=' "$meta" | cut -d= -f2-)

  # In-flight child work in the secondmate home -> plain teardown refuses.
  printf 'kind=ship\nworktree=%s/projects/widget\n' "$home" > "$home/state/child-c9.meta"
  run_fm "$sb" "$TEARDOWN" wid-sm-z5 >/dev/null 2>&1 && fail "teardown did not refuse with in-flight child work"
  rm -f "$home/state/child-c9.meta"

  # Clean retirement removes the herdr worktree (recorded) and clears state + route.
  local removed="$sb/.removed"; : > "$removed"
  HERDR_STUB_REMOVED="$removed" run_fm "$sb" "$TEARDOWN" wid-sm-z5 >/dev/null 2>&1 || fail "clean teardown failed"
  grep -F "ws=$ws" "$removed" >/dev/null || fail "herdr worktree remove not called with the home workspace"
  [ -f "$meta" ] && fail "meta not cleared after retirement"
  reg_line "$sb" wid-sm-z5 | grep -q . && fail "registry route not removed after retirement"

  rm -rf "$sb"; SANDBOX=
  pass "teardown refuses with in-flight child work, then retires via herdr worktree remove and drops the route"
}

test_seed_and_register
test_validate_rejects_conflicts
test_spawn_secondmate
test_backlog_handoff
test_teardown_retires_home
