---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate only captain-relevant events as one batched digest, cutting supervision token cost during walk-away stretches. Exit is automatic; any real (unmarked) message returns to full per-wake responsiveness.
user-invocable: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the captain is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking firstmate's
LLM for each one. Escalations still reach the captain — but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Set the durable away-mode flag:**
   ```sh
   date '+%s' > state/.afk
   ```
   This file survives a firstmate restart: recovery (§5) re-enters afk if the
   flag is present.

2. **Ensure the sub-supervisor daemon is running.** Check the pid file; start
   the daemon only if it is dead or absent:
   ```sh
   if [ -f state/.supervise-daemon.pid ] && kill -0 "$(cat state/.supervise-daemon.pid)" 2>/dev/null; then
     : # daemon already alive — it picks up the flag on its next cycle
   else
     nohup bin/fm-supervise-daemon.sh >/dev/null 2>&1 &
   fi
   ```
   The daemon is **presence-gated**: it injects escalations only while
   `state/.afk` exists, and stays quiet otherwise. Launch it from your own
   (captain) pane so it inherits `HERDR_PANE_ID` — that is the supervisor pane it
   injects digests back into. Override with `FM_SUPERVISOR_TARGET=<pane-id>`.

3. **Do not separately arm `fm-watch.sh`.** The daemon manages the watcher as
   its child; the singleton lock no-ops a stray arm harmlessly. While `state/.afk`
   exists the watcher reverts to one-shot and surfaces every wake for the daemon to
   classify, so the daemon and the always-on watcher never run their triage at the
   same time. Both apply one identical policy: the captain-relevant verb set and the
   signal/stale/heartbeat predicates live in the shared `bin/fm-classify-lib.sh` the
   always-on watcher uses for its own triage when afk is off, so the two modes cannot
   drift apart.

4. **Acknowledge** to the captain that away-mode is active: the daemon will
   self-handle routine wakes, escalate only captain-relevant events, and the
   captain can exit by sending any real message.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk`
  → the captain is back. Clear `state/.afk`, stop the daemon, flush one
  distilled "while you were out" catch-up (drain `state/.wake-queue`, summarize
  any pending escalations from `state/.subsuper-escalations` and any
  `state/.subsuper-inject-wedged` marker), and resume full per-wake
  responsiveness (arm `bin/fm-watch.sh`).
- A message **with** the sentinel marker (`FM_INJECT_MARK`, ASCII 0x1f) → it
  is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away → stay afk (refresh the flag); this
  does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and
a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively firstmate surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive still waits for the captain's
explicit word — the daemon just batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `FM_INJECT_MARK` (ASCII unit
separator, 0x1f) — invisible and untypable. This is how firstmate tells a
daemon escalation apart from a real message in the same pane. The marker
travels with the message text in-band, so it does not rely on any harness-level
or herdr-level typed-vs-injected distinction.

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection (the composer/submit logic is shared with `fm-send.sh` via
`bin/fm-herdr-lib.sh`):

- **`pane_is_busy`** — reads herdr's `agent_status` for the pane (caught live as
  the reliable signal: it covers Claude's thinking phase, which the busy-footer
  text alone misses). Footer regex is the fallback when the integration is absent.
- **`pane_input_pending`** — reads Claude's composer line (herdr exposes no
  cursor position; the composer is not the last line — status footers render
  below it). The detector **strips Claude's composer box borders first**, so an
  idle *bordered* composer (Claude draws `│ > … │`) is correctly read as empty,
  not pending. Without this, every idle Claude pane looked like pending input
  and the daemon deferred 100% of escalations (incident afk-invx-i5). Real
  unsubmitted text after the prompt glyph (a half-typed line, or a previous
  injection whose Enter was swallowed) reads as pending. `FM_COMPOSER_IDLE_RE`
  still overrides empty-composer matching after border stripping.

Either condition defers the injection; the buffered escalation survives in
`state/.subsuper-escalations` and is retried on the next housekeeping tick. In
afk mode the composer guard is belt-and-suspenders (no human is typing), but it
protects against the daemon's own previous injection sitting unsent.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `FM_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush (still requiring an idle pane and empty composer). If
that submit cannot be confirmed, it raises a loud, rate-limited wedge alarm: an
ERROR in the daemon log, a durable `state/.subsuper-inject-wedged` marker
(surface it on the "while you were out" catch-up if present), and a status-line
flash on the supervisor client via `herdr notification show`. A guard
false-positive becomes a visible stall, never an unbounded silent no-op.

## Submit model

The daemon types the digest **once** via `herdr pane send-text`, then submits
with `herdr pane send-keys ... enter` and **verifies** the submit landed using
the same border-aware detector as the composer guard. A submit "landed" only
when a turn started (the pane goes busy) **or** the composer is confirmed empty
afterward — a bordered-empty Claude composer (`│ > │`) is recognized as
submitted rather than mistaken for a swallowed Enter. Enter is retried **Enter
only** (never retypes the digest) while the composer still shows our text,
preventing concatenation of two sentinel-prefixed digests into one corrupted
turn. `fm-send.sh` shares the same primitive and **exits non-zero** when a
steer's Enter is positively swallowed, so firstmate learns an instruction did
not land instead of leaving it silently unsubmitted.
