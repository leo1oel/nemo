#!/usr/bin/env bash
# Resolve a project's delivery mode from the data/projects.md registry.
# Prints one word to stdout: "<mode>", one of no-mistakes|direct-PR.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes (default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode>
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#
# An unknown/missing project or unknown mode falls back to "no-mistakes" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh <project-name>
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Operational data comes from the active home: secondmates run this from their own
# FM_HOME, so honor FM_HOME / FM_DATA_OVERRIDE rather than always reading FM_ROOT.
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes" >&2
  echo "no-mistakes"
  exit 0
fi

# awk emits "<mode>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "") mode = a[1];
    }
    print mode; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes" >&2
  echo "no-mistakes"
  exit 0
fi

mode=$parsed
case "$mode" in
  no-mistakes|direct-PR) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes" >&2; mode=no-mistakes ;;
esac
echo "$mode"
