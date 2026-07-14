# cd-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the cd-guard PreToolUse seatbelt.
`bin/fm-cd-command-policy.mjs` is the single decision owner.
`bin/fm-cd-pretool-check.sh` is the Claude PreToolUse transport, primary-checkout scope, and output renderer.
This fork is Claude-only, so the transport speaks only Claude's PreToolUse contract; upstream firstmate multiplexes several harness transports here.

It is one of a family of primary-session guards that share the same hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the turn-end supervision guard (`bin/fm-turnend-guard.sh`).

## Purpose and boundary

The primary firstmate shell persists its working directory across tool calls.
A stray persistent top-level `cd projects/<clone>` therefore silently relocates the shell, so the next firstmate-owned command - a backlog write, an `fm-*` lifecycle call, `tasks-axi` - runs inside a project clone instead of the home.
The seatbelt denies exactly that command shape - a cwd change that persists to the primary shell - before it runs.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, the same as the watcher-arm seatbelt: an accidental bare `cd projects/foo`, not a deliberately obfuscated bypass.

## Scope: plain firstmate checkouts only

The guard fires only in a plain firstmate checkout where git-dir equals git-common-dir.
It is a silent no-op (exit 0, no output) everywhere else, so it never interferes with a crewmate or scout that legitimately works inside its own herdr task worktree.

A plain, non-worktree checkout has `git rev-parse --git-dir` equal to `git rev-parse --git-common-dir`.
A crewmate or scout task worktree - the shape `bin/fm-spawn.sh` always hands out - is a linked git worktree where the two differ, so the guard is inert there.
The checkout must also carry `AGENTS.md` and `bin/`, and any failure to confirm the primary is treated as inert, never as a block.

The cd-guard does not inspect `.fm-secondmate-home`.
It therefore applies in a secondmate home whose git-dir equals git-common-dir; a secondmate home that is itself a linked herdr worktree is inert under the same linked-worktree test, as are secondmate child crew and scout worktrees.

## Block vs allow

The discriminator is persistence to the parent shell's cwd, not the mere presence of the token `cd`.

The guard **blocks** a `cd`, `pushd`, or `popd` builtin that runs in an executed top-level position in the parent shell, because such a command persistently changes the primary shell's own working directory.
This covers a bare `cd projects/foo`, `cd ..`, `cd`, `cd -`, an absolute `cd /some/path` (still a persistent relocation of the parent shell), `pushd <dir>`, `popd`, a leading-assignment form such as `X=1 cd foo`, quoted or escaped command-word fragments that cook to a bare builtin (`"cd" x`, `c'd' x`, `c\d x`, an ANSI-C `$'\143d' x`), and any list form where the builtin runs in the parent shell (`cd x && cmd`, `cmd; cd x`, `cmd || cd x`, `command cd x`, `command -p cd x`, `command -- cd x`, `builtin cd x`, `command builtin cd x`, `cd x >/dev/null`, and newline-separated lists).

The guard **allows** everything else, including these safe scoped forms that must never be blocked:

- A command that reaches a target without changing the shell's own cwd: `git -C <dir> ...`, `make -C <dir> ...`, `env -C <dir> ...`, or an absolute path on the command itself.
- A directory change that does not persist to the parent shell: a subshell `(cd x && ...)`, a `bash -c 'cd ...'` / `sh -c` / `zsh -c` payload, a `find ... -execdir` runner, a pipeline stage (`cd x | cmd`), or a backgrounded `cd x &`.
- A `cd` behind a forking or exec'ing wrapper (`env`, `sudo`, `nohup`, `timeout`, `gtimeout`, `exec`), which runs in a child and never persists.
- A path-qualified external command named `cd`, `command`, or `builtin` (`./cd`, `/usr/bin/cd`, `./command`, `./builtin`), because it runs as a child process and cannot change the parent shell's cwd.
- A `command` query such as `command -v cd`, `command -V cd`, or a clustered `command -pv cd`, because it reports command resolution without executing the named builtin.
- The token `cd` appearing as data: quoted text (`echo "cd projects/foo"`), a comment, a substring of another word (`cdk`, `abcd`), a `printf` payload, or any later argument word.

An absolute-path `cd` is blocked on purpose: the ALLOW carve-out for absolute paths is for commands that address a target by absolute path, not for `cd`, which relocates the shell itself regardless of its argument.
Blocking a top-level `cd` is safe in the strong sense: the guard's steady state is "always at the home", so a return-to-home `cd` is redundant rather than necessary, and the block never causes a wrong-directory write.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every obfuscated bypass:

- A `cd` reconstructed by a command substitution (`$(echo c)d x`) or hidden inside a brace group (`{ cd x; }`) is not blocked; a false block on brace expansion `{cd,foo}` would be worse than the missed exotic bypass.
- Malformed or untokenizable syntax fails open (allow). Unlike the watcher-arm seatbelt, which fails closed on unclassifiable protected commands, the cd-guard prioritizes zero false blocks over catching a malformed bypass, because a blocked backlog write is a correctness hazard while a missed exotic `cd` is only the pre-existing status quo.

## Transport, wiring, and fail-open

`bin/fm-cd-pretool-check.sh` is wired as a Claude `PreToolUse` hook on the `Bash` matcher in the tracked `.claude/settings.json`, invoked as `... fm-cd-pretool-check.sh --claude`.
In stdin mode it reads `.tool_input.command` from the Claude PreToolUse payload; a `--command <cmd>` CLI mode drives the tests.
On a block it writes a Claude deny object (`hookSpecificOutput.permissionDecision = "deny"`) to stderr and exits 2, keeping stdout empty, which Claude requires on deny.
A strict-superset prefilter fast-allows any command whose text cannot contain `cd`/`pushd`/`popd` even after byte normalization, so the Node policy owner runs only for candidate commands.
Every uncertainty fails open (exit 0, allow): malformed or empty stdin, missing `jq`, missing Node, a missing policy owner, an invalid policy response, or a non-primary checkout.

`bin/fm-cd-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification, so the cd-guard never duplicates shell lexing.

## Tests

`tests/fm-cd-pretool-check.test.sh` drives the full block/allow decision matrix through the Claude CLI, plus the stdin transport, the primary-checkout scoping (a linked worktree is inert), the fail-open path, and the prefilter fast path.
