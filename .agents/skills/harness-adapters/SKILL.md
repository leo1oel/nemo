---
name: harness-adapters
description: Agent-only reference for firstmate crewmate-harness operations on the herdr backend. Use before spawning or recovering a crewmate or secondmate, handling a trust or bypass-permissions dialog, sending a skill invocation, interrupting or exiting an agent, or reading a pane's composer. This fork is Claude-only; the verified Claude Code facts are here.
user-invocable: false
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, or composer reading.

This fork is Claude-only: every crewmate and secondmate runs Claude Code.
Each crewmate is a herdr agent pane named `fm-<id>`, living in its own git worktree workspace and shown live in the herdr sidebar (idle / working / blocked / done); state comes from herdr, not from scraping the screen.
The supervision scripts reach a crewmate through its `handle=` (the herdr pane id) recorded in `state/<id>.meta`, and the harness as `harness=` in the same file.
To enumerate live crewmates, read `state/*.meta` or `bin/fm-backend.sh list`.

The launch mechanics - launch command, autonomy flag, turn-end hook - live in `bin/fm-spawn.sh`.
The supervision knowledge is here: busy signature, exit command, interrupt, dialogs, skill invocation, and the ghost-text quirk.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

Send the validation skill as `/<skill>`, for example `bin/fm-send.sh fm-<id> '/no-mistakes'`; natural language is acceptable if uncertain.

## Trust / bypass-permissions dialog

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
`bin/fm-spawn.sh` pre-seeds the worktree's folder-trust acceptance in `~/.claude.json` (honoring `CLAUDE_CONFIG_DIR`) before launch, so the folder-trust dialog usually never appears.
The peek is the backstop: after every spawn, peek the pane within about 20 seconds; if a dialog is showing, accept it with `bin/fm-send.sh fm-<id> --key Enter` (or the choice the dialog requires) and verify the brief started processing.

## Root/sudo sandbox

Claude refuses `--dangerously-skip-permissions` when running as root unless `IS_SANDBOX` marks a sandbox, and herdr sanitizes the agent pane env, dropping it.
`bin/fm-spawn.sh` forwards `IS_SANDBOX` into the crewmate launch only when the launcher is root (`id -u` = 0); a non-root host (Mac, and most servers) never needs it and the launch stays exactly as before.

## Ghost text (prompt suggestions)

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain pane read cannot tell that ghost text apart from text a human typed, so left unhandled it makes firstmate misread an idle composer as holding pending input.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` (a per-launch env prefix in `bin/fm-spawn.sh`, scoped to firstmate-launched agents - it never touches the captain's global config), which disables the interactive ghost text at the source.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does NOT suppress the interactive composer ghost text (verified empirically on v2.1.186), so the env var is the correct control.
As defense in depth for any pane that flag cannot reach (such as the captain's own firstmate composer the away-mode daemon reads), the composer reader in `bin/fm-herdr-lib.sh` captures the pane WITH ANSI styling (`herdr pane read --format ansi`), drops dim/faint (SGR 2) runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only; `fm-peek` and every other human/LLM-facing read path stay plain `herdr pane read` with no escape codes.
