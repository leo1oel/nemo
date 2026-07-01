# Architecture

How firstmate runs a crew on the herdr backend. This is the reference for the
internals the [README](../README.md) summarizes; the orchestrator contract itself
lives in [`AGENTS.md`](../AGENTS.md).

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/; writes guarded     │
 │ backlog.md ── briefs ── watcher     │
 └──┬──────────────┬───────────────┬───┘
    │ herdr socket / status files   │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   herdr panes you can watch
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  herdr git worktree (clean, disposable, parallel-safe)
     │
     ├─ ship: project mode ► PR ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, check-script output such as PR merge polling, terminal stale panes, non-terminal stale panes whose crew is not provably working, provably-working non-terminal stale panes that persist past `FM_STALE_ESCALATE_SECS`, and heartbeat backstop hits.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
No-verb wakes, such as `working:` notes, bare turn-ended signals, and fresh non-terminal stale panes, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step for that crew's branch or a pane busy signature.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
Routine watcher polling, re-arm no-ops, elapsed waiting time, and absorbed benign wakes stay silent; an idle crew costs you nothing.
Crew status files are append-only wake-event logs, not current-state fields.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes the matching no-mistakes run, active or terminal, to the crew's own branch and keeps that run-step authoritative even if the pane has closed.
Only when no matching run exists does it fall back to the pane busy-signature and then the status log; a dead pane without a run reports unknown instead of trusting a stale log.
Routine re-arms go through `bin/fm-watch-arm.sh`, which forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process; its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained, leading with a prominent bordered banner for the no-watcher case so it cannot be skimmed past.
`bin/fm-wake-drain.sh` runs that same guard after it drains, so a lapsed supervision chain also surfaces on a plain drain-and-handle turn that runs no other supervision script; the grace beacon keeps it silent right after a normal fire.
The same guard carries a second bordered alarm: the worktree-tangle guard, which fires when the primary firstmate checkout is stranded on a feature branch (a crewmate working firstmate-on-itself that branched in the primary instead of its own worktree).

## Away-mode (`/afk`)

An optional sub-supervisor (`bin/fm-supervise-daemon.sh`) wraps the watcher, self-handles routine wakes in bash, and escalates only captain-relevant events as one batched, single-line digest injected into the captain's herdr pane - cutting supervision token cost while you step away.
It is presence-gated: the `/afk` skill turns it on, and the first genuine message turns it back off.
While it is on, the watcher reverts to daemon-owned one-shot mode and the daemon does the triage; the two share `bin/fm-classify-lib.sh` for captain-relevant status verbs and status-scan primitives, while the always-on watcher additionally uses that library's provably-working predicate on its no-verb signal and non-terminal-stale paths, so the overlapping policy cannot drift.

## Worktrees, not branches in your checkout

Crewmates never touch your clone; each gets its own herdr git worktree so parallel tasks on one repo cannot collide.
Spawn refuses to launch unless the opened worktree is a genuine isolated worktree distinct from the project's primary checkout.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes` or `direct-PR`).
Scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
Teardown refuses to discard a ship worktree until its work has landed - remote-reachable, a merged PR whose GitHub head contains the current local work (an exact match, a local HEAD that is an ancestor of the PR head, or unpushed local patches whose patch IDs appear in the PR head after a squash replay), or content already in the up-to-date default branch - so the common squash-merge-then-delete-branch flow tears down cleanly while genuinely unlanded or uncommitted work still refuses.

## Project modes are explicit

`data/projects.md` records each project's delivery mode.
`no-mistakes` projects run the full validation pipeline, while `direct-PR` projects open PRs without that pipeline.

## Optional secondmates

For larger fleets, `data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
A secondmate is a crewmate whose workspace is an isolated firstmate home and whose brief is a charter; it runs the same spawn/brief/status/watcher/steer/teardown/recovery lifecycle as any direct report, but from its own `FM_HOME` with separate state, backlog, projects, and session lock.
`fm-home-seed.sh` provisions the isolated home (with `-`, a herdr worktree of the firstmate repo that herdr never recycles, so it survives any restart), clones the listed projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and maintains the routing table; `fm-spawn.sh --secondmate` launches it through the same herdr and status-file path.
Before launch, the home is fast-forwarded to the primary checkout's current default-branch commit by a purely local fast-forward (no fetch), so a freshly spawned or recovery-respawned secondmate runs the primary's instructions and tooling.
Secondmates are idle by default: startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
A secondmate is itself a firstmate, so a relayed request reaches it in its own chat, which the main firstmate never reads; `fm-send` to a `kind=secondmate` target prepends a from-firstmate marker (`fm-marker-lib.sh`) and the secondmate routes its answer back via its status file (or a doc plus a status pointer) so it surfaces to the main firstmate, while an unmarked message stays conversational captain intervention.
After seeding, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.

## Local clones stay fresh

Each spawn and PR-based teardown refresh remote-backed project clones when the clone is safe to move.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Clones without an origin remote and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Restart-proof

All state lives in herdr, no-mistakes run records, status event logs, local markdown under `data/`, `data/secondmates.md`, and the persistent secondmate homes.
Kill the first mate session anytime; the next one reconciles and carries on.
