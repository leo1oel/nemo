# The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.
Read each script's header comment before first use.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin      |
| `fm-ff-lib.sh`           | Shared fast-forward machinery (origin and local-HEAD base modes) for self-update and the spawn-time secondmate sync |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                  |
| `fm-tasks-axi-lib.sh`    | Shared probe deciding whether a compatible `tasks-axi` (0.1.1+) is on PATH for backlog mutations                    |
| `fm-brief.sh`            | Scaffold a ship brief, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate`        |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when tasks are in flight but queued wakes are pending or the watcher is down; also alarm on a worktree tangle (primary checkout on a feature branch) |
| `fm-tangle-lib.sh`       | Shared classifier for the worktree-tangle guard: a named non-default branch in the primary checkout                |
| `fm-home-seed.sh`        | Provision a secondmate home transactionally (a herdr worktree of the repo with `-`), clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs in one batch, or a persistent secondmate with `--secondmate`; records task kind |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `fm-supervise-daemon.sh` | Optional away-mode sub-supervisor: wraps the watcher, self-handles routine wakes, escalates only captain-relevant events as one batched herdr-pane digest; presence-gated by `/afk` |
| `fm-backend.sh`          | herdr backend abstraction: open/launch/read/send/kill panes and worktrees                                          |
| `fm-send.sh`             | Send one literal line (or `--key Escape`) to a crewmate pane; settles after a text submit                          |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Remove the worktree and close its herdr pane, or retire a secondmate home; refuses unless ship work has landed (remote-reachable, a merged PR for the current HEAD, or content already in the default branch - so squash-merged-and-deleted branches tear down cleanly), requires scout reports, checks child work, and reminds backlog refresh |
| `fm-lock.sh`             | Single-firstmate session lock                                                                                       |
