<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.jpg" width="100%" />
</p>

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents as herdr panes, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
There is no app to install; the whole orchestrator is an `AGENTS.md` file that any terminal coding agent can follow.

- **One liaison** - you never talk to a worker agent.
  The first mate dispatches, supervises, escalates only real decisions, and reports plain outcomes about work that is ready, blocked, or needs your call.
- **A visible crew** - every crewmate is a herdr pane with live state in the sidebar.
  Watch any of them work, or type into their pane to intervene; the first mate reconciles.
- **Guarded by construction** - the first mate is read-only over your projects except for clean local default-branch refreshes, safe pruning of local branches whose remote is gone, and approved `local-only` fast-forward merges; crewmates work in disposable herdr git worktrees.
  Ship tasks follow each project's delivery mode, and scout tasks produce local reports without pushing anything.

This is not an agent harness. This is not a skill. This is not a CLI.

This is.. a directory that turns any agent into your firstmate, and you the captain.

## Quick Start

```sh
$ git clone https://github.com/kunchenguid/firstmate && cd firstmate
$ claude   # launch your agent harness here; AGENTS.md takes over

> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/, and spawns two crewmates as herdr panes
# fm-fix-login-k3 and fm-dark-mode-p7.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

## Install

**Prerequisites** (the first mate detects everything else and offers to install it):

```sh
# 1. Claude Code (this fork is Claude-only)
# 2. git + GitHub auth
# 3. herdr - the crew lives in herdr panes (firstmate offers to install it if missing)
gh auth login
```

**Get firstmate:**

```sh
git clone https://github.com/kunchenguid/firstmate
cd firstmate && claude
```

That is the whole install.
On first launch the first mate detects what its toolchain is missing (herdr, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi), lists it with the exact install commands, and installs only after you say go.

**Crewmates live in herdr.**
Each crewmate is a herdr agent pane in its own worktree workspace; watch any of them in the herdr sidebar or type into a pane to intervene, and the first mate reconciles.

## How It Works

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

- **Event-driven supervision** - a zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet and wakes the first mate only when a crewmate reports, stalls, a PR merges, or an internal heartbeat review is due.
  Detected wakes are also written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed one-shot process exit can be recovered by draining the queue.
  Routine watcher polling, re-arm no-ops, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle crew costs you nothing.
  Routine re-arms go through `bin/fm-watch-arm.sh`, which forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process; its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
  A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained, leading with a prominent bordered banner for the no-watcher case so it cannot be skimmed past.
- **Away-mode (`/afk`)** - an optional sub-supervisor (`bin/fm-supervise-daemon.sh`) wraps the watcher, self-handles routine wakes in bash, and escalates only captain-relevant events as one batched, single-line digest injected into the captain's herdr pane - cutting supervision token cost while you step away. It is presence-gated: the `/afk` skill turns it on, and the first genuine message turns it back off.
- **Worktrees, not branches in your checkout** - crewmates never touch your clone; each gets its own herdr git worktree so parallel tasks on one repo cannot collide.
- **Two task shapes** - ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
- **Project modes are explicit** - `data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
  `no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
- **Optional secondmates** - for larger fleets, `data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
  A secondmate is a crewmate whose workspace is an isolated firstmate home and whose brief is a charter; it runs the same spawn/brief/status/watcher/steer/teardown/recovery lifecycle as any direct report, but from its own `FM_HOME` with separate state, backlog, projects, and session lock.
  `fm-home-seed.sh` provisions the isolated home (with `-`, a herdr worktree of the firstmate repo that herdr never recycles, so it survives any restart), clones the listed `no-mistakes`/`direct-PR` projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and maintains the routing table; `fm-spawn.sh --secondmate` launches it through the same herdr and status-file path.
  Secondmates are idle by default: startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
  After seeding, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
  Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.
- **Project memory belongs to projects** - durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
  Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
- **Local clones stay fresh** - each spawn and PR-based teardown refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.
- **Self-updates stay safe** - `/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
  The update is fast-forward only: dirty, diverged, offline, and off-default/off-lease targets are reported and left untouched.
- **Restart-proof** - all state lives in herdr, status files, local markdown under `data/`, `data/secondmates.md`, and the persistent secondmate homes.
  Kill the first mate session anytime; the next one reconciles and carries on.

## The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin      |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                  |
| `fm-brief.sh`            | Scaffold a ship brief, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate`        |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when tasks are in flight but queued wakes are pending; lead stale or missing watcher cases with a prominent banner |
| `fm-home-seed.sh`        | Provision a secondmate home transactionally (a herdr worktree of the repo with `-`), clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs in one batch, or a persistent secondmate with `--secondmate`; records task kind |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `fm-supervise-daemon.sh` | Optional away-mode sub-supervisor: wraps the watcher, self-handles routine wakes, escalates only captain-relevant events as one batched herdr-pane digest; presence-gated by `/afk` |
| `fm-send.sh`             | Send one literal line (or `--key Escape`) to a crewmate window                                                      |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Remove the worktree and close its herdr pane, or retire a secondmate home; protects ship work, requires scout reports, checks child work, and reminds backlog refresh |
| `fm-lock.sh`             | Single-firstmate session lock                                                                                       |

## Built-in skills

Firstmate ships these built-in skills you invoke by name with the slash form (e.g. `/afk`).
`no-mistakes` is a user-level prerequisite (`~/.claude/skills`), not a firstmate-shipped skill, so it is not listed here.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash and escalates only captain-relevant events as one batched digest, cutting supervision cost while you step away |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |

## Configuration

The shared orchestrator behavior lives in `AGENTS.md` - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.
Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` at session start.
This fork is Claude-only; crewmates run on Claude Code. To add other agents, pull the harness adapters from upstream firstmate.

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
Use `fm-home-seed.sh <id> - <project>...` to provision a fresh herdr worktree of the firstmate repo as the secondmate home; herdr never recycles it, so the home survives across restarts until explicit retirement or seed rollback removes it.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

Runtime tuning via environment variables (defaults shown):

```sh
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc to interrupt'   # Claude's busy-pane signature
```

Sub-supervisor (`fm-supervise-daemon.sh`, away-mode) knobs:

```sh
FM_SUPERVISOR_TARGET    # captain's herdr pane id (else auto-discovered from HERDR_PANE_ID)
FM_STALE_ESCALATE_SECS=240   # idle seconds before a stale pane escalates as a possible wedge
FM_ESCALATE_BATCH_SECS=90    # buffer window for batched escalation digests; 0 = flush immediately
FM_HEARTBEAT_SCAN_SECS=300   # cadence of the catch-all status scan
FM_INJECT_SKIP=heartbeat     # |-separated wake prefixes to force-self-handle
```

## Development

Tracked changes to firstmate itself, including `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.github/workflows/`, `bin/`, and agent skill files, ship through the `no-mistakes` pipeline on a feature branch and require the captain's explicit merge approval.
When supervising live crewmates, keep long validation or build work in the background so watcher wakes can still be handled.
Human-authored pull requests targeting `main` must be raised through `git push no-mistakes`; see `CONTRIBUTING.md` for the enforced contributor workflow.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory instead.
The current watcher reliability work keeps the one-shot process model and adds a durable queue, race-proof singleton lock, duplicate self-eviction, and a self-verifying tracked-child arm wrapper.
The persistent detector daemon and blocking waiter split are deferred follow-up phases.

```sh
bash -n bin/*.sh                          # syntax-check the toolbelt
shellcheck bin/*.sh tests/*.sh            # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do "$test_script"; done   # behavior tests, matching CI
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
FM_HEARTBEAT=2 FM_POLL=1 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then "heartbeat")
```
