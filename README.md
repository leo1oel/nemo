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
On first launch the first mate detects what its toolchain is missing (herdr, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi), lists it with the exact install commands, and installs only after you say go.

`tasks-axi` is optional backlog tooling: the tracked `.tasks.toml` pins its markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When a compatible build (0.1.1 or newer, by the probe in `bin/fm-tasks-axi-lib.sh`) is on `PATH`, the first mate routes routine backlog mutations through its verbs and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation; without it, backlog bookkeeping stays manual exactly as before.

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

You talk to the first mate; it spawns each task as an autonomous Claude Code agent in its own disposable herdr git worktree, supervises the whole fleet with a zero-token bash watcher, and hands you finished PRs, approved local merges, or scout reports.
A pull-based guard surfaces a downed watcher or a tangled checkout on your next action, `/afk` hands routine supervision to a token-cheap bash sub-supervisor while you step away, and the whole thing is restart-proof: kill the session anytime and the next one reconciles from herdr and the local state files.

See **[docs/architecture.md](docs/architecture.md)** for the full internals: event-driven supervision, worktrees, the two task shapes, explicit project modes, optional secondmates, project memory, safe self-updates, and restart-proofing.

## Built-in skills

Firstmate ships two skills you invoke by name with the slash form (e.g. `/afk`).
`no-mistakes` is a user-level prerequisite (`~/.claude/skills`), not a firstmate-shipped skill, so it is not listed here.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash and escalates only captain-relevant events as one batched digest, cutting supervision cost while you step away |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |

It also carries agent-only reference skills the first mate loads on demand, not by name: `harness-adapters` (Claude adapter facts), `stuck-crewmate-recovery` (the stuck-direct-report playbook), and `secondmate-provisioning` (seeding and routing secondmates).

## Documentation

- **[docs/architecture.md](docs/architecture.md)** - how the crew, event-driven supervision, worktrees, task shapes, project modes, and secondmates work.
- **[docs/configuration.md](docs/configuration.md)** - `AGENTS.md`, `FM_HOME`, the backlog backend, captain preferences, secondmate routes, harness support, and the full environment-variable reference.
- **[docs/scripts.md](docs/scripts.md)** - the `bin/` toolbelt.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - the contributor workflow, repo conventions, and the dev/test commands.

## Contributing

Tracked changes to firstmate itself ship through the `no-mistakes` pipeline on a feature branch and require the captain's explicit merge approval; human pull requests targeting `main` are raised through `git push no-mistakes`.
See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the enforced workflow, repo conventions, and the lint/test commands.
