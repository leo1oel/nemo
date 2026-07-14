# The bin/ toolbelt

The first mate drives these; you rarely need to, but they work by hand too.
Read each script's header comment before first use.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-fleet-sync.sh`       | Fetch clones, fast-forward safe default-branch states, self-heal clean detached ancestor drift, report unsafe drift as `STUCK:`, and safely prune branches whose remote is gone |
| `fm-fleet-snapshot.sh`   | Read-only structured (`--json`, schema `fm-fleet-snapshot.v1`) snapshot of the whole fleet: backlog, one row per task meta with reconciled current state and herdr endpoint presence, open-decision hints, scout reports, and a secondmate-landed roll-up; no locks, wakes, or mutations |
| `fm-fleet-view.sh`       | Human renderer over `fm-fleet-snapshot.sh --json` (a fleet table); `--json` passes the underlying snapshot through |
| `fm-bearings-snapshot.sh` | Compact TOON projection of the canonical snapshot for a "pick up where I left off" read; LOCAL-ONLY by default (zero network), with `--include-prs` as the sole opt-in that touches GitHub; feeds the `bearings` skill (`/bearings`) |
| `fm-ff-lib.sh`           | Shared fast-forward machinery for the spawn-time secondmate sync                                                   |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                  |
| `fm-brief.sh`            | Scaffold a ship brief, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate`        |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when tasks are in flight but queued wakes are pending or the watcher is down; also alarm on a worktree tangle (primary checkout on a feature branch) |
| `fm-tangle-lib.sh`       | Shared classifier for the worktree-tangle guard: a named non-default branch in the primary checkout                |
| `fm-turnend-guard.sh`    | Claude Code Stop hook (tracked `.claude/settings.json`): blocks a primary turn end, once per turn, when tasks are in flight with no fresh watcher beacon (or a dead afk daemon) |
| `fm-cd-pretool-check.sh` | Claude PreToolUse hook: denies a persistent top-level `cd`/`pushd`/`popd` in the real primary checkout before it relocates the shell; inert in a linked worktree, fails open on any uncertainty (`docs/cd-guard.md`) |
| `fm-cd-command-policy.mjs` | Sole block/allow decision owner for the cd-guard; reuses the shared shell classifier from `fm-arm-command-policy.mjs` |
| `fm-arm-pretool-check.sh` | Claude PreToolUse hook: denies a watcher arm that is not a standalone verified call (bundled, piped, redirected, backgrounded, nested) and a broad `pkill -f fm-watch`; fails closed on an unclassifiable protected command (`docs/arm-pretool-check.md`) |
| `fm-arm-command-policy.mjs` | Sole owner of firstmate's shell command classification and the watcher-arm decision procedure; exports the tokenizer the cd-guard imports |
| `fm-home-seed.sh`        | Provision a secondmate home transactionally (a herdr worktree of the repo with `-`), clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-session-start.sh`    | One-command session start: lock, diagnostics, wake drain (or read-only report), full context + fleet digest, and the watcher next step |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs in one batch, or a persistent secondmate with `--secondmate`; records task kind; `--model`/`--effort` set the Claude launch profile, enforced as the dispatch backstop while `config/crew-dispatch.json` is active |
| `fm-config-inherit-lib.sh` | Shared primary-authoritative propagation of declared inheritable config items into secondmate homes             |
| `fm-config-push.sh`      | Push the primary's inheritable local config (e.g. `config/crew-dispatch.json`) to every live secondmate home mid-session |
| `fm-project-mode.sh`     | Resolve a project's delivery mode from `data/projects.md`                                                          |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, comparing the recorded PR head (`pr_head=` or `refs/pull/<n>/head`) when `pr=` is recorded, with optional `--stat` output |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `attached` (rides an already-healthy cycle until it ends, so no empty false wake), or `FAILED`; `--restart` relaunches only this home's watcher (`healthy` is restart-only) |
| `fm-watch.sh`            | Singleton-safe always-on watcher; absorbs no-verb signal and stale wakes only when the crew is provably working, queues and exits for actionable wakes (at most one stale/wedge wake per stall episode, on a footer-excluded pane hash), and reverts to daemon-owned one-shot behavior while `state/.afk` exists |
| `fm-classify-lib.sh`     | Shared captain-relevant wake classifier sourced by the watcher and daemon, plus the watcher's provably-working predicate (over `fm-crew-state.sh`) |
| `fm-fastwake-lib.sh`     | Event-accelerated poll sleep for the watcher (#472): returns early on a herdr `blocked` agent-status via the native `herdr wait agent-status`, so a stopped crew is re-examined within a second instead of a full poll; fail-safe to a plain sleep, floored against busy-spin |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers used by watcher, guard, drain, arm, and daemon scripts          |
| `fm-herdr-lib.sh`        | Shared herdr pane primitives for composer detection, verified submit, pane existence, and busy-state reads, plus the single footer-window definition that busy detection scans and the watcher's staleness hash excludes |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work, then assert watcher liveness (reuses fm-guard's beacon banner) so a lapsed chain surfaces on a plain drain turn |
| `fm-supervise-daemon.sh` | Optional away-mode sub-supervisor: wraps the watcher, self-handles routine wakes, escalates only captain-relevant events as one batched herdr-pane digest; presence-gated by `/afk` |
| `fm-crew-state.sh`       | Print one stable current-state line for a crew by reconciling its matching no-mistakes run-step, even when the pane has closed, with pane and status-log fallback |
| `fm-backend.sh`          | herdr backend abstraction: open/launch/read/send/kill panes and worktrees                                          |
| `fm-send.sh`             | Send one literal line (or `--key Escape`) to a crewmate pane; settles after a text submit; marks from-firstmate requests to a `kind=secondmate` target so the reply routes via the status path |
| `fm-marker-lib.sh`       | The from-firstmate request marker ([fm-from-firstmate] + an untypable separator) that tells a secondmate a relayed request apart from a captain-typed message |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-pr-merge.sh`         | Require a full GitHub PR URL, record `pr=` and available `pr_head=` via `fm-pr-check.sh`, parse it into `gh-axi pr merge <n> --repo <owner>/<repo>`, default to `--squash` unless a merge method is forwarded, and reject malformed URLs or repo overrides |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Remove the worktree and close its herdr pane, or retire a secondmate home; refuses unless ship work has landed (remote-reachable, a merged PR for the current HEAD, or content already in the default branch - so squash-merged-and-deleted branches tear down cleanly), requires scout reports, checks child work, and reminds backlog refresh |
| `fm-lock.sh`             | Single-firstmate session lock                                                                                       |
