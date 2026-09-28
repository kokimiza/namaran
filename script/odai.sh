#!/usr/bin/env bash
# Namaran topic picker.
#
# A local and CI authoring aid (never deployed). Picks, for each of the four
# languages, one random topic from the namara-daily skill's odai.txt: either
# a line for that language or an "Any" line. The pick is made here, by a
# script, rather than by asking a model to "choose randomly", so it is
# actually random and shows up verbatim in the workflow log.
#
# Usage:
#   script/odai.sh [ODAI_FILE]
#
#   ODAI_FILE defaults to .claude/skills/namara-daily/odai.txt.
#
# odai.txt format: one "LABEL: topic" per line; blank lines and lines
# starting with # are ignored. LABEL names a language by its usual name,
# with or without the edition/standard suffix (C23, C++26, Rust2024,
# Haskell2010 ...), or is "Any" for a topic every language can take on.
# The suffix is not interpreted, so odai.txt keeps working when CLAUDE.md's
# version table moves to a newer standard.
#
# Output: one line per language, "LANG<TAB>TOPIC", in c, cpp, rust, haskell
# order; an "Any" topic is printed as-is. Exits non-zero on an unknown label
# or when some language has no candidate topic at all.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ODAI_FILE="${1:-$ROOT_DIR/.claude/skills/namara-daily/odai.txt}"

ALL_LANGS=(c cpp rust haskell)

label_lang() {
  case "$1" in
    Any) echo "any" ;;
    C++*) echo "cpp" ;;
    Rust*) echo "rust" ;;
    Haskell*) echo "haskell" ;;
    C|C[0-9]*) echo "c" ;;
    *) return 1 ;;
  esac
}

declare -A candidates=()
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ ! "$line" =~ ^([^:]+):[[:space:]]*(.+)$ ]]; then
    echo "error: $ODAI_FILE:$line_no: expected \"LABEL: topic\", got: $line" >&2
    exit 1
  fi
  label="${BASH_REMATCH[1]}"
  topic="${BASH_REMATCH[2]}"
  label="${label%"${label##*[![:space:]]}"}"
  if ! lang="$(label_lang "$label")"; then
    echo "error: $ODAI_FILE:$line_no: unknown label: $label" >&2
    exit 1
  fi
  if [ "$lang" = "any" ]; then
    for l in "${ALL_LANGS[@]}"; do candidates[$l]+="$topic"$'\n'; done
  else
    candidates[$lang]+="$topic"$'\n'
  fi
done < "$ODAI_FILE"

for lang in "${ALL_LANGS[@]}"; do
  if [ -z "${candidates[$lang]:-}" ]; then
    echo "error: no topic for $lang in $ODAI_FILE (add a line for it, or an Any line)" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$lang" "$(printf '%s' "${candidates[$lang]}" | shuf -n 1)"
done
