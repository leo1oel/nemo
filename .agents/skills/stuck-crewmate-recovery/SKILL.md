---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, a looping pane, repeated confusion, a question the brief already answers, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to interrupt, to relaunch with progress, to failed status.
user-invocable: false
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.
The crewmate's harness is recorded as `harness=` in `state/<id>.meta`; load `harness-adapters` for the interrupt, exit, and skill-invocation facts.

Escalate in order:

1. Peek the pane (`bin/fm-peek.sh fm-<id>`, default 40 lines).
2. Crewmate is waiting on a question its brief already answers: answer in one line via `bin/fm-send.sh fm-<id> '<answer>'`.
3. Crewmate is confused or looping: interrupt with the adapter's interrupt key (`bin/fm-send.sh fm-<id> --key Escape`), then redirect with one corrective line.
4. Crewmate is genuinely wedged after redirection: exit the agent with the adapter's exit command (`/exit`), then relaunch with the same brief plus a `progress so far` note you append to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. Second relaunch fails too: write `failed` to the backlog and tell the captain with evidence.

The context-% shown in a peek is not actionable as crew health; ignore it and intervene only on real signals (`signal`, `stale`, `needs-decision`, `blocked`), looping or confusion in the pane, or a question the brief already answers.
