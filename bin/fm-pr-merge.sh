#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh. This keeps fm-teardown.sh's
# landed-work check reliable after squash-merge/delete-branch flows.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"

[ -f "$META" ] || {
  echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2
  exit 1
}

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2
  exit 1
}

gh-axi pr merge "$URL" "$@"
