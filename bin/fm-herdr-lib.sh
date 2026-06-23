#!/usr/bin/env bash
# fm-herdr-lib.sh — shared herdr pane primitives for firstmate.
#
# ONE source of truth for: composer-empty (pending-input) detection and a
# verify-and-retry-Enter submit. Sourced by both the away-mode daemon
# (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit logic
# cannot drift between the two. herdr-only — no tmux, no treehouse.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("❯ ") at the start of a line as the empty
# composer. Claude can draw its input box WITH box-drawing borders ("│ > … │"),
# so an idle bordered composer read as "pending input" and the away-mode daemon
# deferred 100% of escalations for 9.5 hours with no escape. The detector below
# STRIPS the box borders before deciding, so a bordered-but-empty composer is
# correctly seen as empty. The same corrected detector backs the submit
# acknowledgement (a submit "landed" iff the composer is empty afterward),
# fixing the parallel false "Enter swallowed".
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer AFTER
# structural border stripping (forces the empty verdict on whatever idle glyph a
# harness uses). FM_BUSY_REGEX overrides the busy-footer fallback set.
#
# herdr exposes no cursor position (no tmux `#{cursor_y}`), so the composer is
# located structurally: the lowest rendered line that, after border stripping,
# begins with a prompt glyph (❯ or >). Claude renders the model/effort and
# bypass-permission FOOTERS BELOW the composer, so the composer is NOT the last
# visible line — a naive tail-1 read would see a footer, never the prompt.
#
# All functions are `set -u` and `set -e` safe (guarded herdr calls, explicit
# returns) so they can be sourced into either context.

# Busy-footer FALLBACK regex (used only when herdr's agent_status is
# unavailable). Covers the tool-run footer ("esc to interrupt") AND the thinking
# spinner line ("… (thinking with <effort> effort)"), which the bare "esc to
# interrupt" misses. Primary busy detection is agent_status, in the daemon.
FM_HERDR_BUSY_REGEX_DEFAULT='esc to interrupt|thinking with'

# Box-drawing / pipe glyphs Claude (and other harnesses) use to draw the
# composer border. Stripped from a candidate line before deciding empty vs
# pending. Literal-string substitution (bash 3.2 safe, locale-independent — no
# \u escapes, no multibyte character classes).
_fm_strip_box_borders() {  # <line> -> line with box borders + surrounding ws removed
  local s=$1
  s=${s//│/}      # U+2502 light vertical (claude composer)
  s=${s//┃/}      # U+2503 heavy vertical
  s=${s//║/}      # U+2551 double vertical
  s=${s//|/}      # ASCII pipe
  # Trim surrounding whitespace.
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# fm_herdr_composer_state: classify the composer of <handle> as
#   empty   — no pending input (blank box, a bare prompt glyph, or a busy
#             footer landed on the prompt line). Safe to inject; also the
#             positive acknowledgement that a submit landed.
#   pending — real, unsubmitted text on the composer line (a human mid-typing,
#             or a previous injection whose Enter was swallowed). Defer / retry.
#   unknown — the pane could not be read (herdr error). The caller decides.
#
# Border-aware: each candidate line is stripped of its composer box borders
# FIRST, so a bordered-but-empty composer ("│ > │") reads as empty, and a
# bordered prompt with text ("│ > hi │") reads as pending.
fm_herdr_composer_state() {  # <handle> -> empty|pending|unknown
  local h=$1 out line stripped content lc
  out=$(herdr pane read "$h" --source visible --lines 25 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -n "$out" ] || { printf 'unknown'; return 0; }
  # Find the composer line: the LOWEST rendered line that, after border
  # stripping, begins with a prompt glyph (❯ or >). Conversation history is
  # above it; footers (model/effort, bypass) render below it.
  line=""
  while IFS= read -r lc; do
    stripped=$(_fm_strip_box_borders "$lc")
    case "$stripped" in
      '❯'*|'>'*) line=$lc ;;
    esac
  done <<EOF
$out
EOF
  # No prompt line found at all → composer not rendered (or fully empty box).
  # Treat as empty: there is no unsubmitted text we could be stepping on.
  [ -n "$line" ] || { printf 'empty'; return 0; }
  # Strip the box borders, then the leading prompt glyph + its padding.
  stripped=$(_fm_strip_box_borders "$line")
  content=$(printf '%s' "$stripped" | sed -E 's/^(❯|>)[[:space:]]*//; s/[[:space:]]*$//')
  # Nothing left after the prompt glyph = empty composer (idle).
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # FM_COMPOSER_IDLE_RE override: forces the empty verdict on a harness-specific
  # idle token, AFTER border stripping.
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$content" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # A bare secondary prompt glyph left over is still an empty composer.
  case "$content" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the prompt line is not pending input.
  if printf '%s' "$content" | grep -qiE "${FM_BUSY_REGEX:-$FM_HERDR_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_herdr_input_pending: 0 (pending) if the composer holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here, and
# the inject path independently confirms a submit before clearing its buffer).
fm_herdr_input_pending() {  # <handle>
  [ "$(fm_herdr_composer_state "$1")" = pending ]
}

# fm_herdr_submit_enter_core: submit an already-typed composer with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
# <enter-fn> sends ONE Enter to <handle> (injected so the lib stays free of any
# direct herdr send-keys call site / backend coupling).
fm_herdr_submit_enter_core() {  # <handle> <retries> <enter-sleep> <enter-fn>
  local h=$1 retries=$2 sleep_s=$3 enter_fn=$4 i=0 state
  while :; do
    "$enter_fn" "$h" || true
    sleep "$sleep_s"
    state=$(fm_herdr_composer_state "$h")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}
