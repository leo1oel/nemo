#!/usr/bin/env bash
# Send one line of literal text to a crewmate, then Enter.
# Usage: fm-send.sh <crewmate> <text...>
#   <crewmate> is a task id, fm-<id>, or a herdr pane id (handle from state/<id>.meta).
# Special keys instead of text: fm-send.sh <crewmate> --key Escape   (or Enter, C-c, ...)
#
# Text submission is VERIFIED: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (the text is still sitting in the composer after
# all retries), fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction (incident afk-invx-i5).
# The composer-detection primitive is shared with the away-mode daemon via
# bin/fm-herdr-lib.sh. Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: a cleared composer only proves the text was
# submitted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/fm-herdr-lib.sh
. "$FM_ROOT/bin/fm-herdr-lib.sh"

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
_send_enter() { "$BE" send-key "$1" Enter; }

if [ "${1:-}" = "--key" ]; then
  "$BE" send-key "$HANDLE" "$2"
else
  if ! "$BE" send-text "$HANDLE" "$*"; then
    echo "error: text not sent to $ARG (herdr pane send-text failed)" >&2
    exit 1
  fi
  # Slash commands open a completion popup in some TUIs; submitting too fast selects
  # nothing. Give popups time to settle before Enter.
  case "$*" in /*) sleep 1.2 ;; *) sleep 0.3 ;; esac
  # Type once, submit, verify via the shared border-aware detector. Lenient: only
  # a positively-confirmed swallow (text still in the composer after all retries)
  # is an error; an unreadable pane is assumed sent (an unknown verdict must not
  # turn a normal steer into a false failure).
  verdict=$(fm_herdr_submit_enter_core "$HANDLE" "${FM_SEND_RETRIES:-3}" "${FM_SEND_SLEEP:-0.4}" _send_enter)
  if [ "$verdict" = pending ]; then
    echo "error: text not submitted to $ARG (Enter swallowed; text left in composer)" >&2
    exit 1
  fi
  # Submit landed (verdict was not pending). The cleared composer only proves the
  # text was submitted; the harness still needs a beat to spin up the turn before
  # its busy footer shows. Pause so an immediate peek catches the crewmate actually
  # working instead of the stale idle pane. FM_SEND_SETTLE=0 disables it. Scoped to
  # this text path only, never the shared submit core the daemon uses.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
