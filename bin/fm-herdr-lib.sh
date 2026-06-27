#!/usr/bin/env bash
# fm-herdr-lib.sh — shared herdr pane primitives for firstmate.
#
# ONE source of truth for: composer-empty (pending-input) detection, a
# verify-and-retry-Enter submit, and pane existence + agent_status busy
# detection. Sourced by the away-mode daemon (bin/fm-supervise-daemon.sh),
# bin/fm-send.sh, and bin/fm-crew-state.sh so the composer/submit/busy logic
# cannot drift between them. herdr-only — no tmux, no treehouse.
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
# Ghost text (parity with upstream #59): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text (ANSI SGR 2) inside an otherwise-empty composer.
# A plain read cannot tell it apart from text a human typed, so an idle pane reads
# as holding pending input and the away-mode daemon defers injection. fm-spawn
# disables it at the source (CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false) for every
# firstmate-launched agent; as defense in depth for any pane that flag cannot reach
# (e.g. the captain's own pane), the composer reader captures WITH ANSI styling
# (herdr pane read --format ansi), drops dim/faint runs (fm_herdr_strip_ghost), and
# decides on what is left, so ghost/placeholder text never counts as real input.
# The styled capture is consumed internally and parsed into a verdict here; it is
# NEVER surfaced (fm-peek and every human/LLM-facing path stay plain), so no
# escape-laden pane bulk reaches the captain.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer AFTER
# dim-ghost and structural border stripping (forces the empty verdict on whatever
# idle glyph a harness uses). FM_BUSY_REGEX overrides the busy-footer fallback set.
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

# fm_herdr_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from the
# captured composer text, then drop any remaining escape sequences, leaving only
# the plain, normal-intensity text — the text a human actually typed. Dim/faint
# runs are ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion)
# that fills an otherwise-empty composer and must never read as pending input.
# Reads the styled capture on stdin (from `herdr pane read --format ansi`) and
# prints plain text on stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs
# (e.g. ❯) and dim runs alike pass through or drop intact without locale-dependent
# character classes. A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run;
# codes are processed left to right within a sequence so "ESC[0;2m" (reset then
# dim) reads as dim. Normal-intensity color (SGR 38/48/58 payloads) is preserved,
# so SGR-colored typed input still counts.
fm_herdr_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
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
  # Capture WITH ANSI styling so dim/faint ghost text can be dropped; this styled
  # read is internal only (fm-peek and human-facing reads stay plain).
  out=$(herdr pane read "$h" --source visible --lines 25 --format ansi 2>/dev/null) || { printf 'unknown'; return 0; }
  [ -n "$out" ] || { printf 'unknown'; return 0; }
  # Drop dim/faint ghost runs and any remaining escape sequences, leaving plain,
  # normal-intensity text. Everything below then operates on plain text exactly as
  # before, so the border-aware structural detection is unchanged.
  out=$(printf '%s\n' "$out" | fm_herdr_strip_ghost)
  [ -n "$out" ] || { printf 'empty'; return 0; }
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

# --- pane existence + agent_status busy detection ---------------------------
# Single source of truth for "does this pane exist" and "is its agent working",
# shared by the away-mode daemon and the crew-state helper. All take a resolved
# handle (a herdr pane id); window-name → handle resolution stays with the caller.

# fm_herdr_pane_exists: 0 if the herdr pane currently exists. Replaces the tmux
# `display-message -p '#{pane_id}'` existence probe.
fm_herdr_pane_exists() {  # <handle>
  [ -n "${1:-}" ] || return 1
  herdr pane get "$1" >/dev/null 2>&1
}

# fm_herdr_pane_agent_status: herdr agent_status for a pane (set by the claude
# integration). Empty if the integration is absent or the pane is gone. Parsed
# with grep so no python dependency is introduced.
fm_herdr_pane_agent_status() {  # <handle>
  herdr pane get "$1" 2>/dev/null | grep -o '"agent_status":"[^"]*"' | head -1 | cut -d'"' -f4
}

# fm_herdr_pane_is_busy: 0 if the pane's agent is currently working. PRIMARY
# signal is herdr's agent_status, which covers BOTH the thinking spinner and
# tool-run phases — the busy footer alone misses thinking (Claude shows
# "… (thinking with <effort> effort)", not "esc to interrupt"). Falls back to the
# footer regex only when agent_status is unavailable (integration not installed).
# FM_BUSY_REGEX overrides the fallback set.
fm_herdr_pane_is_busy() {  # <handle>
  local h=$1 st tail40
  [ -n "$h" ] || return 1
  st=$(fm_herdr_pane_agent_status "$h")
  case "$st" in
    working) return 0 ;;
    idle|blocked|done) return 1 ;;
  esac
  # agent_status unknown/empty -> footer-regex fallback.
  tail40=$(herdr pane read "$h" --source visible --lines 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_HERDR_BUSY_REGEX_DEFAULT}"
}
