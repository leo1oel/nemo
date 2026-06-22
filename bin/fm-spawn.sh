#!/usr/bin/env bash
# Spawn a crewmate: tmux window -> treehouse worktree subshell -> agent launched with its brief.
# Usage: fm-spawn.sh <task-id> <project-dir> [launch-command] [--scout]
#   This fork is Claude-only: with no third arg the crewmate runs Claude Code. A non-flag
#   string containing whitespace is treated as a RAW launch command (escape hatch).
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md section 7); the default is kind=ship.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-task shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   The launch template lives in launch_template() below; the only placeholder is:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
# The Claude turn-end hook (a Stop hook in the worktree's .claude/settings.local.json) is
# installed automatically.
# On success prints: spawned <id> harness=<name> kind=<ship|scout> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md via fm-project-mode.sh.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
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
    if [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "${pair%%=*}" "${pair#*=}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=${POS[1]}
ARG3=${POS[2]:-}

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in AGENTS.md section 4.
launch_template() {
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$1" in
    claude) printf '%s' 'claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
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
    HARNESS=$("$FM_ROOT/bin/fm-harness.sh" crew)
    LAUNCH=$(launch_template "$HARNESS") || { echo "error: no launch template for harness '$HARNESS' (from config/crew-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

BRIEF="$FM_ROOT/data/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }
PROJ_ABS="$(cd "$PROJ" && pwd)"

# Crewmate terminal backend, chosen by FM_BACKEND (default tmux):
#   herdr - each crewmate is a herdr agent pane in its own worktree workspace
#   tmux  - legacy path: a tmux window running a treehouse worktree subshell
# Either way this block leaves $WT pointing at the task's worktree, so the
# turn-end hooks below can be written into it before the agent launches.
FM_BACKEND=${FM_BACKEND:-tmux}
BACKEND="$FM_ROOT/bin/fm-backend.sh"
T=""; WS=""; RP=""

if [ "$FM_BACKEND" = herdr ]; then
  OPENED=$(FM_BACKEND=herdr "$BACKEND" open "$ID" "$PROJ_ABS") \
    || { echo "error: 'fm-backend open' failed for $ID" >&2; exit 1; }
  WT=$(printf '%s\n' "$OPENED" | sed -n 's/^worktree=//p')
  WS=$(printf '%s\n' "$OPENED" | sed -n 's/^workspace=//p')
  RP=$(printf '%s\n' "$OPENED" | sed -n 's/^rootpane=//p')
  [ -n "$WT" ] && [ -n "$WS" ] || { echo "error: 'fm-backend open' returned no worktree/workspace" >&2; exit 1; }
else
  # Same session when firstmate already runs inside tmux; dedicated session otherwise.
  if [ -n "${TMUX:-}" ]; then
    SES=$(tmux display-message -p '#S')
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    SES=firstmate
  fi

  W="fm-$ID"
  T="$SES:$W"
  if tmux list-windows -t "$SES" -F '#{window_name}' | grep -qx "$W"; then
    echo "error: window $T already exists" >&2
    exit 1
  fi

  tmux new-window -d -t "$SES" -n "$W" -c "$PROJ_ABS"
  tmux send-keys -t "$T" 'treehouse get' Enter

  # Wait for the treehouse subshell: the pane's cwd moves from the project to the worktree.
  WT=""
  for _ in $(seq 1 60); do
    p=$(tmux display-message -p -t "$T" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$p" ] && [ "$p" != "$PROJ_ABS" ]; then
      WT="$p"
      break
    fi
    sleep 1
  done
  if [ -z "$WT" ]; then
    echo "error: treehouse get did not enter a worktree within 60s; inspect window $T" >&2
    exit 1
  fi
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$FM_ROOT/state/$ID.turn-ended"
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

# Start the crewmate. HANDLE is the backend-neutral target peek/send/teardown use:
# the herdr agent pane id, or the tmux session:window.
HANDLE=""
if [ "$FM_BACKEND" = herdr ]; then
  LAUNCHED=$(FM_BACKEND=herdr "$BACKEND" launch "$ID" "$WS" "$WT" "$LAUNCH" "$RP") \
    || { echo "error: 'fm-backend launch' failed for $ID" >&2; exit 1; }
  HANDLE=$(printf '%s\n' "$LAUNCHED" | sed -n 's/^handle=//p')
  [ -n "$HANDLE" ] || { echo "error: 'fm-backend launch' returned no handle" >&2; exit 1; }
else
  tmux send-keys -t "$T" -l "$LAUNCH"
  sleep 0.3
  tmux send-keys -t "$T" Enter
  HANDLE="$T"
fi

mkdir -p "$FM_ROOT/state"
{
  echo "backend=$FM_BACKEND"
  echo "handle=$HANDLE"
  if [ "$FM_BACKEND" = herdr ]; then
    echo "workspace=$WS"
  else
    echo "window=$T"   # back-compat alias still read by the tmux path of peek/send/teardown
  fi
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} > "$FM_ROOT/state/$ID.meta"

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO backend=$FM_BACKEND handle=$HANDLE worktree=$WT"
