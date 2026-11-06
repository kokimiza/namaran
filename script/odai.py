#!/usr/bin/env python3
"""Namaran topic picker.

A local and CI authoring aid (never deployed). Picks, for each of the five
languages, one random topic from the namaran-daily skill's odai.txt: either
a line for that language or an "Any" line. The pick is made here, by a
script, rather than by asking a model to "choose randomly", so it is
actually random and shows up verbatim in the workflow log.

"Any" covers the four languages Namaran started with (ANY_LANGS below).
Zig draws only from its own lines: they were written for Zig 0.17, whose
standard library is still changing release by release, and a general
topic in Zig is far more likely to fail verification — which holds back
the whole day's drills, not just Zig's.

Usage:
  script/odai.py [ODAI_FILE]

  ODAI_FILE defaults to .claude/skills/namaran-daily/odai.txt.

odai.txt format: one "LABEL: topic" per line; blank lines and lines
starting with # are ignored. LABEL names a language by its usual name,
with or without the edition/standard suffix (C23, C++26, Rust2024,
Haskell2010, Zig ...), or is "Any" for a topic every language in
ANY_LANGS can take on.
The suffix is not interpreted, so odai.txt keeps working when CLAUDE.md's
version table moves to a newer standard.

Output: one line per language, "LANG<TAB>TOPIC", in c, cpp, rust, haskell,
zig order; an "Any" topic is printed as-is. Exits non-zero on an unknown label
or when some language has no candidate topic at all.
"""

import re
import secrets
import sys

from namaran import LANGS, ROOT, die, wants_help

ANY_LANGS = ("c", "cpp", "rust", "haskell")


def label_lang(label):
    """The language a LABEL names, "any", or None."""
    if label == "Any":
        return "any"
    for prefix, lang in (("C++", "cpp"), ("Rust", "rust"), ("Haskell", "haskell"), ("Zig", "zig")):
        if label.startswith(prefix):
            return lang
    if re.fullmatch(r"C(\d.*)?", label):
        return "c"
    return None


def main(args):
    wants_help(args)
    path = args[0] if args else str(ROOT / ".claude/skills/namaran-daily/odai.txt")
    candidates = {lang: [] for lang in LANGS}
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    for line_no, line in enumerate(text.split("\n"), start=1):
        line = line.removesuffix("\r")
        if re.match(r"\s*(#|$)", line):
            continue
        m = re.fullmatch(r"([^:]+):\s*(.+)", line)
        if not m:
            die(f'{path}:{line_no}: expected "LABEL: topic", got: {line}')
        label, topic = m.group(1).rstrip(), m.group(2)
        lang = label_lang(label)
        if lang is None:
            die(f"{path}:{line_no}: unknown label: {label}")
        for l in (ANY_LANGS if lang == "any" else (lang,)):
            candidates[l].append(topic)

    # No two languages get the same topic on the same day (an Any line could
    # otherwise land on several). Earlier days are not looked at: a topic may
    # come back on a later day.
    picked = []
    for lang in LANGS:
        pool = [t for t in candidates[lang] if t not in picked]
        if not pool:
            die(f"no topic left for {lang} in {path} (add a line for it, or an Any line)")
        topic = secrets.choice(pool)
        picked.append(topic)
        print(f"{lang}\t{topic}")


if __name__ == "__main__":
    main(sys.argv[1:])
