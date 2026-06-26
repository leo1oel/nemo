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
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and wakes the first mate only when a crewmate reports, stalls, a PR merges, or an internal heartbeat review is due.
Detected wakes are also written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed one-shot process exit can be recovered by draining the queue.
Routine watcher polling, re-arm no-ops, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle crew costs you nothing.
Routine re-arms go through `bin/fm-watch-arm.sh`, which forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process; its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained, leading with a prominent bordered banner for the no-watcher case so it cannot be skimmed past.
The same guard carries a second bordered alarm: the worktree-tangle guard, which fires when the primary firstmate checkout is stranded on a feature branch (a crewmate working firstmate-on-itself that branched in the primary instead of its own worktree).

## Away-mode (`/afk`)

An optional sub-supervisor (`bin/fm-supervise-daemon.sh`) wraps the watcher, self-handles routine wakes in bash, and escalates only captain-relevant events as one batched, single-line digest injected into the captain's herdr pane - cutting supervision token cost while you step away.
It is presence-gated: the `/afk` skill turns it on, and the first genuine message turns it back off.

## Worktrees, not branches in your checkout

Crewmates never touch your clone; each gets its own herdr git worktree so parallel tasks on one repo cannot collide.
Spawn refuses to launch unless the opened worktree is a genuine isolated worktree distinct from the project's primary checkout.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`).
Scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.

## Optional secondmates

For larger fleets, `data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
A secondmate is a crewmate whose workspace is an isolated firstmate home and whose brief is a charter; it runs the same spawn/brief/status/watcher/steer/teardown/recovery lifecycle as any direct report, but from its own `FM_HOME` with separate state, backlog, projects, and session lock.
`fm-home-seed.sh` provisions the isolated home (with `-`, a herdr worktree of the firstmate repo that herdr never recycles, so it survives any restart), clones the listed `no-mistakes`/`direct-PR` projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and maintains the routing table; `fm-spawn.sh --secondmate` launches it through the same herdr and status-file path.
Before launch, the home is fast-forwarded to the primary checkout's current default-branch commit by a purely local fast-forward (no fetch), so a freshly spawned or recovery-respawned secondmate runs the primary's instructions and tooling.
Secondmates are idle by default: startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
After seeding, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.

## Local clones stay fresh

Each spawn and PR-based teardown refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default/off-lease targets are reported and left untouched.
The fast-forward machinery lives in `bin/fm-ff-lib.sh`, shared with the spawn-time secondmate sync.

## Restart-proof

All state lives in herdr, status files, local markdown under `data/`, `data/secondmates.md`, and the persistent secondmate homes.
Kill the first mate session anytime; the next one reconciles and carries on.
