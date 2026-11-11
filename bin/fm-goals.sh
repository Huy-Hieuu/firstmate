#!/usr/bin/env bash
# fm-goals.sh - read the captain's goals from data/goals.md.
#
# data/goals.md is captain-written; firstmate reads it and never invents its
# contents. docs/configuration.md "Captain goals" owns the file's schema.
#
# Usage:
#   fm-goals.sh [list]
#       Print one "<area><TAB><goal>" line per goal, in file order. A goal is a
#       top-level `- ` or `* ` bullet; its area is the nearest preceding `## `
#       heading, or "general" before any heading. An absent file prints one
#       notice on stderr and nothing on stdout, and exits 0.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
GOALS="$DATA/goals.md"

case "${1:-list}" in
  list) [ "$#" -le 1 ] || { echo "usage: fm-goals.sh [list]" >&2; exit 2; } ;;
  -h|--help|help)
    sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "usage: fm-goals.sh [list]" >&2; exit 2 ;;
esac

if [ ! -f "$GOALS" ]; then
  echo "fm-goals: no goals recorded (data/goals.md absent)" >&2
  exit 0
fi

awk '
  BEGIN { area = "general" }
  /^## / { area = substr($0, 4); sub(/[ \t]+$/, "", area); next }
  /^[-*] / { goal = substr($0, 3); gsub(/\t/, " ", goal); sub(/[ \t]+$/, "", goal); if (goal != "") print area "\t" goal }
' "$GOALS"
