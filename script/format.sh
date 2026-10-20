#!/usr/bin/env bash
# Namaran code formatter.
#
# An *authoring aid*, like script/highlight.sh: it rewrites the verification
# sources of script/verify.sh in place with the repository's formatter
# configs, so every drill's code is published in one layout instead of
# whatever the day's author happened to write.
#
# Usage:
#   script/format.sh [--check] FILE ...
#
#   FILE is a C, C++, Rust or Haskell source (.c .cpp .rs .hs, so the
#   verification names NAME.ok.rs etc. work as they are).
#
#   --check  change nothing; exit 1 and print the diff for each file that is
#            not exactly what this script would write. script/verify.sh uses
#            this as a gate, on every ok, ng and bug file.
#
# Configs (repository root), passed by path rather than discovered, because
# verification sources live outside the repository where clang-format and
# fourmolu would not find them:
#   C, C++   .clang-format   clang-format
#   Rust     rustfmt.toml    rustfmt, parsed as edition 2024 like
#                            script/verify.sh's builds (rustfmt.toml fixes
#                            only the style edition; the edition belongs to
#                            the crate)
#   Haskell  fourmolu.yaml   fourmolu
#
# Exit status: 0 everything formatted (or rewritten); 1 --check found a file
# that would change; 2 usage error, or a formatter is missing or not the
# pinned version; 3 a formatter could not read a file (a syntax error).
# script/verify.sh accepts 3 only for an ng file, whose syntax error may be
# the point of a READ drill.
#
# When a layout the formatter would change is itself what a drill asks
# about (misleading indentation, the Haskell layout rule), switch the
# formatter off around just that code in the verification source, with a
# comment saying why — the same rule as for lint suppressions:
#   C, C++   // clang-format off  ...  // clang-format on
#   Rust     #[rustfmt::skip] on the item or statement
#   Haskell  {- FOURMOLU_DISABLE -}  ...  {- FOURMOLU_ENABLE -}  (column 0)
# Never to keep lines short of the 21-line limit (ponytail.md §2).
#
# Formatters (override the command names with environment variables). Their
# output differs between versions, so clang-format and fourmolu must be the
# versions .github/actions/toolchains installs; rustfmt follows stable Rust,
# whose output is fixed by style_edition.
#   C, C++   NAMARA_CLANG_FORMAT (clang-format)  23.1.2  pip install clang-format==23.1.2
#   Rust     NAMARA_RUSTFMT      (rustfmt)       stable  rustup component add rustfmt
#   Haskell  NAMARA_FOURMOLU     (fourmolu)      0.21.0.0  github.com/fourmolu/fourmolu/releases

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLANG_FORMAT="${NAMARA_CLANG_FORMAT:-clang-format}"
RUSTFMT="${NAMARA_RUSTFMT:-rustfmt}"
FOURMOLU="${NAMARA_FOURMOLU:-fourmolu}"

# Keep in step with .github/actions/toolchains/action.yml. A mismatch stops
# here, loudly, instead of formatting differently from CI.
CLANG_FORMAT_VERSION=23.1.2
FOURMOLU_VERSION=0.21.0.0

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

file_lang() {
  case "$1" in
    *.c) echo c ;;
    *.cpp) echo cpp ;;
    *.rs) echo rust ;;
    *.hs) echo haskell ;;
    *) return 1 ;;
  esac
}

# require LANG — is the formatter for LANG installed, in the pinned version?
require() {
  local v
  case "$1" in
    c|cpp)
      v="$("$CLANG_FORMAT" --version 2> /dev/null | sed -n 's/.*clang-format version \([0-9.]*\).*/\1/p')" || true
      [ "$v" = "$CLANG_FORMAT_VERSION" ] || {
        echo "error: need clang-format $CLANG_FORMAT_VERSION, found ${v:-none} ($CLANG_FORMAT)" >&2
        return 1
      }
      ;;
    rust)
      "$RUSTFMT" --version > /dev/null 2>&1 || {
        echo "error: rustfmt not found ($RUSTFMT)" >&2
        return 1
      }
      ;;
    haskell)
      v="$("$FOURMOLU" --version 2> /dev/null | sed -n '1s/^fourmolu \([0-9.]*\).*/\1/p')" || true
      [ "$v" = "$FOURMOLU_VERSION" ] || {
        echo "error: need fourmolu $FOURMOLU_VERSION, found ${v:-none} ($FOURMOLU)" >&2
        return 1
      }
      ;;
  esac
}

# format_to LANG SRC OUT — write the formatted SRC to OUT.
format_to() {
  case "$1" in
    c|cpp) "$CLANG_FORMAT" --style="file:$ROOT_DIR/.clang-format" "$2" ;;
    rust) "$RUSTFMT" --edition 2024 --config-path "$ROOT_DIR/rustfmt.toml" < "$2" ;;
    haskell) "$FOURMOLU" --quiet --no-cabal --config "$ROOT_DIR/fourmolu.yaml" "$2" ;;
  esac > "$3"
}

main() {
  local check=0
  case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
    --check) check=1; shift ;;
  esac
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }

  local f lang ready=" " unreadable=0 changed=0
  for f in "$@"; do
    lang="$(file_lang "$f")" || { echo "error: not a .c, .cpp, .rs or .hs file: $f" >&2; exit 2; }
    [ -f "$f" ] || { echo "error: no such file: $f" >&2; exit 2; }
    case "$ready" in
      *" $lang "*) ;;
      *) require "$lang" || exit 2; ready+="$lang " ;;
    esac
  done

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  for f in "$@"; do
    lang="$(file_lang "$f")"
    if ! format_to "$lang" "$f" "$WORK_DIR/out" 2> "$WORK_DIR/err"; then
      echo "$f: the formatter could not read it:"
      sed -n '1,20p' "$WORK_DIR/err" | sed 's/^/  /'
      unreadable=1
      continue
    fi
    cmp -s "$f" "$WORK_DIR/out" && continue
    if [ "$check" -eq 1 ]; then
      echo "$f: not formatted; script/format.sh would change it:"
      diff -u --label "$f" --label formatted "$f" "$WORK_DIR/out" || true
      changed=1
    else
      cat "$WORK_DIR/out" > "$f"
      echo "formatted: $f"
    fi
  done

  [ "$unreadable" -eq 0 ] || exit 3
  [ "$changed" -eq 0 ] || exit 1
}

main "$@"
