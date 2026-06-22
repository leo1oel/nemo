#!/usr/bin/env bash
# Send one line of literal text to a crewmate, then Enter.
# Usage: fm-send.sh <crewmate> <text...>
#   <crewmate> is a task id, fm-<id>, or a herdr pane id (handle from state/<id>.meta).
# Special keys instead of text: fm-send.sh <crewmate> --key Escape   (or Enter, C-c, ...)
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true

ARG=${1:?usage: fm-send.sh <crewmate> <text...>}
shift
ID=${ARG#fm-}
META="$FM_ROOT/state/$ID.meta"
if [ -f "$META" ]; then
  HANDLE=$(sed -n 's/^handle=//p' "$META")
else
  HANDLE=$ARG
fi
[ -n "$HANDLE" ] || { echo "error: no handle for $ARG" >&2; exit 1; }

BE="$FM_ROOT/bin/fm-backend.sh"
if [ "${1:-}" = "--key" ]; then
  "$BE" send-key "$HANDLE" "$2"
else
  "$BE" send-text "$HANDLE" "$*"
  # Slash commands open a completion popup in some TUIs; submitting too fast selects
  # nothing. Give popups time to settle before Enter.
  case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  "$BE" send-key "$HANDLE" Enter
fi
