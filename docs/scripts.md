# The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.
Read each script's header comment before first use.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-fleet-sync.sh`       | Fetch clones, fast-forward safe default-branch states, self-heal clean detached ancestor drift, report unsafe drift as `STUCK:`, and safely prune branches whose remote is gone |
| `fm-ff-lib.sh`           | Shared fast-forward machinery for the spawn-time secondmate sync                                                   |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                  |
| `fm-brief.sh`            | Scaffold a ship brief, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate`        |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when tasks are in flight but queued wakes are pending or the watcher is down; also alarm on a worktree tangle (primary checkout on a feature branch) |
| `fm-tangle-lib.sh`       | Shared classifier for the worktree-tangle guard: a named non-default branch in the primary checkout                |
| `fm-home-seed.sh`        | Provision a secondmate home transactionally (a herdr worktree of the repo with `-`), clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs in one batch, or a persistent secondmate with `--secondmate`; records task kind |
| `fm-project-mode.sh`     | Resolve a project's delivery mode from `data/projects.md`                                                          |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe always-on watcher; absorbs no-verb signal and stale wakes only when the crew is provably working, queues and exits for actionable wakes, and reverts to daemon-owned one-shot behavior while `state/.afk` exists |
| `fm-classify-lib.sh`     | Shared captain-relevant wake classifier sourced by the watcher and daemon, plus the watcher's provably-working predicate (over `fm-crew-state.sh`) |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers used by watcher, guard, drain, arm, and daemon scripts          |
| `fm-herdr-lib.sh`        | Shared herdr pane primitives for composer detection, verified submit, pane existence, and busy-state reads         |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work, then assert watcher liveness (reuses fm-guard's beacon banner) so a lapsed chain surfaces on a plain drain turn |
| `fm-supervise-daemon.sh` | Optional away-mode sub-supervisor: wraps the watcher, self-handles routine wakes, escalates only captain-relevant events as one batched herdr-pane digest; presence-gated by `/afk` |
| `fm-crew-state.sh`       | Print one stable current-state line for a crew by reconciling its matching no-mistakes run-step, even when the pane has closed, with pane and status-log fallback |
| `fm-backend.sh`          | herdr backend abstraction: open/launch/read/send/kill panes and worktrees                                          |
| `fm-send.sh`             | Send one literal line (or `--key Escape`) to a crewmate pane; settles after a text submit; marks from-firstmate requests to a `kind=secondmate` target so the reply routes via the status path |
| `fm-marker-lib.sh`       | The from-firstmate request marker ([fm-from-firstmate] + an untypable separator) that tells a secondmate a relayed request apart from a captain-typed message |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-pr-merge.sh`         | Merge a task PR through `gh-axi` after recording PR metadata with `fm-pr-check.sh`                                  |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Remove the worktree and close its herdr pane, or retire a secondmate home; refuses unless ship work has landed (remote-reachable, a merged PR for the current HEAD, or content already in the default branch - so squash-merged-and-deleted branches tear down cleanly), requires scout reports, checks child work, and reminds backlog refresh |
| `fm-lock.sh`             | Single-firstmate session lock                                                                                       |
