#!/usr/bin/env python3
"""Namaran complexity line checker.

WRITE and DEBUG answers state the time and space complexity of the code they
end with (the WRITE reference, the DEBUG Right), in big-O notation, inside
the heading of that code: WRITE's <summary>Reference ...</summary>, DEBUG's
<h3 class="right">Right ...</h3>. style.css sets it on the heading's row,
to the right, and shows the summary's only while the answer is open.

  <h3 class="right">Right
    <span class="complexity">
      <span><span class="complexity-label">時間計算量</span> &#x1D4AA;(<var>n</var>)</span>
      <span><span class="complexity-label">空間計算量</span> &#x1D4AA;(1)</span>
      <span class="complexity-where"><var>n</var> は <code>digits</code> が出す数字の個数</span>
    </span>
  </h3>

This script checks the *form* of that line, not whether the bound is right:
measuring a bound would mean timing each drill at several input sizes, with
a harness per language. What it checks:

  * the line exists once, in the WRITE Reference summary or the DEBUG
    Right heading
  * one time entry and one space entry, in that order, each 𝒪(...) written
    as &#x1D4AA; (the character itself and a Latin O are refused). This
    unifies the source, not the glyph: after parsing, &#x1D4AA; and 𝒪 are
    the same character, and which face draws it is style.css's math font
    stack (".complexity")
  * the inside of 𝒪(...) is a plain bound: 1, variables in <var>, log,
    powers in <sup>, products by juxtaposition, sums with +
  * every variable the bounds use is defined in the where-span
    ("<var>n</var> は ..."), every variable defined there is used, and the
    where-span is there only if needed

Space follows Namaran's own convention, since sources differ on whether the
result counts (namaran-daily SKILL.md, "計算量"): the input is not counted;
locals, temporary buffers, the recursion stack, heap allocations and a newly
built return value are.

Usage:
  script/complexity.py FILE ...   print problems; exit 1 if any

script/verify.py calls problems() for WRITE and DEBUG pages from
COMPLEXITY_SINCE on.
"""

import re
import sys

# The first day whose WRITE / DEBUG answers carry the complexity line.
COMPLEXITY_SINCE = "2026-11-27"

O = "&#x1D4AA;"
VAR = r"<var>[a-z]</var>"
# A factor: 1, a variable, log of a variable, or either with a power.
FACTOR = rf"(?:{VAR}|log {VAR}|log<sup>2</sup> {VAR}|\d+<sup>{VAR}</sup>)(?:<sup>\d+</sup>)?"
TERM = rf"{FACTOR}(?: {FACTOR})*"
BOUND = re.compile(rf"{re.escape(O)}\((?:1|{TERM}(?: \+ {TERM})*)\)")

LINE = re.compile(
    r'<span class="complexity">\s*'
    r'<span><span class="complexity-label">時間計算量</span> (?P<time>[^\n]*?)</span>\s*'
    r'<span><span class="complexity-label">空間計算量</span> (?P<space>[^\n]*?)</span>\s*'
    r'(?:<span class="complexity-where">(?P<where>.*?)</span>\s*)?'
    r'</span>', re.S)


def problems(page, typ):
    """What is wrong with a WRITE or DEBUG page's complexity line."""
    start = page.find('<details class="answer"')
    if start == -1:
        return ["answer section (<details class=\"answer\">) not found"]
    answer = page[start:]
    found = answer.count('class="complexity"')
    if found != 1:
        return [f"the answer needs exactly one complexity line (<span class=\"complexity\">), found {found}"]
    if typ == "write":
        place = r'<summary>Reference\s*<span class="complexity">(?:(?!</summary>).)*</summary>'
        where = "inside <summary>Reference …</summary>"
    else:
        place = r'<h3 class="right">Right\s*<span class="complexity">(?:(?!</h3>).)*</h3>\s*<pre class="code">'
        where = "inside <h3 class=\"right\">Right …</h3>, right before the Right listing"
    if not re.search(place, answer, re.S):
        return [f"the complexity line must be {where}"]

    m = LINE.search(answer)
    if not m:
        return ['the complexity line must be <span class="complexity"><span>時間計算量 …</span> <span>空間計算量 …</span> '
                '[<span class="complexity-where">…</span>] (see script/complexity.py)']
    out = []
    used = set()
    for name, label in (("time", "時間計算量"), ("space", "空間計算量")):
        bound = m.group(name).strip()
        if "\U0001D4AA" in bound or bound.startswith(("O(", "&#x4F;(", "&#79;(")):
            out.append(f"{label}: write 𝒪 as {O}, not the character or a Latin O: {bound!r}")
        elif not BOUND.fullmatch(bound):
            out.append(f"{label}: not a plain big-O bound: {bound!r} "
                       "(1, <var>n</var>, log <var>n</var>, <sup>2</sup>, products, +)")
        used |= set(re.findall(r"<var>([a-z])</var>", bound))
    defined = set(re.findall(r"<var>([a-z])</var> は", m.group("where") or ""))
    for v in sorted(used - defined):
        out.append(f"variable {v} is used in a bound but not defined in the complexity-where span "
                   f"(\"<var>{v}</var> は …\")")
    for v in sorted(defined - used):
        out.append(f"variable {v} is defined in the complexity-where span but no bound uses it")
    if m.group("where") is not None and not used and not defined:
        out.append("the complexity-where span is there but no bound uses a variable: drop it")
    return out


def main(args):
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    bad = False
    for name in args:
        typ = name.replace("\\", "/").split("/")[-4] if name.count("/") >= 3 else ""
        if typ not in ("write", "debug"):
            sys.exit(f"error: {name}: not a WRITE or DEBUG page ({{lang}}/{{type}}/YYYY/MM/*.html)")
        for p in problems(open(name, encoding="utf-8").read(), typ):
            bad = True
            print(f"{name}: {p}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
