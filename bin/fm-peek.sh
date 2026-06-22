#!/usr/bin/env bash
# Print the tail of a crewmate's screen (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <crewmate> [lines=40]
#   <crewmate> is a task id, fm-<id>, or a herdr pane id. The pane handle is read from
#   state/<id>.meta when present; otherwise the arg is used as the pane id directly.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true

ARG=${1:?usage: fm-peek.sh <crewmate> [lines]}
N=${2:-40}
ID=${ARG#fm-}
META="$FM_ROOT/state/$ID.meta"
if [ -f "$META" ]; then
  HANDLE=$(sed -n 's/^handle=//p' "$META")
else
  HANDLE=$ARG
fi
[ -n "$HANDLE" ] || { echo "error: no handle for $ARG" >&2; exit 1; }

"$FM_ROOT/bin/fm-backend.sh" read "$HANDLE" "$N"
