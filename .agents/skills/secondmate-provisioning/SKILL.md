---
name: secondmate-provisioning
description: Agent-only reference for creating, seeding, and routing persistent secondmates on the herdr backend. Use when promoting a domain to a persistent secondmate, seeding its isolated firstmate home, registering its route, handing off in-scope backlog, or recovering a dead secondmate. Covers the routing table, fm-home-seed, the idle-by-default contract, and backlog handoff.
user-invocable: false
---

# secondmate-provisioning

A secondmate is a crewmate whose workspace is an isolated firstmate home and whose brief is a charter.
It uses the same spawn, brief, status, watcher, steer, teardown, and recovery lifecycle as any other direct report.
Use this reference when creating or seeding a secondmate, registering its route, handing off backlog, or recovering one.

## Routing table

`data/secondmates.md` is the secondmate routing table. Every persistent secondmate has one line:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake; the `projects:` field is a non-exclusive clone list, not ownership.
Route by the nature of the task against each registered `scope:`, not just the project name; a project may appear in several clone lists.
If the resolved project is `local-only`, keep the work with the main firstmate even when a secondmate scope sounds relevant.

## Seeding a home

Use `bin/fm-home-seed.sh <id> <home|-> <project>...` after scaffolding the charter to provision the persistent home and registry entry.
A secondmate home is an isolated firstmate home.

- With `-`, `fm-home-seed.sh` provisions a fresh herdr worktree of the firstmate repo as the home and records its herdr workspace beside the home marker; herdr never recycles a worktree, so the home survives with no live process across restarts and is removed only on explicit retirement or seed rollback.
- An explicit `<home>` path argument stays a plain directory home (a git clone, no herdr worktree).

The charter must be filled before seeding; direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Seeding is transactional: if validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`bin/fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
Secondmate project lists may include `no-mistakes` and `direct-PR` projects only; `local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

Scaffold the charter with `bin/fm-brief.sh <id> --secondmate <project>...` (set `FM_SECONDMATE_CHARTER` / `FM_SECONDMATE_SCOPE`), then seed, then launch with `bin/fm-spawn.sh <id> --secondmate`.

## Idle by default

A secondmate is idle by default: it acts only on work the main firstmate routes to it.
On startup and restart it runs recovery solely to reconcile work that is already its own - in-flight crewmates, tracked backlog items, and durable watches in its home - and then waits silently for routed work.
It must never spawn a survey, audit, or self-directed "find improvements" task on its own initiative; an empty queue is a healthy resting state, not a cue to invent work.
This idle contract is encoded in the charter brief, so it travels with the live secondmate.

## Replies route via the status path

A secondmate is itself a firstmate, so a request relayed to it reaches it in its own chat, which the main firstmate never reads.
`fm-send` to a bare `fm-<id>` whose meta records `kind=secondmate` therefore prepends a from-firstmate marker (`bin/fm-marker-lib.sh`: the label `[fm-from-firstmate]` followed by an untypable separator).
The charter tells the secondmate to recognize that marker and return its answer via the status file - a status line for a terse result, or a doc under its home plus a status pointer (the scout-report pattern) for a detailed one - never only in chat.
An unmarked message is the captain typing directly: it stays conversational captain intervention.
When you route work to a secondmate, read its answer on the status/doc path, not by peeking its chat.

## Hand off in-scope backlog on creation

When a secondmate is created for a domain, the existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule: read `data/backlog.md`, pick the queued items that fit the new scope, and move them with `bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...`.
The helper resolves the secondmate home from `data/secondmates.md` and mechanically moves each named item from the main `data/backlog.md` into the secondmate home's `data/backlog.md`, preserving the line and its section, so the item is neither duplicated nor lost.
It refuses `## In flight` entries because active task ownership also lives in herdr and `state/`.
It is idempotent (an item already in the secondmate backlog is skipped) and refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items: that work stays with the main firstmate.

## Recovery and teardown

A secondmate is persistent by default; an empty queue is healthy and does not trigger teardown.
On a dead secondmate (its herdr pane is missing), respawn it with `bin/fm-spawn.sh <id> --secondmate` against the recorded `home=`; if the meta is missing but `data/secondmates.md` still registers it, respawn from the registry entry and its persistent on-disk home.
Retire one explicitly only on the captain's or main firstmate's decision with `bin/fm-teardown.sh <id>` (it refuses while the home has in-flight work); `--force` is the approved discard path.
