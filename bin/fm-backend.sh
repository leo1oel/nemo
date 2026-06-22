#!/usr/bin/env bash
# Crewmate terminal backend abstraction.
#
# The fm-* scripts call this for all crewmate terminal operations instead of naming herdr
# directly, so the multiplexer stays behind one seam.
#
# Subcommands (the contract every backend implements):
#   open     <id> <project-dir>                creates the per-task worktree (and its
#                                              workspace) but does NOT launch the agent, so
#                                              the caller can write turn-end hooks into the
#                                              worktree first. Prints, one per line:
#                                                worktree=<absolute worktree path>
#                                                workspace=<backend workspace id, may be empty>
#                                                rootpane=<spare pane to pass to launch, may be empty>
#   launch   <id> <workspace> <worktree> <launch-cmd> [rootpane]
#                                              starts the crewmate in the opened worktree and
#                                              prints: handle=<opaque terminal handle>
#   spawn    <id> <project-dir> <launch-cmd>   open + launch in one shot (no hooks). Prints:
#                                                worktree=, workspace=, rootpane=, handle=
#   read     <handle> [lines]                  prints the tail of the crewmate's screen
#   send     <handle> <text...>                sends literal text, then Enter
#   send-key <handle> <key>                    sends a single key (Escape|Enter|C-c|...)
#   state    <handle>                          prints idle|working|blocked|done|unknown
#   list                                       prints one fm-<id> task handle per line
#   kill     <handle> [workspace]              removes the worktree and closes its
#                                              herdr workspace + pane (killing the agent)
#
# <launch-cmd> is a shell command string (e.g. 'claude ... "$(cat brief.md)"'); launch runs
# it via `bash -lc`, so command substitutions expand in that shell, not here.
#
# Verified against herdr 0.7.0 (socket CLI).
set -eu

# Extract a dotted path from JSON on stdin. Missing -> empty string, never an error.
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

############################
# herdr backend
############################

# Common key names -> herdr key names (herdr accepts enter/tab/esc/ctrl+<x>/arrows).
_herdr_key() {
  case "$1" in
    Escape|Esc|escape|esc) echo esc ;;
    Enter|enter|Return)     echo enter ;;
    Tab|tab)                echo tab ;;
    C-c|c-c|ctrl-c)         echo ctrl+c ;;
    C-d|c-d|ctrl-d)         echo ctrl+d ;;
    *)                      echo "$1" ;;
  esac
}

# open creates the per-task worktree (and its herdr workspace + a spare shell pane) but does
# NOT launch the agent yet, so the caller can write turn-end hooks into the worktree first.
herdr_open() {
  local id=$1 proj=$2 proj_abs j wt ws rp
  proj_abs=$(cd "$proj" && pwd) || { echo "fm-backend: no such project dir: $proj" >&2; return 1; }
  j=$(herdr worktree create --cwd "$proj_abs" --branch "fm-$id" --label "fm-$id" --no-focus --json) \
    || { echo "fm-backend: 'herdr worktree create' failed for fm-$id" >&2; return 1; }
  wt=$(printf '%s' "$j" | _jget result.worktree.path)
  ws=$(printf '%s' "$j" | _jget result.worktree.open_workspace_id)
  rp=$(printf '%s' "$j" | _jget result.root_pane.pane_id)
  if [ -z "$wt" ] || [ -z "$ws" ]; then
    echo "fm-backend: could not parse 'herdr worktree create' output (path/workspace missing)" >&2
    printf '%s\n' "$j" >&2
    return 1
  fi
  echo "worktree=$wt"
  echo "workspace=$ws"
  echo "rootpane=$rp"
}

# launch starts the crewmate as a named pane that execs `bash -lc <launch>`. Running through
# bash (not the crewmate's interactive shell) means launch templates using $(...) work whether
# the login shell is fish, zsh, or bash. The agent is named fm-<id> for the herdr sidebar. If a
# spare root pane id is given (from open), it is closed so the crewmate keeps one pane.
herdr_launch() {
  local id=$1 ws=$2 wt=$3 launch=$4 rp=${5:-} st ap
  st=$(herdr agent start "fm-$id" --workspace "$ws" --cwd "$wt" --no-focus -- bash -lc "$launch") \
    || { echo "fm-backend: 'herdr agent start' failed for fm-$id" >&2; return 1; }
  ap=$(printf '%s' "$st" | _jget result.agent.pane_id)
  [ -n "$ap" ] || { echo "fm-backend: could not parse agent pane id" >&2; printf '%s\n' "$st" >&2; return 1; }
  if [ -n "$rp" ] && [ "$rp" != "$ap" ]; then herdr pane close "$rp" >/dev/null 2>&1 || true; fi
  echo "handle=$ap"
}

# spawn is open + launch in one shot (no turn-end hooks); handy for standalone use and tests.
herdr_spawn() {
  local id=$1 proj=$2 launch=$3 opened wt ws rp
  opened=$(herdr_open "$id" "$proj") || return 1
  wt=$(printf '%s\n' "$opened" | sed -n 's/^worktree=//p')
  ws=$(printf '%s\n' "$opened" | sed -n 's/^workspace=//p')
  rp=$(printf '%s\n' "$opened" | sed -n 's/^rootpane=//p')
  printf '%s\n' "$opened"
  herdr_launch "$id" "$ws" "$wt" "$launch" "$rp"
}

# herdr pane read prints the rendered screen text directly (not JSON); pass it through as-is.
herdr_read()     { herdr pane read "$1" --source visible --lines "${2:-40}"; }
herdr_send()      { local h=$1; shift; herdr pane send-text "$h" "$*" >/dev/null; herdr pane send-keys "$h" enter >/dev/null; }
herdr_send_text() { herdr pane send-text "$1" "$2" >/dev/null; }
herdr_send_key()  { herdr pane send-keys "$1" "$(_herdr_key "$2")" >/dev/null; }
herdr_state()    { local s; s=$(herdr agent get "$1" 2>/dev/null | _jget result.agent.agent_status); [ -n "$s" ] && echo "$s" || echo unknown; }
herdr_list()     { herdr agent list 2>/dev/null | python3 -c 'import sys,json
try: a=json.load(sys.stdin)["result"]["agents"]
except Exception: a=[]
for x in a:
    n=x.get("name","")
    if n.startswith("fm-"): print(n)'; }
herdr_kill() {
  local h=$1 ws=${2:-}
  if [ -n "$ws" ]; then
    # Removes the linked worktree AND closes its workspace+pane in one call.
    herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 || herdr pane close "$h" >/dev/null 2>&1 || true
  else
    herdr pane close "$h" >/dev/null 2>&1 || true
  fi
}

############################
# dispatch
############################

op=${1:-}; shift || true
case "$op" in
  open)     herdr_open "$@" ;;
  launch)   herdr_launch "$@" ;;
  spawn)    herdr_spawn "$@" ;;
  read)     herdr_read "$@" ;;
  send)     herdr_send "$@" ;;
  send-text) herdr_send_text "$@" ;;
  send-key) herdr_send_key "$@" ;;
  state)    herdr_state "$@" ;;
  list)     herdr_list ;;
  kill)     herdr_kill "$@" ;;
  *) echo "fm-backend: unknown op '$op' (open|launch|spawn|read|send|send-text|send-key|state|list|kill)" >&2; exit 2 ;;
esac
