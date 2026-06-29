# Configuration

Where firstmate's behavior and per-fleet state are configured.

## Orchestrator behavior (`AGENTS.md`)

The shared orchestrator behavior lives in `AGENTS.md` - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.
`CLAUDE.md` is a symlink to it, and `.claude/skills` symlinks to `.agents/skills`.

## Backlog backend (`.tasks.toml` / `tasks-axi`)

`tasks-axi` is optional backlog tooling: the tracked `.tasks.toml` pins its markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When a compatible build (0.1.1 or newer, by the probe in `bin/fm-tasks-axi-lib.sh`) is on `PATH`, the first mate routes routine backlog mutations through its verbs and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation; without it, backlog bookkeeping stays manual exactly as before.

## Captain preferences (`data/captain.md`)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` at session start.

## Secondmate routes (`data/secondmates.md`)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
Use `fm-home-seed.sh <id> - <project>...` to provision a fresh herdr worktree of the firstmate repo as the secondmate home; herdr never recycles it, so the home survives across restarts until explicit retirement or seed rollback removes it.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## `FM_HOME`

`FM_HOME` selects the operational home for a firstmate instance.
When unset, the home is the repo root; when set, scripts still use their own `bin/` but read `state/`, `data/`, `config/`, and `projects/` from `$FM_HOME`.
Each secondmate gets its own persistent `FM_HOME`, so its local state, backlog, projects, and session lock are isolated from the main firstmate.

## Harness support

This fork is Claude-only; crewmates run on Claude Code.
The verified Claude adapter facts (busy signature, exit, interrupt, trust dialog, ghost text) live in the `harness-adapters` skill.
To add other agents, pull the harness adapters from upstream firstmate.

## Environment variables

Runtime tuning (defaults shown):

```sh
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_SEND_SETTLE=1        # seconds fm-send pauses after a successful text submit (0 disables)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc to interrupt'   # Claude's busy-pane signature
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that makes watcher and daemon signal/stale/scan output captain-relevant
FM_STALE_ESCALATE_SECS=240   # idle seconds before a provably-working non-terminal stale pane escalates; not-provably-working stale wakes surface immediately
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by provably-working watcher triage
```

Sub-supervisor (`fm-supervise-daemon.sh`, away-mode) knobs:

```sh
FM_SUPERVISOR_TARGET    # captain's herdr pane id (else auto-discovered from HERDR_PANE_ID)
FM_ESCALATE_BATCH_SECS=90    # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300        # force one flush if a digest stays undelivered this long; 0 disables
FM_HEARTBEAT_SCAN_SECS=300   # cadence of the catch-all status scan
FM_INJECT_SKIP=heartbeat     # |-separated wake prefixes to force-self-handle
```
