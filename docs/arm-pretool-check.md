# watcher-arm PreToolUse seatbelt

This document is the authoritative human-readable contract for the watcher-arm PreToolUse seatbelt.
`bin/fm-arm-command-policy.mjs` is the single decision owner and the sole owner of firstmate's shell command classification.
`bin/fm-arm-pretool-check.sh` is the Claude PreToolUse transport and output renderer.
This fork is Claude-only, so the transport speaks only Claude's PreToolUse contract; upstream firstmate multiplexes several harness transports here.

It is a sibling of the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`), which imports this file's shell tokenizer instead of duplicating shell lexing.

## Purpose and boundary

The watcher is firstmate's supervision backbone (AGENTS.md section 8): it must be armed as a standalone, harness-tracked background task via `bin/fm-watch-arm.sh`, never bundled into a compound command, and it must never be broad-killed with `pkill -f fm-watch`.
A watcher that is armed inside a pipeline, a substitution, or an `&`-list, or that is killed by a pattern that matches sibling homes' watchers, silently breaks supervision.
The seatbelt denies those command shapes before they run.

This guard classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, not a deliberately obfuscated bypass.
It fails **closed** on an unclassifiable command that still mentions a protected watcher script (unlike the cd-guard, which fails open), because a missed bad arm breaks supervision silently.

### Fork note: no checkpoint

Upstream firstmate also protects a Codex-only `bin/fm-watch-checkpoint.sh`, a bounded foreground watcher checkpoint for harnesses that cannot rely on background-task completion to wake the model.
This fork is Claude-only, and Claude arms the watcher as a tracked background task and is re-invoked on its exit, so there is no checkpoint concept.
The classifier therefore recognizes only two protected identities: `bin/fm-watch-arm.sh` (`arm`, a valid standalone) and `bin/fm-watch.sh` (`watch`, which must never be run directly).

## Deny reasons

The policy denies a protected watcher command that escapes a clean standalone call, each with a distinct reason code:

- `watcher-background` - the arm runs in an asynchronous list or through `nohup`/`disown` (`arm &`, `nohup arm`, `arm & disown`).
- `watcher-pipeline` - the arm participates in a pipeline (`arm | cat`, `arm 2>&1 | head`).
- `watcher-redirection` - the arm uses shell redirection (`arm >/tmp/out`).
- `watcher-bundled` - the arm is not the sole final command after approved setup nodes (`echo x; arm`, `true && arm`, `arm; echo y`).
- `watcher-nested` - the arm runs through a wrapper, substitution, process substitution, or `sh -c`/`bash -c` payload (`$(arm)`, `<(arm)`, `bash -lc 'arm &'`, an indirected `"$WATCHER" &`).
- `broad-watcher-kill` - a broad process kill targets the watcher (`pkill -f /bin/fm-watch.sh`, `sudo pkill ...`, `kill "$(pgrep -f ...)"`), including behind `command`/`sudo`/an absolute path.
- `watcher-direct` - `bin/fm-watch.sh` is run directly instead of arming with `bin/fm-watch-arm.sh`.
- `unclassifiable-protected-command` - unsupported or malformed shell syntax still mentions a protected watcher script (fail-closed).

## Allow: standalone arm, blessed setup, and mere mentions

The guard **allows**:

- A standalone verified arm: `bin/fm-watch-arm.sh`, `./bin/fm-watch-arm.sh --restart`, `exec bin/fm-watch-arm.sh`.
- A standalone arm preceded only by approved setup nodes connected with `;`, newline, or `&&`, where the arm is the sole final command: a `cd <dir>` and an `export VAR=val`.
  Upstream additionally blesses a `source config/x-mode.env` setup node (an X-mode startup form); this fork has no X-mode and no source-a-config-before-arming pattern, so only `cd` and `export` setup nodes are blessed here (tighter than upstream).
- Any command that merely mentions a protected script as data: a quoted reference (`rg -n 'fm-watch-arm.sh &' docs`, `git grep '...'`), a comment (`echo ok # arm &`), a `printf`/`echo` payload, or a search over docs and tests.
- Any command with no `fm-watch` token at all (fast-allowed by the prefilter before the Node policy runs).

## Transport, wiring, and fail-open

`bin/fm-arm-pretool-check.sh` is wired as a Claude `PreToolUse` hook on the `Bash` matcher in the tracked `.claude/settings.json`, invoked as `... fm-arm-pretool-check.sh --claude`, ahead of the cd-guard hook.
In stdin mode it reads `.tool_input.command` from the Claude PreToolUse payload; a `--command <cmd>` CLI mode drives the tests, and `--background` is accepted for transport parity as a no-op.
On a deny it writes a Claude deny object (`hookSpecificOutput.permissionDecision = "deny"`) to stderr and exits 2, keeping stdout empty.
A strict-superset prefilter fast-allows any command whose text cannot contain `fm-watch` even after byte normalization; the marker set that forces delegation to the classifier is coupled to the classifier's decoder set.
Transport uncertainty fails open (missing `jq`, missing Node, a missing policy owner, an invalid policy response); the classifier itself fails closed on an unclassifiable protected command.

## Tests

`tests/fm-arm-pretool-check.test.sh` drives a representative decision matrix (every deny reason plus the blessed-setup and reference allows) through the Claude CLI, plus reason-code mapping, the stdin transport, the fail-open path, the prefilter fast path, and the shared-tokenizer export the cd-guard imports.
The classifier is ported verbatim from upstream, so its exhaustive adversarial coverage is inherited.
