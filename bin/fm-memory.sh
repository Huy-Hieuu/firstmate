#!/usr/bin/env bash
# Apply the memory grammar owned by the internal stow skill: `until` expiry,
# strike-through, sticky forget, the git journal, topic and person files with
# their alias index, and quote-gated capture.
# Usage:
#   fm-memory.sh view <file>        print <file> without hidden entries
#   fm-memory.sh due                list hidden entries in the memory files
#   fm-memory.sh entries            list live entries in the memory files
#   fm-memory.sh forget <term>      record <term>; list entries mentioning it
#   fm-memory.sh unforget <term>    drop <term> from the forgotten list
#   fm-memory.sh check <text>       exit 1 naming the forgotten term <text> mentions
#   fm-memory.sh commit <reason>    journal memory changes as one data/ git commit
#   fm-memory.sh new topic|person <slug> [<alias>...]   create a topic or person file
#   fm-memory.sh index [--all]      the alias index of topic and person files
#   fm-memory.sh load <text>        print every topic or person file <text> names
#   fm-memory.sh capture [--until YYYY-MM-DD] <file> <source> <quote> <fact>
#                                   append <fact> to <file> with its evidence
#
# An entry is a top-level `- `, `* `, or `+ ` list line plus its indented
# continuation lines; any other line stands alone. An entry is hidden when it is
# struck (its text starts with `~~`), expired (it carries <!--u:YYYY-MM-DD-->
# dated before today), or forgotten (it mentions a recorded term as a whole
# word, case-insensitively). A standalone non-heading line is hidden only when
# forgotten. Headings and every other line print unchanged.
# The forgotten list is data/memory/forgotten.txt, one `YYYY-MM-DD<TAB>term`
# line per term; `#` lines are ignored.
#
# Memory files are the startup files data/captain.md, data/captain-shared.md,
# and data/learnings.md, plus the on-demand topic files data/memory/<slug>.md
# and person files data/people/<slug>.md, where <slug> matches
# [a-z0-9][a-z0-9-]* and is the stable key. A topic or person file opens with a
# front matter block, `---` through the next `---`, of `key: value` lines:
# `aliases:` is a comma list of other names it goes by, and a person file also
# carries `role:`, `org:`, `channel:`, and `timezone:`. Its body uses the same
# entry grammar. `index` prints one line per file (at most 40 lines and 2000
# characters unless --all) for the session-start digest; `load` prints, through
# `view`, each file whose slug or alias <text> mentions as a whole word.
# `due` and `entries` print `<file>:<line>: <reason>: <first line>` and
# `<file>:<line><TAB><first line>` over every memory file; `forget` lists
# matches in them and data/memory-archive.md like `due`.
#
# `capture` is the one way a new entry is written. <file> is captain.md,
# captain-shared.md (refused in a secondmate home), learnings.md,
# memory/<slug>.md, or people/<slug>.md, the last two made by `new` first.
# <quote> is evidence copied verbatim: the captain's own words, or one line of
# <source>. <source> is `chat` for the captain's message in this session, or a
# file under FM_HOME (or absolute) that must contain <quote> verbatim. The
# capture is refused, writing nothing, when the quote is empty, multi-line,
# longer than 300 characters, or a question (ends with `?`); when a number,
# path, or URL in <fact> is missing from <quote>; or when either mentions a
# forgotten term. It appends `- <fact>` with today's `aging` marker in
# learnings.md (no marker elsewhere) and any `until` marker, then the
# continuation line `  > "<quote>" (<source>, <today>)`.
#
# `commit` stages only the startup memory files, data/memory-archive.md,
# data/memory/, and data/people/, commits them as `memory: <reason>`, and never
# pushes; it is a no-op when nothing changed or when data/ is not its own git
# repository.
# FM_MEMORY_TODAY (YYYY-MM-DD) overrides today's local date.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FORGOTTEN="$DATA/memory/forgotten.txt"
TODAY="${FM_MEMORY_TODAY:-$(date +%Y-%m-%d)}"
MEMORY_FILES="captain.md captain-shared.md learnings.md"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

usage() {
  sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-memory: %s\n' "$1" >&2
  exit 2
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The whole-word matcher every awk program here shares: <t> occurs in <s> with
# no letter, digit, or underscore on either side. Both are lowercase.
# shellcheck disable=SC2016 # An awk program.
AWK_HASWORD='
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
  }'

# scan <mode> <file> [term]: the one entry classifier. Modes: view prints kept
# lines, due lists hidden entries, list lists kept entries, match lists entries
# mentioning <term>, check prints the first forgotten term.
scan() {
  local terms_file=$FORGOTTEN
  [ -f "$terms_file" ] || terms_file=/dev/null
  awk -v mode="$1" -v label="$2" -v today="$TODAY" -v only="$(lower "${3:-}")" \
      -v terms_file="$terms_file" "$AWK_HASWORD"'
    function forgotten(s,   i) {
      s = tolower(s)
      if (only != "") return hasword(s, only) ? only : ""
      for (i = 1; i <= nterms; i++) if (hasword(s, terms[i])) return terms[i]
      return ""
    }
    function flush(   reason, t, d, i) {
      if (n == 0) return
      reason = ""
      if (mode == "view" || mode == "due" || mode == "list") {
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
      } else if (mode == "list") {
        if (reason == "" && bullet) printf "%s:%d\t%s\n", label, start, unit[1]
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

# topic_files: the topic and person files, relative to data/, sorted.
topic_files() {
  local f
  for f in "$DATA"/memory/*.md "$DATA"/people/*.md; do
    [ -f "$f" ] && printf '%s\n' "${f#"$DATA"/}"
  done
  return 0
}

each_memory_file() {  # <mode> <term> [extra file...]
  local mode=$1 term=$2 f
  shift 2
  for f in $MEMORY_FILES $(topic_files) "$@"; do
    [ -f "$DATA/$f" ] && scan "$mode" "$DATA/$f" "$term" | sed "s|^$DATA/|data/|"
  done
  return 0
}

# catalog: one `<kind>\t<slug>\t<path>\t<aliases>\t<details>` line per topic or
# person file, read from its front matter.
catalog() {
  local files
  files=$(topic_files)
  [ -n "$files" ] || return 0
  # shellcheck disable=SC2016 # An awk program.
  (cd "$DATA" && printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk '
    function emit(   kind, slug) {
      kind = (path ~ /^people\//) ? "person" : "topic"
      slug = path; sub(/^[^\/]*\//, "", slug); sub(/\.md$/, "", slug)
      printf "%s\t%s\t%s\t%s\t%s\n", kind, slug, path, al, det
    }
    FNR == 1 {
      if (path != "") emit()
      path = FILENAME; al = ""; det = ""; infm = ($0 == "---")
      if (infm) next
    }
    infm {
      if ($0 == "---") { infm = 0; next }
      k = $0; sub(/[ \t]*:.*/, "", k); v = $0
      if (!sub(/^[^:]*:[ \t]*/, "", v)) next
      gsub(/[ \t]+$/, "", v)
      if (k == "aliases") al = v
      else if (v != "" && (k == "role" || k == "org" || k == "channel" || k == "timezone"))
        det = det (det == "" ? "" : "; ") v
      next
    }
    END { if (path != "") emit() }
  ')
}

valid_slug() {
  case "$1" in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

new_file() {  # <topic|person> <slug> [alias...]
  local kind=$1 slug=$2 dir file aliases='' a
  case "$kind" in topic) dir=memory ;; person) dir=people ;; *) usage >&2; exit 2 ;; esac
  valid_slug "$slug" || die "a slug matches [a-z0-9][a-z0-9-]* (at most 64 characters): $slug"
  shift 2
  file="$DATA/$dir/$slug.md"
  [ ! -e "$file" ] || die "already exists: data/$dir/$slug.md"
  for a in "$@"; do
    case "$a" in ''|*,*|*$'\n'*) die "an alias is one non-empty line without commas: $a" ;; esac
    aliases="${aliases:+$aliases, }$a"
  done
  mkdir -p "$DATA/$dir"
  {
    printf -- '---\naliases: %s\n' "$aliases"
    [ "$kind" = topic ] || printf 'role: \norg: \nchannel: \ntimezone: \n'
    printf -- '---\n# %s\n' "$slug"
  } > "$file"
  printf 'created: data/%s/%s.md\n' "$dir" "$slug"
}

index_cmd() {
  local all=0 lines
  case "${1:-}" in '') ;; --all) all=1 ;; *) usage >&2; exit 2 ;; esac
  lines=$(catalog | awk -F '\t' '{
      s = "- " $1 " " $2
      if ($4 != "") s = s ": " $4
      if ($5 != "") s = s " (" $5 ")"
      print s
    }' | scan view - | grep -v '^\[fm-memory:' || true)
  # shellcheck disable=SC2016 # Literal backquotes.
  printf 'Topic and person memory; `bin/fm-memory.sh load "<text>"` prints each file the text names, and `bin/fm-recall.sh <words>` searches older notes and reports.\n'
  [ -n "$lines" ] || { printf '(no topic or person files yet)\n'; return 0; }
  printf '%s\n' "$lines" | awk -v all="$all" '
    all || (NR <= 40 && used + length($0) + 1 <= 2000) { print; used += length($0) + 1; next }
    { more++ }
    END { if (more) printf "- and %d more: bin/fm-memory.sh index --all\n", more }'
}

load() {
  local paths p
  paths=$(catalog | awk -F '\t' -v text="$(lower "$1")" "$AWK_HASWORD"'
    {
      names = $2 "," $4
      s = $2; gsub(/-/, " ", s); names = names "," s
      k = split(names, a, ",")
      for (i = 1; i <= k; i++) {
        t = tolower(a[i]); gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t != "" && hasword(text, t)) { print $3; next }
      }
    }')
  [ -n "$paths" ] || { printf 'no topic or person file is named in the text\n'; return 0; }
  printf '%s\n' "$paths" | while IFS= read -r p; do
    printf '== data/%s ==\n' "$p"
    scan view "$DATA/$p"
  done
}

valid_term() {
  case "$1" in
    ''|*$'\t'*|*$'\n'*) die "a term must be one non-empty line without tabs" ;;
  esac
}

term_recorded() {
  [ -f "$FORGOTTEN" ] && awk -F '\t' -v t="$(lower "$1")" \
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
  awk -F '\t' -v t="$(lower "$1")" \
    '$0 ~ /^#/ || NF < 2 || tolower(substr($0, index($0, "\t") + 1)) != t' "$FORGOTTEN" > "$tmp"
  mv "$tmp" "$FORGOTTEN"
  printf 'unforgotten: %s\n' "$1"
}

forgotten_in() {  # <text>: the first forgotten term <text> mentions, or nothing
  printf -- '- %s\n' "$1" | scan check - | head -n 1
}

check() {
  local hit
  hit=$(forgotten_in "$1")
  [ -z "$hit" ] || { printf 'forgotten term: %s\n' "$hit"; return 1; }
}

refuse() {
  printf 'fm-memory: capture refused: %s\n' "$1" >&2
  exit 1
}

capture() {
  local until='' target source quote fact file src marker missing hit
  if [ "${1:-}" = --until ]; then
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    until=$2
    shift 2
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) die "--until takes YYYY-MM-DD: $until" ;;
    esac
  fi
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
  target=$1 source=$2 quote=$3 fact=$4
  case "$target" in
    captain.md|learnings.md) ;;
    captain-shared.md)
      ! fm_root_is_secondmate_home "$FM_HOME" \
        || refuse "data/captain-shared.md is read-only in a secondmate home; route the fact to the primary home" ;;
    memory/*.md|people/*.md)
      file=${target#*/}
      valid_slug "${file%.md}" && [ -f "$DATA/$target" ] \
        || die "no such topic or person file: data/$target (create it with: fm-memory.sh new topic|person <slug>)" ;;
    *) die "<file> is captain.md, captain-shared.md, learnings.md, memory/<slug>.md, or people/<slug>.md" ;;
  esac
  file="$DATA/$target"
  case "$fact" in
    ''|*$'\n'*) refuse "the fact must be one non-empty line" ;;
    '~~'*) refuse "a new fact cannot be struck" ;;
  esac
  case "$quote" in
    ''|*$'\n'*) refuse "the quote must be one non-empty line copied verbatim" ;;
    *'?'|*'? ') refuse "the quote is a question, not a statement" ;;
  esac
  [ "${#quote}" -le 300 ] || refuse "the quote is longer than 300 characters; copy only the span that states the fact"
  if [ "$source" != chat ]; then
    case "$source" in /*) src=$source ;; *) src="$FM_HOME/$source" ;; esac
    [ -f "$src" ] || refuse "source is neither 'chat' nor a readable file: $source"
    grep -qF -- "$quote" "$src" || refuse "the quote does not appear verbatim in $source"
  fi
  missing=$(perl -e '
    my ($fact, $quote) = @ARGV;
    my @miss;
    for my $t ($fact =~ m{([A-Za-z][A-Za-z0-9+.-]*://\S+|\S*/\S+|\d+(?:[.,:]\d+)*)}g) {
      $t =~ s/^[(\["'"'"'`<]+//;
      $t =~ s/[.,;:!?)\]}"'"'"'`>]+$//;
      push @miss, $t if $t ne "" && index($quote, $t) < 0;
    }
    print join(" ", @miss);
  ' "$fact" "$quote")
  [ -z "$missing" ] || refuse "the quote does not contain: $missing"
  hit=$(forgotten_in "$fact $quote")
  [ -z "$hit" ] || refuse "it mentions the forgotten term '$hit' (unforget it only when the captain states it again)"
  marker=''
  [ "$target" != learnings.md ] || marker="<!--a:$TODAY-->"
  [ -z "$until" ] || marker="$marker<!--u:$until-->"
  mkdir -p "$(dirname "$file")"
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
    printf '\n' >> "$file"
  fi
  printf -- '- %s%s\n  > "%s" (%s, %s)\n' "$fact" "${marker:+ $marker}" "$quote" "$source" "$TODAY" >> "$file"
  printf 'captured: data/%s\n' "$target"
}

commit() {
  local top paths=() p
  [ -n "$1" ] || die "commit needs a reason"
  if ! top=$(git -C "$DATA" rev-parse --show-toplevel 2>/dev/null) \
    || [ "$(cd "$top" && pwd -P)" != "$(cd "$DATA" && pwd -P)" ]; then
    printf 'fm-memory: no journal: %s is not its own git repository\n' "$DATA"
    return 0
  fi
  for p in $MEMORY_FILES memory-archive.md memory people; do
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
  entries) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; each_memory_file list "" ;;
  forget) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; forget "$2" ;;
  unforget) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; unforget "$2" ;;
  check) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; check "$2" ;;
  commit) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; commit "$2" ;;
  new) [ "$#" -ge 3 ] || { usage >&2; exit 2; }; shift; new_file "$@" ;;
  index) [ "$#" -le 2 ] || { usage >&2; exit 2; }; index_cmd "${2:-}" ;;
  load) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; load "$2" ;;
  capture) shift; capture "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
