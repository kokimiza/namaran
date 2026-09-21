#!/usr/bin/env bash
# Namaran drill verifier.
#
# A *local and CI authoring aid*, like script/content.sh — it never runs on
# Cloudflare Pages. It checks one day's drill pages, and compiles and
# statically analyzes the source files that back up what those pages claim,
# so that a drill is never published with code that doesn't behave the way
# its answer says. The same command is the gate in
# .github/workflows/namara-daily.yml: nothing is pushed unless it passes.
#
# Usage:
#   script/verify.sh DATE VERIFY_DIR [LANG/TYPE ...]
#
#   LANG/TYPE pairs default to all 12 (4 languages x 3 exercise types).
#
# VERIFY_DIR holds one directory per combo, VERIFY_DIR/{lang}/{type}/, with
# complete, compilable source files named NAME.KIND.EXT:
#
#   NAME.ok.EXT    must compile with warnings as errors and pass static
#                  analysis (see "Toolchains" below). A drill's correct
#                  code: the READ program, the WRITE reference, the fixed
#                  DEBUG program.
#   NAME.stdout    optional, next to NAME.ok.EXT: the program is run (10s
#                  timeout, sanitizers on for C/C++) and its stdout must
#                  match this file byte for byte. Required for every READ
#                  ok file, so the published answer is the observed output.
#   NAME.ng.EXT    must FAIL to compile: a "this doesn't compile" answer,
#                  or a DEBUG drill whose bug is a compile error.
#   NAME.bug.EXT   must compile (warnings allowed) but is never run and
#                  never analyzed: a DEBUG drill whose bug is at run time
#                  (undefined behavior, a hang, a wrong result).
#
# Per combo, at least: READ one file of any kind; WRITE one ok file; DEBUG
# one ok file plus one ng or bug file.
#
# Page checks, for {lang}/{type}/DATE.html: JSON-LD parses, no TODO left,
# lang-nav/type-nav point at the same date, the archive.html line exists,
# <code> contents are HTML-escaped (the highlighter's <span>s aside), every
# non-comment line of every <pre class="code"> block appears (ignoring
# indentation) in one of that combo's ok/ng/bug files — so the code readers
# see is the code that was checked — and the listings are highlighted exactly
# as script/highlight.sh would write them.
#
# Toolchains (override the command names with environment variables):
#   C        NAMARA_CC     (gcc-14)   -std=c23   -Wall -Wextra -Wpedantic -Werror -fanalyzer
#   C++      NAMARA_CXX    (g++-14)   -std=c++26 -Wall -Wextra -Wpedantic -Werror
#   Rust     NAMARA_CLIPPY (clippy-driver) / NAMARA_RUSTC (rustc)  --edition 2024, clippy -D warnings
#   Haskell  NAMARA_GHC    (ghc) / NAMARA_HLINT (hlint)  -XHaskell2010 -Wall -Werror, hlint warnings/errors
#
# The language versions here must match CLAUDE.md's version table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ALL_LANGS=(c cpp rust haskell)
ALL_TYPES=(read write debug)

CC="${NAMARA_CC:-gcc-14}"
CXX="${NAMARA_CXX:-g++-14}"
RUSTC="${NAMARA_RUSTC:-rustc}"
CLIPPY="${NAMARA_CLIPPY:-clippy-driver}"
GHC="${NAMARA_GHC:-ghc}"
HLINT="${NAMARA_HLINT:-hlint}"

usage() {
  sed -n '2,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

code_ext() {
  case "$1" in
    c) echo "c" ;;
    cpp) echo "cpp" ;;
    rust) echo "rs" ;;
    haskell) echo "hs" ;;
    *) echo "unknown language: $1" >&2; exit 2 ;;
  esac
}

FAILURES=0
fail() {
  echo "  FAIL: $*"
  FAILURES=$((FAILURES + 1))
}
pass() {
  echo "  ok:   $*"
}

# Runs a command with its output captured to $LOG; prints the log on demand.
LOG=""
run_logged() {
  "$@" > "$LOG" 2>&1
}
show_log() {
  sed -n '1,40p' "$LOG" | sed 's/^/        /'
}

# compile_ok LANG SRC BIN — strict build + static analysis of a correct file.
compile_ok() {
  local lang="$1" src="$2" bin="$3" out="$4"
  case "$lang" in
    c)
      run_logged "$CC" -std=c23 -Wall -Wextra -Wpedantic -Werror -fanalyzer \
        -g -fsanitize=address,undefined -fno-sanitize-recover=all -o "$bin" "$src"
      ;;
    cpp)
      run_logged "$CXX" -std=c++26 -Wall -Wextra -Wpedantic -Werror \
        -g -fsanitize=address,undefined -fno-sanitize-recover=all -o "$bin" "$src"
      ;;
    rust)
      run_logged "$CLIPPY" --edition 2024 --crate-name verify -D warnings \
        -C debug-assertions=on -o "$bin" "$src"
      ;;
    haskell)
      run_logged "$GHC" -XHaskell2010 -Wall -Werror -outputdir "$out" -o "$bin" "$src" &&
        run_logged_hlint "$src"
      ;;
  esac
}

# hlint suggestions are style preferences and don't fail the check;
# warnings and errors do.
run_logged_hlint() {
  local json
  json="$("$HLINT" --json "$1" 2> "$LOG" || true)"
  python3 -c '
import json, sys
hints = [h for h in json.loads(sys.argv[1] or "[]") if h["severity"] in ("Warning", "Error")]
for h in hints:
    print("hlint %s: line %s: %s: %r -> %r" % (h["severity"], h["startLine"], h["hint"], h["from"], h["to"]))
sys.exit(1 if hints else 0)
' "$json" > "$LOG" 2>&1
}

# check_only LANG SRC OUT — does this file compile at all? (no warnings gate)
check_only() {
  local lang="$1" src="$2" out="$3"
  case "$lang" in
    c) run_logged "$CC" -std=c23 -pedantic-errors -fsyntax-only "$src" ;;
    cpp) run_logged "$CXX" -std=c++26 -pedantic-errors -fsyntax-only "$src" ;;
    rust) run_logged "$RUSTC" --edition 2024 --crate-name verify --emit=metadata -o "$out/verify.rmeta" "$src" ;;
    haskell) run_logged "$GHC" -XHaskell2010 -fno-code -outputdir "$out" "$src" ;;
  esac
}

verify_sources() {
  local lang="$1" type="$2" src_dir="$3" work="$4"
  local ext n_ok=0 n_ng=0 n_bug=0 n_any=0 f base name kind stdout_file bin out
  ext="$(code_ext "$lang")"

  shopt -s nullglob
  for f in "$src_dir"/*; do
    base="$(basename "$f")"
    case "$base" in
      *.ok."$ext") kind=ok ;;
      *.ng."$ext") kind=ng ;;
      *.bug."$ext") kind=bug ;;
      *.stdout)
        [ -f "$src_dir/${base%.stdout}.ok.$ext" ] ||
          fail "$base has no matching ${base%.stdout}.ok.$ext"
        continue
        ;;
      *) fail "unexpected file (want NAME.ok|ng|bug.$ext or NAME.stdout): $base"; continue ;;
    esac
    name="${base%."$kind"."$ext"}"
    n_any=$((n_any + 1))
    out="$work/$lang-$type-$name-$kind"
    mkdir -p "$out"
    bin="$out/prog"
    LOG="$out/log.txt"

    case "$kind" in
      ok)
        n_ok=$((n_ok + 1))
        if ! compile_ok "$lang" "$f" "$bin" "$out"; then
          fail "$base does not pass the strict build / static analysis:"
          show_log
          continue
        fi
        stdout_file="$src_dir/$name.stdout"
        if [ -f "$stdout_file" ]; then
          if ! (cd "$out" && timeout 10 "$bin" > "$out/actual.stdout" 2> "$out/stderr.txt"); then
            fail "$base: running it failed or timed out:"
            sed -n '1,20p' "$out/stderr.txt" | sed 's/^/        /'
          elif ! cmp -s "$stdout_file" "$out/actual.stdout"; then
            fail "$base: stdout differs from $name.stdout:"
            { diff "$stdout_file" "$out/actual.stdout" || true; } | sed -n '1,20p' | sed 's/^/        /'
          else
            pass "$base (analyzed, stdout matches)"
          fi
        elif [ "$type" = "read" ]; then
          fail "$base: READ ok files need a $name.stdout with the answer's output"
        else
          pass "$base (analyzed)"
        fi
        ;;
      ng)
        n_ng=$((n_ng + 1))
        if check_only "$lang" "$f" "$out"; then
          fail "$base was expected NOT to compile, but it does"
        else
          pass "$base (fails to compile, as expected)"
        fi
        ;;
      bug)
        n_bug=$((n_bug + 1))
        if check_only "$lang" "$f" "$out"; then
          pass "$base (compiles; run-time bug, not executed)"
        else
          fail "$base was expected to compile, but it doesn't:"
          show_log
        fi
        ;;
    esac
  done
  shopt -u nullglob

  case "$type" in
    read) [ "$n_any" -ge 1 ] || fail "READ needs at least one source file" ;;
    write) [ "$n_ok" -ge 1 ] || fail "WRITE needs at least one ok file (the reference)" ;;
    debug)
      [ "$n_ok" -ge 1 ] || fail "DEBUG needs at least one ok file (the fixed program)"
      [ $((n_ng + n_bug)) -ge 1 ] || fail "DEBUG needs an ng or bug file (the broken program)"
      ;;
  esac
}

verify_page() {
  local lang="$1" type="$2" date="$3" src_dir="$4"
  local result
  if result="$(python3 - "$ROOT_DIR" "$lang" "$type" "$date" "$src_dir" <<'PY'
import html, json, pathlib, re, sys

root, lang, typ, date, src_dir = sys.argv[1:]
page = pathlib.Path(root, lang, typ, f"{date}.html")
archive = pathlib.Path(root, lang, typ, "archive.html")
exts = {"c": "c", "cpp": "cpp", "rust": "rs", "haskell": "hs"}
# The only markup allowed inside <code>: script/highlight.sh's token spans.
spans = re.compile(r'<span class="(?:kw|ty|fn|st|nu|cm|pp|mc|lt|op)">|</span>')
problems = []

s = page.read_text(encoding="utf-8")

m = re.search(r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>', s, re.S)
try:
    json.loads(m.group(1))
except Exception as e:
    problems.append(f"JSON-LD does not parse: {e}")

if "TODO" in s:
    problems.append("TODO markers remain")

def nav(cls):
    n = re.search(rf'<nav class="{cls}".*?</nav>', s, re.S)
    return n.group(0) if n else ""
lang_nav, type_nav = nav("lang-nav"), nav("type-nav")
for l in exts:
    if f'href="/{l}/{typ}/{date}"' not in lang_nav:
        problems.append(f"lang-nav lacks /{l}/{typ}/{date}")
for t in ("read", "write", "debug"):
    if f'href="/{lang}/{t}/{date}"' not in type_nav:
        problems.append(f"type-nav lacks /{lang}/{t}/{date}")
active = f'href="/{lang}/{typ}/{date}" class="active" aria-current="page"'
if active not in lang_nav or active not in type_nav:
    problems.append("current page is not marked active in both navs")

if f'href="/{lang}/{typ}/{date}"' not in archive.read_text(encoding="utf-8"):
    problems.append(f"{archive.relative_to(root)} has no line for {date}")

for code in re.findall(r"<code>(.*?)</code>", s, re.S):
    if re.search(r"<|&(?!lt;|gt;|amp;|quot;|#39;)", spans.sub("", code)):
        problems.append(f"unescaped < or & inside <code>: {code[:60]!r}")

ext = exts[lang]
kinds = ("ok", "ng", "bug")
verified = set()
for f in pathlib.Path(src_dir).glob(f"*.{ext}"):
    if any(f.name.endswith(f".{k}.{ext}") for k in kinds):
        verified.update(line.strip() for line in f.read_text(encoding="utf-8").splitlines())
comment = re.compile(r"^(--( |$)|\{-)" if lang == "haskell" else r"^(//|/\*|\*/|\*( |$))")
for block in re.findall(r'<pre class="code"><code>(.*?)</code></pre>', s, re.S):
    for line in html.unescape(spans.sub("", block)).splitlines():
        t = line.strip()
        if t and not comment.match(t) and t not in verified:
            problems.append(f"published code line is in no ok/ng/bug file: {t!r}")

print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
)"; then
    pass "$lang/$type/$date.html (page checks)"
  else
    fail "$lang/$type/$date.html page checks:"
    printf '%s\n' "$result" | sed 's/^/        /'
  fi

  if result="$("$SCRIPT_DIR/highlight.sh" --check "$ROOT_DIR/$lang/$type/$date.html" 2>&1)"; then
    pass "$lang/$type/$date.html (highlighting)"
  else
    fail "$lang/$type/$date.html is not highlighted as script/highlight.sh writes it:"
    printf '%s\n' "$result" | sed 's/^/        /'
  fi
}

main() {
  case "${1:-}" in
    ""|-h|--help|help) usage; exit 0 ;;
  esac
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }

  local date="$1" verify_dir="$2"
  shift 2
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "error: not a YYYY-MM-DD date: $date" >&2; exit 2; }
  verify_dir="$(cd "$verify_dir" 2>/dev/null && pwd)" || { echo "error: no such directory: $2" >&2; exit 2; }

  local combos=() lang type pair
  if [ "$#" -eq 0 ]; then
    for lang in "${ALL_LANGS[@]}"; do
      for type in "${ALL_TYPES[@]}"; do combos+=("$lang/$type"); done
    done
  else
    combos=("$@")
  fi

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  for pair in "${combos[@]}"; do
    lang="${pair%%/*}" type="${pair##*/}"
    code_ext "$lang" > /dev/null
    case "$type" in read|write|debug) ;; *) echo "unknown exercise type: $type" >&2; exit 2 ;; esac

    echo "== $lang/$type/$date"
    if [ ! -f "$ROOT_DIR/$lang/$type/$date.html" ]; then
      fail "$lang/$type/$date.html does not exist"
      continue
    fi
    if [ ! -d "$verify_dir/$lang/$type" ]; then
      fail "no verification sources in $verify_dir/$lang/$type"
      continue
    fi
    verify_page "$lang" "$type" "$date" "$verify_dir/$lang/$type"
    verify_sources "$lang" "$type" "$verify_dir/$lang/$type" "$WORK_DIR"
  done

  echo
  if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed."
    exit 1
  fi
  echo "All checks passed for ${#combos[@]} combo(s)."
}

main "$@"
