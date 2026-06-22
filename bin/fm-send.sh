#!/usr/bin/env bash
# Send one line of literal text to a crewmate, then Enter.
# Usage: fm-send.sh <crewmate> <text...>
#   <crewmate> is a task id, fm-<id>, or (legacy) a tmux session:window.
# Special keys instead of text: fm-send.sh <crewmate> --key Escape   (or Enter, C-c, ...)
# The backend (herdr|tmux) and handle are read from state/<id>.meta when present;
# otherwise the arg is treated as a literal target under FM_BACKEND (default tmux).
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true

ARG=${1:?usage: fm-send.sh <crewmate> <text...>}
shift
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
  BE="$FM_ROOT/bin/fm-backend.sh"
  if [ "${1:-}" = "--key" ]; then
    FM_BACKEND=herdr "$BE" send-key "$HANDLE" "$2"
  else
    FM_BACKEND=herdr "$BE" send-text "$HANDLE" "$*"
    # Slash commands open a completion popup in some TUIs; submitting too fast selects
    # nothing. Give popups time to settle before Enter (mirrors the tmux path).
    case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
    FM_BACKEND=herdr "$BE" send-key "$HANDLE" Enter
  fi
else
  case "$HANDLE" in
    *:*) T="$HANDLE" ;;
    *)   T=$(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$HANDLE\$") \
           || { echo "error: no window named $HANDLE" >&2; exit 1; } ;;
  esac
  if [ "${1:-}" = "--key" ]; then
    tmux send-keys -t "$T" "$2"
  else
    tmux send-keys -t "$T" -l "$*"
    case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
    tmux send-keys -t "$T" Enter
  fi
fi
