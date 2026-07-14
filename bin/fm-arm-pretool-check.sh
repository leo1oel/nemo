#!/usr/bin/env bash
# Claude PreToolUse transport for the watcher-arm command policy.
#
# A firstmate must arm the watcher as a standalone verified harness call, never
# bundled into a compound command, piped, redirected, backgrounded, nested in a
# wrapper/substitution, run directly as bin/fm-watch.sh, or broad-killed with
# `pkill -f fm-watch`. bin/fm-arm-command-policy.mjs is the sole owner of shell
# classification, the blessed setup tree, and deny reason codes. This wrapper
# only acquires the Claude PreToolUse payload, discovers the active roots,
# invokes that policy, and renders the deny response. It never executes,
# sources, evaluates, or expands the submitted command.
# See docs/arm-pretool-check.md for the complete contract and validation record.
#
# This fork is Claude-only, so the wrapper speaks only Claude's PreToolUse
# contract (upstream firstmate multiplexes Grok/Codex/OpenCode/Pi transports
# here, and also protects a Codex-only fm-watch-checkpoint.sh; neither applies).
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh [--claude]
#   bin/fm-arm-pretool-check.sh --command '<cmd>'   # CLI mode (tests)
#
# Stdin mode extracts .tool_input.command from the Claude PreToolUse payload.
# --claude is accepted for hook-command compatibility and is a no-op (Claude is
# the only rendering). --background is accepted for transport parity and is not
# itself a policy signal.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY - exit 2 with a Claude-shaped deny object on stderr (stdout stays empty,
#          which Claude requires on deny).
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
set -u

CMD=""
CMD_SET=0

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude]

With no --command, reads a Claude PreToolUse JSON payload on stdin
(.tool_input.command).
Exits 0 to allow and 2 to deny.
The deny reason is written to stderr as a Claude PreToolUse deny object.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --background)
      # Accepted for transport parity; harness-native tracked background
      # execution is not itself a policy signal.
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      shift 2
      ;;
    --background=*)
      shift
      ;;
    --claude)
      # Accepted for hook-command compatibility; Claude is the only rendering.
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification semantics).
# Every protected watcher execution and every broad watcher kill resolves to the
# fm-watch byte sequence AFTER the classifier's byte normalization, so a command
# that cannot contain fm-watch even after that normalization can never be a
# deniable watcher command and is fast-allowed without the Node policy owner.
# We mirror the classifier's cheapest byte transforms here (drop line-
# continuation and escape backslashes, quotes, and newlines) so obfuscated
# protected paths such as fm-watc\<newline>h-arm.sh or fm-"watch"-arm.sh still
# delegate. Stripping only these non-alphanumeric bytes can never destroy an
# existing fm-watch run.
#
# The fast path may allow ONLY when BOTH hold: (a) the stripped/normalized text
# lacks the fm-watch watcher substring, AND (b) the raw command carries no
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"..."), both of which the classifier
# decodes and can therefore reconstruct fm-watch from bytes this cheap byte
# strip cannot. This marker set is COUPLED to the classifier's decoder set in
# bin/fm-arm-command-policy.mjs: adding any new quote/expansion form the
# classifier decodes REQUIRES extending this marker set in the same change, or
# the prefilter stops being a strict superset. Otherwise the command always
# delegates to the classifier - the single owner of every decision.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *fm-watch*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
ACTIVE_HOME=${FM_HOME:-$ROOT}
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" --root "$ROOT" --home "$ACTIVE_HOME" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
