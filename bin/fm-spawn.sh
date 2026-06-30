#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a herdr worktree workspace, or a persistent
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> [launch-command] [--scout]
#        fm-spawn.sh <task-id> [<firstmate-home>] [launch-command] --secondmate
#   This fork is Claude-only: with no launch arg the agent runs Claude Code. A non-flag
#   string containing whitespace is treated as a RAW launch command (escape hatch).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7). --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home (a herdr worktree of $FM_ROOT seeded by fm-home-seed.sh);
#   the default is kind=ship.
#   Before a secondmate launch, the home is locally fast-forwarded to the primary
#   default-branch commit when safe (no fetch); skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch after the worktree is opened unless the resolved
#   path is a real git worktree root distinct from the project's primary checkout
#   (prevents the firstmate-on-itself worktree tangle; see fm-tangle-lib.sh).
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   The launch template lives in launch_template() below; the only placeholder is:
#     __BRIEF__    absolute path to data/<task-id>/brief.md (or the home's data/charter.md
#                  for a secondmate)
# The Claude turn-end hook (a Stop hook in the worktree's .claude/settings.local.json) is
# installed automatically for crewmate tasks; secondmates run their own watcher in their
# home and are supervised through status writes, not pane-idle staleness, so they get none.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> mode=<mode> yolo=<on|off> handle=<pane> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tasks; a secondmate
# spawn records mode=secondmate, yolo=off, home=, home_workspace=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# Operational dirs come from the active home so a secondmate (its own FM_HOME) spawns its
# own crewmates against its own state/data/projects. bin/ still resolves from the repo.
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SUB_HOME_MARKER=".fm-secondmate-home"
SUB_HOME_WS_MARKER=".fm-secondmate-home.workspace"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"   # primary_head_commit + ff_target for the secondmate local-HEAD sync
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    *) POS+=("$a") ;;
  esac
done

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-task mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-task invocations never carry an '=' in arg
# one (task ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = secondmate ]; then
      echo "error: batch dispatch does not support --secondmate; spawn each secondmate explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-spawn.sh <task-id> <project-dir> [launch-command] [--scout]   (or several id=repo pairs, or <task-id> [<firstmate-home>] --secondmate)" >&2; exit 2; }
ID=${POS[0]}
PROJ=
ARG3=
FIRSTMATE_HOME=

if [ "$KIND" = secondmate ]; then
  # <id> [<home>] [launch] --secondmate. The home arg is optional: when absent it is
  # resolved from the recorded meta (recovery) or the data/secondmates.md registry. A
  # bare launch adapter name or a whitespace raw launch command is distinguished from a
  # home path the same way upstream does.
  case "${POS[1]:-}" in
    ''|claude)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        FIRSTMATE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      FIRSTMATE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  [ "${#POS[@]}" -ge 2 ] || { echo "usage: fm-spawn.sh <task-id> <project-dir> [launch-command] [--scout]   (or several id=repo pairs)" >&2; exit 2; }
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$1" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate reads the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-herdr-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    HARNESS=claude   # this fork is Claude-only
    LAUNCH=$(launch_template "$HARNESS")
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

# Root/sudo sandbox: forward IS_SANDBOX into the crewmate launch. claude refuses
# --dangerously-skip-permissions when running as root for security UNLESS IS_SANDBOX marks
# the environment as a sandbox - and herdr starts agent panes with a sanitized environment
# that DROPS IS_SANDBOX, so without this a crewmate's root claude refuses to launch and its
# pane dies within ~2s, collapsing the spawn before any brief is read. Done ONLY when this
# firstmate is actually running as root: a normal non-root host (a laptop, most servers)
# never needs it and must not falsely claim to be sandboxed, so there the launch stays
# exactly as before. Applied once here, so it covers ship, scout, and secondmate launches
# alike. Default to 1 when unset so a fresh root container works with no other setup; honor
# an already-set IS_SANDBOX, and validate it to a safe token set so the inline shell
# assignment can never be malformed.
case "$HARNESS" in
  claude*)
    if [ "$(id -u 2>/dev/null || echo)" = 0 ]; then
      FM_SANDBOX_VAL=${IS_SANDBOX:-1}
      case "$FM_SANDBOX_VAL" in
        ''|*[!A-Za-z0-9_.:/-]*) FM_SANDBOX_VAL=1 ;;
      esac
      LAUNCH="IS_SANDBOX=$FM_SANDBOX_VAL $LAUNCH"
    fi
    ;;
esac

# Per-task temp root: /tmp/fm-<id>/ with Go's build temp nested at gotmp/. Go's
# GOTMPDIR is unset by default, so every go build/test creates numbered
# /tmp/go-build* dirs that Go LEAVES BEHIND when interrupted (signal, timeout, OOM,
# full disk), accumulating until the disk fills. Give each task its own GOTMPDIR so
# fm-teardown can remove the whole root deterministically. Go won't create GOTMPDIR
# itself, so mkdir it here. Nested (not a bare /tmp/fm-<id>/gotmp) so other per-task
# temp can live alongside later. GOTMPDIR (not TMPDIR) is the targeted knob: TMPDIR
# is too broad (affects every program's temp, not just Go's). Prepended to LAUNCH as
# an env prefix - the same delivery the IS_SANDBOX/FM_HOME prefixes use - so the
# agent and every child process (go build, go test, ...) inherit it; this covers
# ship, scout, and secondmate launches alike. Recorded as tasktmp= in meta below.
TASK_TMP="/tmp/fm-$ID"
mkdir -p "$TASK_TMP/gotmp"
LAUNCH="GOTMPDIR=$TASK_TMP/gotmp $LAUNCH"

# claude_pretrust <dir>: seed claude's per-directory folder-trust for <dir> so its
# first-launch trust dialog ("Is this a project you created or one you trust?") never
# appears. That dialog blocks on stdin; in a freshly created worktree/home the crewmate
# pane can reach end-of-input on the prompt and claude exits before firstmate peeks and
# accepts it (the harness-adapters skill), collapsing the spawn. claude records trust per project
# directory in ~/.claude.json (projects.<abs-path>.hasTrustDialogAccepted), so add that
# entry for <dir> before launch. The existing file is preserved (read-modify-write of one
# entry) and replaced atomically; an flock serializes concurrent writers so neither write is
# torn - flock is absent on macOS, where the atomic os.replace alone still prevents a torn
# file. Best-effort and non-fatal: on any failure the spawn proceeds and the dialog can
# still be accepted by hand. claude only.
claude_pretrust() {
  local dir=$1 cfg
  [ -n "$dir" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  cfg="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
  cfg="${cfg:-$HOME/.claude.json}"
  (
    flock 9 2>/dev/null || true
    python3 - "$cfg" "$dir" <<'PY' || true
import json, os, sys, tempfile
cfg, d = sys.argv[1], os.path.abspath(sys.argv[2])
try:
    with open(cfg) as f:
        data = json.load(f)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
projects = data.setdefault("projects", {})
entry = projects.get(d)
if not isinstance(entry, dict):
    entry = {}
entry.setdefault("allowedTools", [])
entry["hasTrustDialogAccepted"] = True
entry["hasCompletedProjectOnboarding"] = True
projects[d] = entry
dirn = os.path.dirname(os.path.abspath(cfg)) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".claude.json.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, cfg)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
PY
  ) 9>"${cfg}.fm-trust.lock" 2>/dev/null || true
}

BACKEND="$FM_ROOT/bin/fm-backend.sh"

# Shared herdr json helper (mirrors bin/fm-backend.sh _jget).
_jget() {
  python3 -c '
import sys, json
path = [p for p in sys.argv[1].split(".") if p != ""]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in path:
    if isinstance(d, list):
        try: d = d[int(k)]
        except (ValueError, IndexError): d = None
    elif isinstance(d, dict):
        d = d.get(k)
    else:
        d = None
    if d is None:
        break
sys.stdout.write("" if d is None else str(d))
' "$1"
}

# Read a field off a secondmate's data/secondmates.md registry line.
secondmate_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_firstmate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_firstmate_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_firstmate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

if [ "$KIND" = secondmate ]; then
  # Resolve the home: explicit arg, recorded meta (recovery), or the registry.
  if [ -z "$FIRSTMATE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    FIRSTMATE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$FIRSTMATE_HOME" ]; then
    FIRSTMATE_HOME=$(secondmate_registry_value "$ID" home || true)
  fi
  [ -n "$FIRSTMATE_HOME" ] || { echo "error: no firstmate home supplied or registered for $ID" >&2; exit 1; }
  HOME_PATH=$(validate_firstmate_home_for_spawn "$ID" "$FIRSTMATE_HOME") || exit 1
  # The home's workspace, if it was provisioned by herdr (the `-` seed path). Recorded
  # beside the marker; a plain directory home has none, so spawn opens one on the fly.
  HOME_WORKSPACE=$(cat "$HOME_PATH/$SUB_HOME_WS_MARKER" 2>/dev/null || true)
  WT="$HOME_PATH"
  # Local-HEAD sync: before launch, fast-forward this secondmate's home worktree to
  # the PRIMARY checkout's current default-branch commit, so a freshly spawned or
  # recovery-respawned secondmate always runs the primary's version (AGENTS.md spawn
  # section). Purely local - no fetch: the home is a herdr worktree of this same repo
  # on lease branch secondmate-<id> and already holds the commit in the shared object
  # store. ff-only and guarded; a dirty, diverged, or wrong-branch home is left
  # untouched and launches as-is. The agent re-reads AGENTS.md fresh on launch, so no
  # nudge is needed here.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    sm_ff_out=$(ff_target "$HOME_PATH" "secondmate $ID" "$sm_primary_head" "secondmate-$ID" yes yes 2>&1 || true)
    case "$sm_ff_out" in
      *': skipped:'*)
        sm_ff_line=$(first_line "$sm_ff_out")
        sm_ff_reason=${sm_ff_line#"secondmate $ID: skipped: "}
        echo "warning: secondmate $ID sync skipped before launch: $sm_ff_reason" >&2
        ;;
    esac
  else
    echo "warning: secondmate $ID sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  if [ -f "$HOME_PATH/data/charter.md" ]; then
    BRIEF="$HOME_PATH/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
  [ -f "$BRIEF" ] || { echo "error: no charter/brief at $BRIEF" >&2; exit 1; }

  # A secondmate is launched in its home: reuse the home's herdr workspace when it was
  # herdr-provisioned, else open a fresh workspace rooted at the home directory. No
  # worktree create (the home IS the workspace), no turn-end hook (the secondmate runs
  # its own watcher and is supervised through status writes), no fleet sync.
  if [ -n "$HOME_WORKSPACE" ]; then
    WS=$HOME_WORKSPACE
  else
    WSJSON=$(herdr workspace create --cwd "$HOME_PATH" --label "sm-$ID" --no-focus --json 2>/dev/null) \
      || { echo "error: 'herdr workspace create' failed for secondmate $ID home $HOME_PATH" >&2; exit 1; }
    WS=$(printf '%s' "$WSJSON" | _jget result.workspace.workspace_id)
    [ -n "$WS" ] || WS=$(printf '%s' "$WSJSON" | _jget result.workspace_id)
    [ -n "$WS" ] || { echo "error: could not parse 'herdr workspace create' output (workspace id missing)" >&2; printf '%s\n' "$WSJSON" >&2; exit 1; }
  fi

  MODE=secondmate
  YOLO=off
  SECONDMATE_PROJECTS=$(secondmate_registry_value "$ID" projects || true)

  # The secondmate runs as a firstmate in its own home: point its operational env at the
  # home so its own fm-* calls resolve there, and use the same launch-template path.
  BRIEF_Q=$(shell_quote "$BRIEF")
  HOME_Q=$(shell_quote "$HOME_PATH")
  LAUNCH=${LAUNCH//__BRIEF__/$BRIEF_Q}
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_HOME=$HOME_Q $LAUNCH"

  # Pre-trust the home so claude's first-launch folder-trust dialog never collapses the spawn.
  case "$HARNESS" in claude*) claude_pretrust "$HOME_PATH" ;; esac

  LAUNCHED=$("$BACKEND" launch "$ID" "$WS" "$HOME_PATH" "$LAUNCH") \
    || { echo "error: 'fm-backend launch' failed for secondmate $ID" >&2; exit 1; }
  HANDLE=$(printf '%s\n' "$LAUNCHED" | sed -n 's/^handle=//p')
  [ -n "$HANDLE" ] || { echo "error: 'fm-backend launch' returned no handle" >&2; exit 1; }

  mkdir -p "$STATE"
  {
    echo "handle=$HANDLE"
    echo "workspace=$WS"
    echo "worktree=$HOME_PATH"
    echo "project=$HOME_PATH"
    echo "harness=$HARNESS"
    echo "kind=$KIND"
    echo "mode=$MODE"
    echo "yolo=$YOLO"
    echo "tasktmp=$TASK_TMP"
    echo "home=$HOME_PATH"
    echo "home_workspace=$WS"
    echo "projects=$SECONDMATE_PROJECTS"
  } > "$STATE/$ID.meta"

  echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO handle=$HANDLE worktree=$HOME_PATH"
  exit 0
fi

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
case "$PROJ" in
  projects/*) PROJ_ABS="$(cd "$PROJECTS/${PROJ#projects/}" && pwd)" ;;
  *) PROJ_ABS="$(cd "$PROJ" && pwd)" ;;
esac

# Refresh this project's clone so the crewmate branches off current code (this replaces the
# session-start fleet refresh the old bootstrap did). Best-effort and non-fatal.
"$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ_ABS" >/dev/null 2>&1 || true

# Create the crewmate's worktree (a herdr worktree workspace) before the turn-end hook
# below is written into it. $WT is the worktree path, $WS its herdr workspace id, $RP the
# spare root pane the launch step will replace.
OPENED=$("$BACKEND" open "$ID" "$PROJ_ABS") \
  || { echo "error: 'fm-backend open' failed for $ID" >&2; exit 1; }
WT=$(printf '%s\n' "$OPENED" | sed -n 's/^worktree=//p')
WS=$(printf '%s\n' "$OPENED" | sed -n 's/^workspace=//p')
RP=$(printf '%s\n' "$OPENED" | sed -n 's/^rootpane=//p')
[ -n "$WT" ] && [ -n "$WS" ] || { echo "error: 'fm-backend open' returned no worktree/workspace" >&2; exit 1; }

# Isolation guard: refuse to launch unless WT is a genuine, ISOLATED worktree -
# a real git worktree root, distinct from the project's primary checkout
# (PROJ_ABS). Firstmate is a git repo of itself with linked worktrees, so a
# worktree-open misfire could leave the pane in (or in a subdir of, or a symlink
# to) the primary checkout; branching/committing there would tangle the primary
# onto a feature branch (see fm-tangle-lib.sh). This proves the pane landed in a
# true, separate worktree root before any branch/commit can happen.
wt_real=
if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then
  wt_real=
fi
proj_real=
if ! proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P); then
  proj_real=
fi
wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
wt_top_real=
if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then
  wt_top_real=
fi
if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
  echo "error: 'fm-backend open' did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout." >&2
  "$BACKEND" kill "" "$WS" >/dev/null 2>&1 || true
  exit 1
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
case "$HARNESS" in
  claude*)
    mkdir -p "$WT/.claude"
    cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
    exclude_path '.claude/settings.local.json'
    ;;
esac

# Per-project delivery mode + yolo flag (bin/fm-project-mode.sh; AGENTS.md sections 6-7).
# Recorded in meta so fm-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tasks; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
PROJ_NAME=$(basename "$PROJ_ABS")
read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF

LAUNCH=${LAUNCH//__BRIEF__/$BRIEF}

# Pre-trust the worktree so claude's first-launch folder-trust dialog never collapses the spawn.
case "$HARNESS" in claude*) claude_pretrust "$WT" ;; esac

# Start the crewmate in its worktree pane. HANDLE (the herdr pane id) is what
# peek/send/teardown use to reach it.
LAUNCHED=$("$BACKEND" launch "$ID" "$WS" "$WT" "$LAUNCH" "$RP") \
  || { echo "error: 'fm-backend launch' failed for $ID" >&2; exit 1; }
HANDLE=$(printf '%s\n' "$LAUNCHED" | sed -n 's/^handle=//p')
[ -n "$HANDLE" ] || { echo "error: 'fm-backend launch' returned no handle" >&2; exit 1; }

mkdir -p "$STATE"
{
  echo "handle=$HANDLE"
  echo "workspace=$WS"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASK_TMP"
} > "$STATE/$ID.meta"

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO handle=$HANDLE worktree=$WT"
