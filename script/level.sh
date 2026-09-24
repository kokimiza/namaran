#!/usr/bin/env bash
# Namaran difficulty draw.
#
# A local and CI authoring aid like script/odai.sh (never deployed). Draws a
# difficulty for each LANG/TYPE combo, so that the namara-daily skill writes
# each drill to a level chosen for it, not one it picked itself. A model asked
# to "pick at random" drifts toward the middle and toward what it wrote last;
# a script does neither, and its pick shows up verbatim in the workflow log.
#
# Usage:
#   script/level.sh [LANG/TYPE ...]
#
#   LANG/TYPE pairs default to all 12 (4 languages x 3 exercise types).
#
# The four levels are animals, not stars (doc/requirements.md §7):
#
#   hedgehog   ハリネズミ   基礎   44.7%
#   peacock    孔雀         初級   27.6%
#   bison      バイソン     中級   17.1%
#   whale      クジラ       上級   10.6%
#
# Each probability is the one above it divided by the golden ratio, and the
# four add up to 100%: φ^0 + φ^-1 + φ^-2 + φ^-3 = √5, so level k comes up
# with probability φ^-k / √5.
#
# Every combo is drawn on its own, and nothing looks at what earlier days
# drew. A day of twelve whales is a legitimate outcome and is published as
# such: the distribution holds over time, not within a day, and evening it
# out by hand would make the draw mean nothing.
#
# Output: one line per combo, "LANG/TYPE<TAB>LEVEL", in the order given.

set -euo pipefail

ALL_LANGS=(c cpp rust haskell)
ALL_TYPES=(read write debug)

# Per mille, so the draw is exact integer arithmetic: 447 + 276 + 171 + 106.
LEVELS=(hedgehog peacock bison whale)
WEIGHTS=(447 276 171 106)

case "${1:-}" in
  -h|--help|help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

combos=()
if [ "$#" -eq 0 ]; then
  for lang in "${ALL_LANGS[@]}"; do
    for type in "${ALL_TYPES[@]}"; do combos+=("$lang/$type"); done
  done
else
  for pair in "$@"; do
    case "$pair" in
      c/*|cpp/*|rust/*|haskell/*) ;;
      *) echo "error: expected LANG/TYPE (e.g. c/read), got: $pair" >&2; exit 1 ;;
    esac
    case "${pair#*/}" in
      read|write|debug) ;;
      *) echo "error: expected LANG/TYPE (e.g. c/read), got: $pair" >&2; exit 1 ;;
    esac
    combos+=("$pair")
  done
fi

for pair in "${combos[@]}"; do
  roll="$(shuf -i 0-999 -n 1)"
  for i in "${!LEVELS[@]}"; do
    if [ "$roll" -lt "${WEIGHTS[$i]}" ]; then
      printf '%s\t%s\n' "$pair" "${LEVELS[$i]}"
      break
    fi
    roll=$((roll - WEIGHTS[i]))
  done
done
