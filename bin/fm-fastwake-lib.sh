#!/usr/bin/env bash
# fm-fastwake-lib.sh - event-accelerated poll sleep for the watcher (fork #472).
#
# Upstream firstmate wakes the supervisor on a blocked pane through a ~1600-line
# Python AF_UNIX subscriber to herdr's raw pane.agent_status_changed stream. This
# fork's herdr (0.7.3) ships a NATIVE blocking wait for that exact signal:
#     herdr wait agent-status <pane_id> --status blocked --timeout <ms>
# which returns rc 0 when the pane reaches the blocked status and rc 1 on timeout
# (or on a gone/errored pane). So the fork gets #472's value with the native
# primitive instead of the Python subscriber.
#
# fm_fastwake_sleep is a drop-in for the watcher's end-of-cycle `sleep <POLL>`. It
# sleeps up to <secs> but returns EARLY as soon as any live crewmate pane hits the
# blocked status, so a crew that stops to ask for a decision is re-examined by the
# next cycle within a second instead of waiting out the full poll interval. The
# existing pane-staleness detection then surfaces it exactly as before - this lib
# only changes WHEN the loop re-runs, never what it decides.
#
# Fail-safe by construction. It degrades to a plain `sleep <secs>` whenever the
# fast path is unavailable: FM_FASTWAKE=0, no herdr, no `herdr wait agent-status`,
# no mkfifo, no live crewmate panes, or a fifo that cannot be created. A busy-spin
# FLOOR (FM_FASTWAKE_FLOOR, default 2s) caps the loop rate so that even if the
# native wait were level-triggered - returning instantly for an already-blocked,
# already-surfaced pane - the watcher cannot spin faster than one cycle per floor.
#
# Knobs: FM_FASTWAKE (default 1; 0 disables), FM_FASTWAKE_FLOOR (default 2).
# The waiters signal the reader on scratch fd 9 (a fixed literal - bash 3.2 has no
# dynamic {fd} allocation, and the watcher's directory lock holds no fd, so 9 is
# free during the poll sleep).

# fm_fastwake_available: succeed (0) only when the native fast path can be used.
# Cheap; the one subprocess (herdr wait --help) is negligible at poll cadence.
fm_fastwake_available() {
  [ "${FM_FASTWAKE:-1}" != 0 ] || return 1
  command -v herdr >/dev/null 2>&1 || return 1
  command -v mkfifo >/dev/null 2>&1 || return 1
  herdr wait --help 2>/dev/null | grep -q 'agent-status' || return 1
  return 0
}

# fm_fastwake_sleep <secs> <state_dir> : sleep up to <secs>, returning early when
# any live crewmate pane (non-secondmate meta with a handle= in <state_dir>) hits
# the herdr blocked status. Always returns 0.
fm_fastwake_sleep() {
  local secs=$1 state=$2
  local floor=${FM_FASTWAKE_FLOOR:-2}

  if ! fm_fastwake_available; then sleep "$secs"; return 0; fi

  local handles=() meta hl
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] && continue
    hl=$(sed -n 's/^handle=//p' "$meta")
    [ -n "$hl" ] || continue
    handles+=("$hl")
  done
  if [ "${#handles[@]}" -eq 0 ]; then sleep "$secs"; return 0; fi

  local fifo="$state/.fastwake.${BASHPID:-$$}"
  rm -f "$fifo"
  mkfifo "$fifo" 2>/dev/null || { sleep "$secs"; return 0; }

  local t0 pids=() p
  t0=$(date +%s)
  # Read+write open so read -t works and the open never blocks waiting for a
  # writer (a plain read < fifo would hang forever if no pane ever blocks).
  exec 9<>"$fifo"
  for hl in "${handles[@]}"; do
    ( herdr wait agent-status "$hl" --status blocked --timeout "$(( secs * 1000 ))" >/dev/null 2>&1 \
        && printf '.\n' >&9 ) &
    pids+=("$!")
  done
  # Returns on the first waiter's write, or after <secs> on timeout.
  read -r -t "$secs" -u 9 _ 2>/dev/null || true
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait "${pids[@]}" 2>/dev/null || true
  exec 9<&- 9>&- 2>/dev/null || true
  rm -f "$fifo"

  # Busy-spin floor: an instant early return (an already-blocked pane under a
  # level-triggered wait) still costs at least <floor> seconds per cycle.
  local elapsed=$(( $(date +%s) - t0 ))
  [ "$elapsed" -lt "$floor" ] && sleep "$(( floor - elapsed ))"
  return 0
}
