#!/usr/bin/env python3
"""Namaran code formatter.

An *authoring aid*, like script/highlight.py: it rewrites the verification
sources of script/verify.py in place with the repository's formatter
configs, so every drill's code is published in one layout instead of
whatever the day's author happened to write.

Usage:
  script/format.py [--check] FILE ...

  FILE is a C, C++, Rust, Haskell or Zig source (.c .cpp .rs .hs .zig, so
  the verification names NAME.ok.rs etc. work as they are).

  --check  change nothing; exit 1 and print the diff for each file that is
           not exactly what this script would write. script/verify.py uses
           this as a gate, on every ok, ng and bug file.

Configs (repository root), passed by path rather than discovered, because
verification sources live outside the repository where clang-format and
fourmolu would not find them:
  C, C++   .clang-format   clang-format
  Rust     rustfmt.toml    rustfmt, parsed as edition 2024 like
                           script/verify.py's builds (rustfmt.toml fixes
                           only the style edition; the edition belongs to
                           the crate)
  Haskell  fourmolu.yaml   fourmolu
  Zig      (none)          zig fmt, which has no settings: the layout is
                           fixed by the Zig release itself

Exit status: 0 everything formatted (or rewritten); 1 --check found a file
that would change; 2 usage error, or a formatter is missing or not the
pinned version; 3 a formatter could not read a file (a syntax error).
script/verify.py accepts 3 only for an ng file, whose syntax error may be
the point of a READ drill.

When a layout the formatter would change is itself what a drill asks
about (misleading indentation, the Haskell layout rule), switch the
formatter off around just that code in the verification source, with a
comment saying why — the same rule as for lint suppressions:
  C, C++   // clang-format off  ...  // clang-format on
  Rust     #[rustfmt::skip] on the item or statement
  Haskell  {- FOURMOLU_DISABLE -}  ...  {- FOURMOLU_ENABLE -}  (column 0)
  Zig      // zig fmt: off  ...  // zig fmt: on
Never to keep lines short of the 21-line limit (ponytail.md §2).

Formatters (override the command names with environment variables). Their
output differs between versions, so clang-format, fourmolu and zig must be
the versions .github/actions/toolchains installs; rustfmt follows stable
Rust, whose output is fixed by style_edition. zig fmt ships inside the
compiler, so its version is the Zig version of CLAUDE.md's table, the same
binary script/verify.py builds with.
  C, C++   NAMARAN_CLANG_FORMAT (clang-format)  23.1.2  pip install clang-format==23.1.2
  Rust     NAMARAN_RUSTFMT      (rustfmt)       stable  rustup component add rustfmt
  Haskell  NAMARAN_FOURMOLU     (fourmolu)      0.21.0.0  github.com/fourmolu/fourmolu/releases
  Zig      NAMARAN_ZIG          (zig)           0.17.0  ziglang.org/download
"""

import difflib
import os
import pathlib
import re
import subprocess
import sys

from namaran import ROOT, wants_help

CLANG_FORMAT = os.environ.get("NAMARAN_CLANG_FORMAT", "clang-format")
RUSTFMT = os.environ.get("NAMARAN_RUSTFMT", "rustfmt")
FOURMOLU = os.environ.get("NAMARAN_FOURMOLU", "fourmolu")
ZIG = os.environ.get("NAMARAN_ZIG", "zig")

# Keep in step with .github/actions/toolchains/action.yml. A mismatch stops
# here, loudly, instead of formatting differently from CI.
CLANG_FORMAT_VERSION = "23.1.2"
FOURMOLU_VERSION = "0.21.0.0"
ZIG_VERSION = "0.17.0"

EXT_LANG = {".c": "c", ".cpp": "cpp", ".rs": "rust", ".hs": "haskell", ".zig": "zig"}

OK, CHANGED, UNUSABLE, UNREADABLE = 0, 1, 2, 3


def output_of(cmd):
    """stdout of cmd, or "" when it cannot run or fails."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError:
        return ""
    return r.stdout if r.returncode == 0 else ""


def missing(lang):
    """Why the formatter for lang cannot be used, or None if it is the pinned one."""
    if lang in ("c", "cpp"):
        m = re.search(r"clang-format version ([0-9.]*)", output_of([CLANG_FORMAT, "--version"]))
        v = m.group(1) if m else ""
        if v != CLANG_FORMAT_VERSION:
            return f"need clang-format {CLANG_FORMAT_VERSION}, found {v or 'none'} ({CLANG_FORMAT})"
    elif lang == "rust":
        try:
            subprocess.run([RUSTFMT, "--version"], capture_output=True, check=True)
        except (OSError, subprocess.CalledProcessError):
            return f"rustfmt not found ({RUSTFMT})"
    elif lang == "haskell":
        first = output_of([FOURMOLU, "--version"]).partition("\n")[0]
        m = re.match(r"fourmolu ([0-9.]*)", first)
        v = m.group(1) if m else ""
        if v != FOURMOLU_VERSION:
            return f"need fourmolu {FOURMOLU_VERSION}, found {v or 'none'} ({FOURMOLU})"
    elif lang == "zig":
        v = output_of([ZIG, "version"]).strip()
        if v != ZIG_VERSION:
            return f"need zig {ZIG_VERSION}, found {v or 'none'} ({ZIG})"
    return None


def formatted(lang, path):
    """(the formatted source as bytes, None) or (None, the formatter's stderr)."""
    src = path.read_bytes()
    if lang in ("c", "cpp"):
        cmd, stdin = [CLANG_FORMAT, f"--style=file:{ROOT / '.clang-format'}", str(path)], None
    elif lang == "rust":
        cmd, stdin = [RUSTFMT, "--edition", "2024", "--config-path", str(ROOT / "rustfmt.toml")], src
    elif lang == "haskell":
        cmd, stdin = [FOURMOLU, "--quiet", "--no-cabal", "--config", str(ROOT / "fourmolu.yaml"), str(path)], None
    else:
        cmd, stdin = [ZIG, "fmt", "--stdin"], src
    r = subprocess.run(cmd, input=stdin, capture_output=True)
    if r.returncode != 0:
        return None, r.stderr.decode("utf-8", "replace")
    return r.stdout, None


def run(paths, check, out=print):
    """Format (or with check, only inspect) paths. Returns the exit status."""
    langs = []
    for p in paths:
        lang = EXT_LANG.get(pathlib.Path(p).suffix)
        if lang is None:
            out(f"error: not a .c, .cpp, .rs, .hs or .zig file: {p}")
            return UNUSABLE
        if not pathlib.Path(p).is_file():
            out(f"error: no such file: {p}")
            return UNUSABLE
        langs.append(lang)
    for lang in dict.fromkeys(langs):
        why = missing(lang)
        if why:
            out(f"error: {why}")
            return UNUSABLE

    unreadable = changed = False
    for p, lang in zip(paths, langs):
        path = pathlib.Path(p)
        new, err = formatted(lang, path)
        if new is None:
            out(f"{p}: the formatter could not read it:")
            for line in err.splitlines()[:20]:
                out(f"  {line}")
            unreadable = True
            continue
        old = path.read_bytes()
        if new == old:
            continue
        if check:
            out(f"{p}: not formatted; script/format.py would change it:")
            for line in difflib.unified_diff(
                    old.decode("utf-8", "replace").splitlines(),
                    new.decode("utf-8", "replace").splitlines(),
                    fromfile=p, tofile="formatted", lineterm=""):
                out(line)
            changed = True
        else:
            path.write_bytes(new)
            out(f"formatted: {p}")
    if unreadable:
        return UNREADABLE
    return CHANGED if changed else OK


def main(args):
    if not args:
        print(__doc__.strip())
        return
    wants_help(args)
    check = args[0] == "--check"
    paths = args[1:] if check else args
    if not paths:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(UNUSABLE)

    def say(msg):
        print(msg, file=sys.stderr if msg.startswith("error: ") else sys.stdout)

    sys.exit(run(paths, check, say))


if __name__ == "__main__":
    main(sys.argv[1:])
