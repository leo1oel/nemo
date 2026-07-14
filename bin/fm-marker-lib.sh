#!/usr/bin/env bash
# fm-marker-lib.sh - the from-firstmate request marker.
#
# When the MAIN firstmate relays a work request to one of its SECONDMATES,
# bin/fm-send.sh prepends this marker to the message text. A secondmate is itself
# a firstmate running in its own home, so without a marker it treats every
# incoming fm-send line as if its captain typed it and answers
# CONVERSATIONALLY in its own chat. But the main firstmate never reads a
# secondmate's chat: the only main<-secondmate wakeup channel is the status file
# (charter escalation), optionally pointing to a doc for detail. A detailed
# chat-only reply therefore strands, unseen.
#
# The marker lets the secondmate tell its supervisor's request apart from a
# message the captain typed directly into its pane:
#
#   - marked   -> a from-firstmate request. Do the work, then respond via the
#                 STATUS/ESCALATION path (a status line for a terse result, or a
#                 doc plus a status pointer - the scout-report pattern - for a
#                 detailed one) so it surfaces to the main firstmate via the
#                 watcher signal. It MUST NOT respond only in chat.
#   - unmarked -> the captain typing directly. Stay conversational, exactly as
#                 before: authoritative captain intervention.
#
# This contract lives in the generated secondmate charter (bin/fm-brief.sh) so it
# travels with the live secondmate, and is summarized in AGENTS.md.
#
# Distinct from the afk daemon marker, on purpose.
# The away-mode daemon (bin/fm-supervise-daemon.sh) marks its daemon->firstmate
# escalations with a BARE leading unit separator (FM_INJECT_MARK, ASCII 0x1f).
# This from-firstmate marker instead uses U+2063 INVISIBLE SEPARATOR after its
# human-readable label. U+2063 has no normal keyboard keystroke (so a human can
# never forge it) but travels as UTF-8 text rather than a terminal control byte.
# The original ASCII 0x1f separator did NOT survive terminal input faithfully:
# feeding it to a real herdr composer (herdr 0.7.3) dropped the preceding label,
# so a secondmate received only the unmarked request and answered in chat where
# the main firstmate never sees it - the exact stranding this marker prevents.
# The afk contract keys on a LEADING 0x1f, while this marker begins with its
# label and contains no 0x1f, so the two cannot conflate: a secondmate's own afk
# machinery never mistakes a from-firstmate request for an internal daemon
# escalation, and vice versa. The visible label is what the secondmate's LLM
# reads in its pane; the U+2063 separator itself is invisible.
#
# Sourced by bin/fm-send.sh, bin/fm-brief.sh, and the tests. No side effects on
# source. set -u / set -e safe.

# The label field: human-readable, greppable, and distinctive enough that the
# captain would not type it by hand. This is the part the secondmate's LLM reads.
FM_FROMFIRST_LABEL='[fm-from-firstmate]'

# The full marker fm-send prepends to a from-firstmate request: the label, then
# U+2063 INVISIBLE SEPARATOR (UTF-8 e2 81 a3) as the untypable field separator,
# which - unlike the raw 0x1f control byte - survives a herdr composer intact.
# The request text follows the separator.
FM_FROMFIRST_SEPARATOR=$'\xE2\x81\xA3'
FM_FROMFIRST_MARK="${FM_FROMFIRST_LABEL}${FM_FROMFIRST_SEPARATOR}"

# fm_message_from_firstmate: 0 (true) if <message> carries the from-firstmate
# marker - it begins with the label immediately followed by U+2063 - and 1
# otherwise. U+2063 has no normal keyboard keystroke, so a captain-typed message,
# even one that happens to start with the label text alone, is never matched.
fm_message_from_firstmate() {  # <message>
  case "$1" in
    "$FM_FROMFIRST_MARK"*) return 0 ;;
  esac
  return 1
}
