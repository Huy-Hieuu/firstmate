#!/usr/bin/env bash
# Apply the startup-memory entry grammar owned by the internal stow skill:
# `until` expiry, strike-through, sticky forget, and the git journal.
# Usage:
#   fm-memory.sh view <file>        print <file> without hidden entries
#   fm-memory.sh due                list hidden entries in the memory files
#   fm-memory.sh forget <term>      record <term>; list entries mentioning it
#   fm-memory.sh unforget <term>    drop <term> from the forgotten list
#   fm-memory.sh check <text>       exit 1 naming the forgotten term <text> mentions
#   fm-memory.sh commit <reason>    journal memory changes as one data/ git commit
#
# An entry is a top-level `- `, `* `, or `+ ` list line plus its indented
# continuation lines; any other line stands alone. An entry is hidden when it is
# struck (its text starts with `~~`), expired (it carries <!--u:YYYY-MM-DD-->
# dated before today), or forgotten (it mentions a recorded term as a whole
# word, case-insensitively). A standalone non-heading line is hidden only when
# forgotten. Headings and every other line print unchanged.
# The forgotten list is data/memory/forgotten.txt, one `YYYY-MM-DD<TAB>term`
# line per term; `#` lines are ignored.
# `due` scans data/captain.md, data/captain-shared.md, data/learnings.md and
# prints `<file>:<line>: <reason>: <first line>`; `forget` lists matches in
# those files and data/memory-archive.md the same way.
# `commit` stages only the memory files, data/memory-archive.md, and
# data/memory/, commits them as `memory: <reason>`, and never pushes; it is a
# no-op when nothing changed or when data/ is not its own git repository.
# FM_MEMORY_TODAY (YYYY-MM-DD) overrides today's local date.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FORGOTTEN="$DATA/memory/forgotten.txt"
TODAY="${FM_MEMORY_TODAY:-$(date +%Y-%m-%d)}"
MEMORY_FILES="captain.md captain-shared.md learnings.md"

usage() {
  sed -n '2,27{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-memory: %s\n' "$1" >&2
  exit 2
}

# scan <mode> <file> [term]: the one entry classifier. Modes: view prints kept
# lines, due lists hidden entries, match lists entries mentioning <term>.
scan() {
  local terms_file=$FORGOTTEN
  [ -f "$terms_file" ] || terms_file=/dev/null
  awk -v mode="$1" -v label="$2" -v today="$TODAY" -v only="$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')" \
      -v terms_file="$terms_file" '
    function hasword(s, t,   p, off, b, a) {
      off = 0
      while ((p = index(substr(s, off + 1), t)) > 0) {
        p += off
        b = (p == 1) ? "" : substr(s, p - 1, 1)
        a = substr(s, p + length(t), 1)
        if (b !~ /[a-z0-9_]/ && a !~ /[a-z0-9_]/) return 1
        off = p
      }
      return 0
    }
    function forgotten(s,   i) {
      s = tolower(s)
      if (only != "") return hasword(s, only) ? only : ""
      for (i = 1; i <= nterms; i++) if (hasword(s, terms[i])) return terms[i]
      return ""
    }
    function flush(   reason, t, d, i) {
      if (n == 0) return
      reason = ""
      if (mode == "view" || mode == "due") {
        if (bullet && unit[1] ~ /^[-*+][ \t]+~~/) reason = "struck"
        for (i = 1; i <= n && reason == ""; i++) {
          if (match(unit[i], /<!--u:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-->/)) {
            d = substr(unit[i], RSTART + 6, 10)
            if (d < today) reason = "expired " d
          }
        }
      }
      if (reason == "" && (bullet || unit[1] !~ /^#/)) {
        t = ""
        for (i = 1; i <= n; i++) t = t "\n" unit[i]
        t = forgotten(t)
        if (t != "") reason = "forgotten " t
      }
      if (mode == "check") {
        if (t != "") print t
      } else if (mode == "view") {
        if (reason == "") for (i = 1; i <= n; i++) print unit[i]
        else hidden++
      } else if (reason != "") {
        printf "%s:%d: %s: %s\n", label, start, reason, unit[1]
      }
      n = 0
    }
    BEGIN {
      while ((getline line < terms_file) > 0) {
        if (line ~ /^#/ || line !~ /\t/) continue
        sub(/^[^\t]*\t/, "", line)
        if (line != "") terms[++nterms] = tolower(line)
      }
    }
    {
      if (n > 0 && bullet && $0 ~ /^[ \t]+[^ \t]/) { unit[++n] = $0; next }
      flush()
      bullet = ($0 ~ /^[-*+][ \t]/)
      start = NR
      unit[++n] = $0
    }
    END {
      flush()
      if (mode == "view" && hidden > 0)
        printf "[fm-memory: %d expired, struck, or forgotten entr%s hidden; /stow archives or removes them]\n", hidden, (hidden == 1 ? "y" : "ies")
    }
  ' "$2"
}

each_memory_file() {  # <mode> <term> [extra file...]
  local mode=$1 term=$2 f
  shift 2
  for f in $MEMORY_FILES "$@"; do
    [ -f "$DATA/$f" ] && scan "$mode" "$DATA/$f" "$term" | sed "s|^$DATA/|data/|"
  done
  return 0
}

valid_term() {
  case "$1" in
    ''|*$'\t'*|*$'\n'*) die "a term must be one non-empty line without tabs" ;;
  esac
}

term_recorded() {
  [ -f "$FORGOTTEN" ] && awk -F '\t' -v t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" \
    '$0 !~ /^#/ && NF >= 2 && tolower(substr($0, index($0, "\t") + 1)) == t { found = 1 } END { exit !found }' "$FORGOTTEN"
}

forget() {
  valid_term "$1"
  if term_recorded "$1"; then
    printf 'already forgotten: %s\n' "$1"
  else
    mkdir -p "$DATA/memory"
    printf '%s\t%s\n' "$TODAY" "$1" >> "$FORGOTTEN"
    printf 'forgotten: %s\n' "$1"
  fi
  each_memory_file match "$1" memory-archive.md
}

unforget() {
  local tmp
  valid_term "$1"
  term_recorded "$1" || { printf 'not forgotten: %s\n' "$1"; return 0; }
  tmp="$FORGOTTEN.tmp.$$"
  awk -F '\t' -v t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" \
    '$0 ~ /^#/ || NF < 2 || tolower(substr($0, index($0, "\t") + 1)) != t' "$FORGOTTEN" > "$tmp"
  mv "$tmp" "$FORGOTTEN"
  printf 'unforgotten: %s\n' "$1"
}

check() {
  local hit
  hit=$(printf -- '- %s\n' "$1" | scan check - | head -n 1)
  [ -z "$hit" ] || { printf 'forgotten term: %s\n' "$hit"; return 1; }
}

commit() {
  local top paths=() p
  [ -n "$1" ] || die "commit needs a reason"
  if ! top=$(git -C "$DATA" rev-parse --show-toplevel 2>/dev/null) \
    || [ "$(cd "$top" && pwd -P)" != "$(cd "$DATA" && pwd -P)" ]; then
    printf 'fm-memory: no journal: %s is not its own git repository\n' "$DATA"
    return 0
  fi
  for p in $MEMORY_FILES memory-archive.md memory; do
    if [ -e "$DATA/$p" ] || git -C "$DATA" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      paths+=("$p")
    fi
  done
  [ "${#paths[@]}" -gt 0 ] || { printf 'fm-memory: no memory files\n'; return 0; }
  git -C "$DATA" add -A -- "${paths[@]}"
  if git -C "$DATA" diff --cached --quiet -- "${paths[@]}"; then
    printf 'fm-memory: no memory changes\n'
    return 0
  fi
  git -C "$DATA" commit -q -m "memory: $1" -- "${paths[@]}"
  printf 'fm-memory: journaled %s\n' "$(git -C "$DATA" log -1 --format='%h %s')"
}

case "${1:-}" in
  view) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; [ -f "$2" ] || die "no such file: $2"; scan view "$2" ;;
  due) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; each_memory_file due "" ;;
  forget) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; forget "$2" ;;
  unforget) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; unforget "$2" ;;
  check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; check "$2" ;;
  commit) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; commit "$2" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
