#!/usr/bin/env bash
# Print the tail of a crewmate's screen (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <crewmate> [lines=40]
#   <crewmate> is a task id, fm-<id>, or (legacy) a tmux session:window.
# The backend (herdr|tmux) and handle are read from state/<id>.meta when present;
# otherwise the arg is treated as a literal target under FM_BACKEND (default tmux).
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true

ARG=${1:?usage: fm-peek.sh <crewmate> [lines]}
N=${2:-40}
ID=${ARG#fm-}
META="$FM_ROOT/state/$ID.meta"
if [ -f "$META" ]; then
  BACKEND=$(sed -n 's/^backend=//p' "$META"); [ -n "$BACKEND" ] || BACKEND=tmux
  HANDLE=$(sed -n 's/^handle=//p' "$META"); [ -n "$HANDLE" ] || HANDLE=$(sed -n 's/^window=//p' "$META")
else
  BACKEND=${FM_BACKEND:-tmux}
  HANDLE=$ARG
fi

if [ "$BACKEND" = herdr ]; then
  FM_BACKEND=herdr "$FM_ROOT/bin/fm-backend.sh" read "$HANDLE" "$N"
else
  case "$HANDLE" in
    *:*) T="$HANDLE" ;;
    *)   T=$(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$HANDLE\$") \
           || { echo "error: no window named $HANDLE" >&2; exit 1; } ;;
  esac
  tmux capture-pane -p -t "$T" -S -"$N"
fi
