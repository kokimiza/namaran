#!/usr/bin/env bash
# Namaran content-management script.
#
# This is an *authoring aid* (run locally or by the namara-daily workflow),
# not part of the deployed site. It never runs on Cloudflare Pages and the
# site never depends on it — it only replaces hand-copying the same
# boilerplate (nav, JSON-LD, footer) into a new file and a new archive.html
# line every day. The one thing it deliberately does NOT do is invent the
# actual problem: code, question, and answer are written by the namara-daily
# skill against the criteria in doc/requirements.md §11/§24, so `new` always
# leaves those as clearly marked TODOs for the skill to fill in.
#
# Usage:
#   script/content.sh new  [DATE] [LANG/TYPE ...]
#   script/content.sh undo [DATE] [LANG/TYPE ...]
#
#   DATE defaults to today in Asia/Tokyo (matches functions/_middleware.js).
#   LANG/TYPE pairs default to all 12 (4 languages x 3 exercise types) when
#   omitted, e.g.: script/content.sh new 2026-08-25 c/read rust/debug
#
# `new`  creates {lang}/{type}/{date}.html from script/template.html and
#        prepends a matching <li> to {lang}/{type}/archive.html. It never
#        overwrites an existing dated file (doc/basic-design.md: published
#        pages are never edited), and skips an archive line that's already
#        there, so re-running `new` for the same day is always safe.
#
# `undo` reverses exactly that: removes the dated file and its archive line.
#        As a safety check, it only deletes a dated file that still contains
#        a "TODO:" marker — i.e. one nobody has started writing content
#        into yet. A file with the TODOs filled in is left alone; undo it
#        by hand if you really mean to.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/template.html"

ALL_LANGS=(c cpp rust haskell)
ALL_TYPES=(read write debug)

lang_label() {
  case "$1" in
    c) echo "C" ;;
    cpp) echo "C++" ;;
    rust) echo "Rust" ;;
    haskell) echo "Haskell" ;;
    *) echo "unknown language: $1" >&2; exit 1 ;;
  esac
}

type_label() {
  case "$1" in
    read) echo "READ" ;;
    write) echo "WRITE" ;;
    debug) echo "DEBUG" ;;
    *) echo "unknown exercise type: $1" >&2; exit 1 ;;
  esac
}

code_ext() {
  case "$1" in
    c) echo "c" ;;
    cpp) echo "cpp" ;;
    rust) echo "rs" ;;
    haskell) echo "hs" ;;
  esac
}

# The lang-nav buttons name a specific language edition/standard, so readers
# know exactly which dialect a drill assumes. Everywhere else (title, JSON-LD,
# meta description) keeps the plain lang_label() name — the edition suffix is
# a nav-button-only convention, not a rename of the language.
lang_nav_label() {
  case "$1" in
    c) echo "C23" ;;
    cpp) echo "C++26" ;;
    rust) echo "Rust 2024" ;;
    haskell) echo "Haskell 2010" ;;
    *) echo "unknown language: $1" >&2; exit 1 ;;
  esac
}

build_lang_nav() {
  local active_lang="$1" type="$2" date="$3" lang label href
  echo '<nav class="lang-nav" aria-label="Language">'
  for lang in "${ALL_LANGS[@]}"; do
    label="$(lang_nav_label "$lang")"
    href="/$lang/$type/$date"
    if [ "$lang" = "$active_lang" ]; then
      echo "  <a href=\"$href\" class=\"active\" aria-current=\"page\">$label</a>"
    else
      echo "  <a href=\"$href\">$label</a>"
    fi
  done
  echo '</nav>'
}

build_type_nav() {
  local lang="$1" active_type="$2" date="$3" type label href
  echo '<nav class="type-nav" aria-label="Exercise type">'
  for type in "${ALL_TYPES[@]}"; do
    label="$(type_label "$type")"
    href="/$lang/$type/$date"
    if [ "$type" = "$active_type" ]; then
      echo "  <a href=\"$href\" class=\"active\" aria-current=\"page\">$label</a>"
    else
      echo "  <a href=\"$href\">$label</a>"
    fi
  done
  echo '</nav>'
}

build_answer_body() {
  local type="$1"
  if [ "$type" = "write" ]; then
    cat <<'EOF'
      <pre class="code"><code>TODO: reference implementation
</code></pre>
      <p>
        TODO: 解説をここに書く。参考実装であり、唯一の正解ではないことに触れる。
      </p>
EOF
  else
    cat <<'EOF'
      <p>
        TODO: 答えと解説をここに書く。
      </p>
EOF
  fi
}

# Renders script/template.html for one (lang, type, date) to stdout.
# Block placeholders (@@LANG_NAV@@ etc.) must appear alone on their own
# line in the template; everything else is a plain inline substitution.
render() {
  local lang="$1" type="$2" date="$3"
  local lang_label_v type_label_v code_ext_v summary_label
  lang_label_v="$(lang_label "$lang")"
  type_label_v="$(type_label "$type")"
  code_ext_v="$(code_ext "$lang")"
  summary_label="Answer"
  [ "$type" = "write" ] && summary_label="Reference"

  local lang_nav type_nav answer_body
  lang_nav="$(build_lang_nav "$lang" "$type" "$date")"
  type_nav="$(build_type_nav "$lang" "$type" "$date")"
  answer_body="$(build_answer_body "$type")"

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '@@LANG_NAV@@') printf '%s\n' "$lang_nav" ;;
      '@@TYPE_NAV@@') printf '%s\n' "$type_nav" ;;
      '@@ANSWER_BODY@@') printf '%s\n' "$answer_body" ;;
      *)
        line="${line//@@DATE@@/$date}"
        line="${line//@@LANG_SLUG@@/$lang}"
        line="${line//@@LANG_LABEL@@/$lang_label_v}"
        line="${line//@@TYPE_SLUG@@/$type}"
        line="${line//@@TYPE_LABEL@@/$type_label_v}"
        line="${line//@@CODE_EXT@@/$code_ext_v}"
        line="${line//@@SUMMARY_LABEL@@/$summary_label}"
        printf '%s\n' "$line"
        ;;
    esac
  done < "$TEMPLATE"
}

today_in_japan() {
  TZ=Asia/Tokyo date +%Y-%m-%d
}

validate_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    echo "error: not a YYYY-MM-DD date: $1" >&2
    exit 1
  }
}

# Parses trailing LANG/TYPE args into the COMBOS array ("lang type" pairs,
# one per line-ish entry via parallel arrays). Defaults to all 12.
parse_combos() {
  COMBO_LANGS=()
  COMBO_TYPES=()
  if [ "$#" -eq 0 ]; then
    for lang in "${ALL_LANGS[@]}"; do
      for type in "${ALL_TYPES[@]}"; do
        COMBO_LANGS+=("$lang")
        COMBO_TYPES+=("$type")
      done
    done
    return
  fi
  for pair in "$@"; do
    local lang="${pair%%/*}" type="${pair##*/}"
    if [ "$lang" = "$pair" ] || [ "$type" = "$pair" ]; then
      echo "error: expected LANG/TYPE (e.g. c/read), got: $pair" >&2
      exit 1
    fi
    lang_label "$lang" > /dev/null
    type_label "$type" > /dev/null
    COMBO_LANGS+=("$lang")
    COMBO_TYPES+=("$type")
  done
}

cmd_new() {
  local date="${1:-$(today_in_japan)}"
  [ "$#" -gt 0 ] && shift
  validate_date "$date"
  parse_combos "$@"

  local created=0 skipped_file=0 archive_updated=0 archive_already=0
  for i in "${!COMBO_LANGS[@]}"; do
    local lang="${COMBO_LANGS[$i]}" type="${COMBO_TYPES[$i]}"
    local dir="$ROOT_DIR/$lang/$type"
    local file="$dir/$date.html"
    local archive="$dir/archive.html"

    mkdir -p "$dir"

    if [ -e "$file" ]; then
      echo "skip (already exists): $lang/$type/$date.html"
      skipped_file=$((skipped_file + 1))
    else
      render "$lang" "$type" "$date" > "$file"
      echo "created: $lang/$type/$date.html"
      created=$((created + 1))
    fi

    if [ -f "$archive" ]; then
      if grep -qF "/$lang/$type/$date\"" "$archive"; then
        archive_already=$((archive_already + 1))
      else
        local entry="    <li><a href=\"/$lang/$type/$date\">$date</a></li>"
        # Keep the list newest-first: insert right before the first existing
        # <li> whose date is older than the new one (ISO 8601 dates compare
        # correctly as plain strings). If every existing entry is newer (or
        # the list is still empty), that never matches, so fall back to
        # inserting right before </ul> — i.e. at the end, the oldest slot.
        # This matters for backfilling a date behind an already-listed
        # newer one, not just for the usual "today" append.
        awk -v entry="$entry" -v newdate="$date" '
          {
            if (!done && match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
              existing = substr($0, RSTART, RLENGTH)
              if (newdate > existing) { print entry; done = 1 }
            }
            if (!done && $0 ~ /<\/ul>/) { print entry; done = 1 }
            print
          }
        ' "$archive" > "$archive.tmp" && mv "$archive.tmp" "$archive"
        echo "archived: $lang/$type/archive.html += $date"
        archive_updated=$((archive_updated + 1))
      fi
    else
      echo "warning: no archive.html for $lang/$type yet — skipped archive update" >&2
    fi
  done

  echo
  echo "$created created, $skipped_file already existed, $archive_updated archive.html updated, $archive_already already listed."
  if [ "$created" -gt 0 ]; then
    echo "Fill in the TODOs (code / question / answer) before publishing."
  fi
}

cmd_undo() {
  local date="${1:-$(today_in_japan)}"
  [ "$#" -gt 0 ] && shift
  validate_date "$date"
  parse_combos "$@"

  local removed=0 kept=0 archive_removed=0
  for i in "${!COMBO_LANGS[@]}"; do
    local lang="${COMBO_LANGS[$i]}" type="${COMBO_TYPES[$i]}"
    local dir="$ROOT_DIR/$lang/$type"
    local file="$dir/$date.html"
    local archive="$dir/archive.html"

    if [ -f "$file" ]; then
      if grep -q 'TODO:' "$file"; then
        rm "$file"
        echo "removed: $lang/$type/$date.html"
        removed=$((removed + 1))
      else
        echo "keep (has been edited, no TODO markers left): $lang/$type/$date.html" >&2
        kept=$((kept + 1))
        continue
      fi
    fi

    if [ -f "$archive" ] && grep -qF "/$lang/$type/$date\"" "$archive"; then
      # Matches the link, not the whole line: script/topics.sh (§9.5) appends
      # the drill's topic to it afterwards, so the tail of the line varies.
      grep -vF "/$lang/$type/$date\">$date</a>" "$archive" > "$archive.tmp" && mv "$archive.tmp" "$archive"
      echo "unarchived: $lang/$type/archive.html -= $date"
      archive_removed=$((archive_removed + 1))
    fi
  done

  echo
  echo "$removed removed, $kept kept (edited — remove by hand if you're sure), $archive_removed archive.html entries removed."
}

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift || true
  case "$sub" in
    new) cmd_new "$@" ;;
    undo) cmd_undo "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "error: unknown subcommand: $sub" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
