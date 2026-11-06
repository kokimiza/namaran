#!/usr/bin/env python3
"""Namaran syntax highlighter.

An *authoring aid*, like script/content.py: it rewrites the code listings of
drill pages in place, so the site keeps shipping plain static HTML with no
client JS (the CSP forbids it) and no build step (the output is committed).

Usage:
  script/highlight.py [--check] FILE ...

  FILE is a drill page, {lang}/{type}/YYYY/MM/*.html; the language is read from the
  path. Every <pre class="code"><code>…</code></pre> block is re-lexed and its
  tokens wrapped in <span class="…">. Existing spans are stripped first, so
  running it again — after editing the code, or on an already highlighted
  page — always gives the same result.

  --check  change nothing; exit 1 and list the files whose listings are not
           exactly what this script would write. script/verify.py uses this
           as a gate, so a page cannot be published unhighlighted or with
           hand-edited spans.

New templates opt in with <main class="drill">. Their tokens are also
wrapped in code-line spans; CSS adds the gutter numbers and diff marks.
Legacy pages retain their original token-only markup.

On those pages the answer listings are also marked as a diff, the way git
shows one. DEBUG: Wrong is diffed against Right. WRITE: the reference
(.diff-added) is diffed against the question's listing. Lines both sides
share stay plain; only changed lines become code-line del / code-line ins,
and in a changed line with a similar partner on the other side, the words
that changed are wrapped in <span class="chg">. An excerpt may be shifted
left as a whole, so lines are first matched on their text alone to find
that shift, then matched again with indentation taken into account.

Only the markup changes: for every block, the text a reader sees (spans
removed, entities decoded) is asserted to be identical before and after.
Output escapes only < > & (as &lt; &gt; &amp;), the same set the pages use.

Token classes (colours live in style.css, "syntax" section):
  kw keyword   ty type / constructor   fn function name   st string / char
  nu number / literal constant   cm comment   pp preprocessor, attribute,
  pragma   mc macro call, Zig builtin (@import)   lt lifetime, label
  op Haskell reserved operator

The lexers are deliberately small, regex-based, and wrong in the corners
(no nested block comments, no C++ context-sensitive keywords). A token
they misjudge gets the wrong colour, never different text.
"""

import collections
import difflib
import html
import itertools
import pathlib
import re
import sys

from namaran import LANGS

BLOCK = re.compile(r'(<pre class="code"><code>)(.*?)(</code></pre>)', re.S)
SPAN = re.compile(r'</?span\b[^>]*>')


def words(s):
    return frozenset(s.split())


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def plain(markup):
    return html.unescape(SPAN.sub("", markup))


def next_char(text, end):
    m = re.compile(r"[ \t]*(.?)").match(text, end)
    return m.group(1)


def at_line_start(text, pos):
    return text[text.rfind("\n", 0, pos) + 1:pos].strip() == ""


# ---------- C / C++ ----------

C_KW = words("""
    alignas alignof auto break case const constexpr continue default do else
    enum extern for goto if inline register restrict return sizeof static
    static_assert struct switch thread_local typedef typeof typeof_unqual union
    volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert
    _Thread_local""")
CPP_KW = C_KW | words("""
    and and_eq bitand bitor catch class co_await co_return co_yield compl
    concept const_cast consteval constinit contract_assert decltype delete
    dynamic_cast explicit export final friend import module mutable namespace
    new noexcept not not_eq operator or or_eq override post pre private
    protected public reinterpret_cast requires static_cast template this throw
    try typeid typename using virtual xor xor_eq""")
C_TY = words("""
    void char short int long float double signed unsigned bool _Bool _BitInt
    _Complex _Decimal32 _Decimal64 _Decimal128 FILE va_list""")
CPP_TY = C_TY | words("""
    wchar_t char8_t char16_t char32_t string string_view vector array map
    unordered_map set unordered_set multimap multiset deque list forward_list
    optional variant any expected unique_ptr shared_ptr weak_ptr span mdspan
    pair tuple function initializer_list ostream istream iostream
    stringstream ostringstream istringstream atomic mutex thread jthread
    lock_guard scoped_lock unique_lock generator""")
C_LIT = words("true false nullptr NULL")
DECL_KW = words("struct enum union class concept namespace typename")
NO_CALL = words("if while for switch return sizeof alignof typeof decltype")

C_RULES = [
    ("ws", r"\s+"),
    ("cm", r"//[^\n]*|/\*[\s\S]*?(?:\*/|\Z)"),
    ("dir", r"#[ \t]*[A-Za-z_]\w*"),
    ("hdr", r"<[^<>\n]*>"),
    ("st", r'(?:u8|u|U|L)?R"([^()\\\s]{0,16})\([\s\S]*?\)\1"'),
    ("st", r'(?:u8|u|U|L)?"(?:\\.|[^"\\\n])*"'),
    ("st", r"(?:u8|u|U|L)?'(?:\\.|[^'\\\n])+'"),
    ("nu", r"(?:0[xX][0-9a-fA-F']+|0[bB][01']+|\d[\d']*(?:\.\d[\d']*)?(?:[eE][+-]?\d+)?|\.\d[\d']*(?:[eE][+-]?\d+)?)[uUlLfFzZ]*"),
    ("id", r"[A-Za-z_]\w*"),
    ("x", r"[\s\S]"),
]


def c_like(cpp):
    kw, ty = (CPP_KW, CPP_TY) if cpp else (C_KW, C_TY)

    def classify(kind, tok, text, pos, end, prev):
        if kind == "dir":
            return "pp" if at_line_start(text, pos) else None
        if kind == "hdr":
            # only a header name right after #include; otherwise it is a
            # template argument list or a comparison, lexed char by char
            return "st" if prev == ("pp", "include") else False
        if kind != "id":
            return kind if kind in ("cm", "st", "nu") else None
        if tok in C_LIT:
            return "nu"
        if tok in kw:
            return "kw"
        if tok in ty or tok.endswith("_t"):
            return "ty"
        if prev and prev[1] in DECL_KW:
            return "ty"
        if next_char(text, end) == "(" and tok not in NO_CALL:
            return "fn"
        if re.fullmatch(r"[A-Z][A-Z0-9_]+", tok):
            return "nu"
        if tok[0].isupper():
            return "ty"
        return None

    return C_RULES, classify


# ---------- Rust ----------

RS_KW = words("""
    as async await break const continue crate dyn else enum extern fn for gen
    if impl in let loop match mod move mut pub ref return self static struct
    super trait type unsafe use where while yield""")
RS_TY = words("""
    i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str
    Self""")
RS_LIT = words("true false")

RS_RULES = [
    ("ws", r"\s+"),
    ("cm", r"//[^\n]*|/\*[\s\S]*?(?:\*/|\Z)"),
    ("pp", r"#!?\[[^\]\n]*\]"),
    ("st", r'b?r(#*)"[\s\S]*?"\1'),
    ("st", r'b?"(?:\\[\s\S]|[^"\\])*"'),
    ("st", r"b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)|[^'\\\n])'"),
    ("lt", r"'[A-Za-z_]\w*"),
    ("nu", r"(?:0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?)(?:[iu](?:8|16|32|64|128|size)|f32|f64)?"),
    ("id", r"(?:r#)?[A-Za-z_]\w*(?:!(?!=))?"),
    ("x", r"[\s\S]"),
]


def rs_classify(kind, tok, text, pos, end, prev):
    if kind != "id":
        return kind if kind in ("cm", "st", "nu", "pp", "lt") else None
    if tok.endswith("!"):
        return "mc"
    after = text[end:end + 3]
    if tok in RS_LIT:
        return "nu"
    if tok in RS_KW:
        return "kw"
    if tok in RS_TY:
        return "ty"
    if prev == ("kw", "fn"):
        return "fn"
    if next_char(text, end) == "(" or after == "::<":
        return "fn"
    if re.fullmatch(r"[A-Z][A-Z0-9_]+", tok):
        return "nu"
    if tok[0].isupper():
        return "ty"
    return None


# ---------- Haskell ----------

HS_KW = words("""
    case class data default deriving do else foreign if import in infix infixl
    infixr instance let module newtype of then type where qualified as hiding""")
HS_OP = words(":: -> <- =>")
HS_SYM = r"!#$%&*+./<=>?@\\^|~:"

HS_RULES = [
    ("ws", r"\s+"),
    ("pp", r"\{-#[\s\S]*?(?:#-\}|\Z)"),
    ("cm", r"\{-[\s\S]*?(?:-\}|\Z)"),
    ("cm", rf"--+(?![-{HS_SYM}])[^\n]*"),
    ("st", r'"(?:\\[\s\S]|[^"\\\n])*"'),
    ("st", r"'(?:\\(?:[^\s']+|')|[^'\\\n])'"),
    ("nu", r"0[xX][0-9a-fA-F]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"),
    ("ty", r"(?:[A-Z][\w']*\.)*[A-Z][\w']*"),
    ("id", r"[a-z_][\w']*"),
    ("sym", rf"[-{HS_SYM}]+"),
    ("x", r"[\s\S]"),
]


def hs_classify(kind, tok, text, pos, end, prev):
    if kind == "sym":
        return "op" if tok in HS_OP else None
    if kind != "id":
        return kind if kind in ("cm", "st", "nu", "pp", "ty") else None
    if tok in HS_KW:
        return "kw"
    if text[pos - 1:pos] in ("", "\n"):
        return "fn"  # a top-level binding: the name being defined
    return None


# ---------- Zig ----------
# The keywords and primitive types are std/zig/tokenizer.zig's and
# std/zig/primitives.zig's lists as of Zig 0.17.

ZIG_KW = words("""
    addrspace align allowzero and anyframe anytype asm break callconv catch
    comptime const continue defer else enum errdefer error export extern fn
    for if inline linksection noalias noinline nosuspend opaque or orelse
    packed pub resume return struct suspend switch test threadlocal try union
    unreachable var volatile while""")
ZIG_TY = words("""
    anyerror anyframe anyopaque bool c_char c_short c_ushort c_int c_uint
    c_long c_ulong c_longlong c_ulonglong c_longdouble comptime_float
    comptime_int f16 f32 f64 f80 f128 isize noreturn type usize void""")
ZIG_LIT = words("true false null undefined")
# What a label (blk:, outer:) can be put in front of.
ZIG_LABELED = re.compile(r":\s*(?:\{|(?:inline\s+)?(?:while|for)\b|switch\b)")

ZIG_RULES = [
    ("ws", r"\s+"),
    ("cm", r"//[^\n]*"),
    ("st", r"\\\\[^\n]*"),
    ("qid", r'@"(?:\\.|[^"\\\n])*"'),
    ("mc", r"@[A-Za-z_]\w*"),
    ("st", r'"(?:\\.|[^"\\\n])*"'),
    ("st", r"'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^'\\\n])'"),
    ("nu", r"0x[0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?\d[\d_]*)?|0o[0-7_]+|0b[01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d[\d_]*)?"),
    ("lbl", r":[A-Za-z_]\w*"),
    ("id", r"[A-Za-z_]\w*"),
    ("x", r"[\s\S]"),
]


def zig_classify(kind, tok, text, pos, end, prev):
    if kind == "lbl":
        # only the target of break :blk / continue :outer; otherwise the
        # colon is a type annotation or a sentinel, lexed char by char
        return "lt" if prev in (("kw", "break"), ("kw", "continue")) else False
    if kind != "id":
        return kind if kind in ("cm", "st", "nu", "mc") else None
    if tok in ZIG_LIT:
        return "nu"
    if tok in ZIG_KW:
        return "kw"
    if tok in ZIG_TY or re.fullmatch(r"[iu]\d+", tok):
        return "ty"
    if prev == ("kw", "fn"):
        return "fn"
    if ZIG_LABELED.match(text, end):
        return "lt"
    if re.fullmatch(r"[A-Z][A-Z0-9_]+", tok):
        return "nu"
    if tok[0].isupper():
        return "ty"  # types are TitleCase, and so are functions returning one
    if next_char(text, end) == "(":
        return "fn"
    return None


# ---------- driver ----------

LEXERS = {
    "c": c_like(cpp=False),
    "cpp": c_like(cpp=True),
    "rust": (RS_RULES, rs_classify),
    "haskell": (HS_RULES, hs_classify),
    "zig": (ZIG_RULES, zig_classify),
}
COMPILED = {
    lang: [(kind, re.compile(rx)) for kind, rx in rules]
    for lang, (rules, _) in LEXERS.items()
}


def lex(lang, text):
    classify = LEXERS[lang][1]
    rules = COMPILED[lang]
    pos, prev, out = 0, None, []
    while pos < len(text):
        for kind, rx in rules:
            m = rx.match(text, pos)
            if not m or m.end() == pos:
                continue
            cls = classify(kind, m.group(0), text, pos, m.end(), prev)
            if cls is False:
                continue  # rule declined in this context; try the next one
            break
        tok = m.group(0)
        out.append((tok, cls))
        if kind == "dir":
            prev = ("pp", tok.lstrip("#").strip())
        elif kind not in ("ws", "cm"):
            prev = (cls, tok)
        pos = m.end()
    return out


# ---------- diff marks ----------
# Answer listings on new templates are drawn as a diff (see the header):
# shared lines plain, changed lines del / ins, changed words chg.

# Words, runs of spaces, multi-character operators, then single characters.
WORD = re.compile(r"\w+|\s+|<<=|>>=|\.\.\.|\.\.=|::|->|=>|<-|<<|>>|<=|>=|==|!=|&&|\|\|"
                  r"|\+\+|--|[-+*/%&|^]=|\.\.|[^\w\s]")
# Two changed lines are paired, and their changed words marked, only if at
# least this share of their visible characters is common to both.
SIMILAR = 0.35


def source_lines(text):
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()  # the trailing LF ends the last line, it does not start one
    return lines


def indent(line):
    return len(line) - len(line.lstrip(" \t"))


def visible(s):
    return len(s) - sum(c.isspace() for c in s)


def join(x, y):
    """The smallest span covering two spans, either of which may be None."""
    if not (x and y):
        return x or y
    return (min(x[0], y[0]), max(x[1], y[1]))


def word_diff(a, b):
    """(similarity, ranges in a, ranges in b) for two lines.

    Ranges are (start, end) character offsets of the changed words. Changes
    separated by nothing but spaces and at most one visible character are
    reported as one: `32 - k` against `31 / k * k` is one edit, not three.
    """
    ta, tb = WORD.findall(a), WORD.findall(b)
    oa, ob = [0], [0]
    for t in ta:
        oa.append(oa[-1] + len(t))
    for t in tb:
        ob.append(ob[-1] + len(t))
    ops = difflib.SequenceMatcher(None, ta, tb, autojunk=False).get_opcodes()
    total = visible(a) + visible(b)
    same = sum(visible("".join(ta[i1:i2])) for tag, i1, i2, _, _ in ops if tag == "equal")
    score = 2 * same / total if total else 1.0

    # Each group: the span it changes in a and in b, or None where that side
    # is untouched (a pure insertion leaves a alone).
    groups = []
    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            continue
        span_a = (oa[i1], oa[i2]) if i2 > i1 else None
        span_b = (ob[j1], ob[j2]) if j2 > j1 else None
        if groups and visible("".join(ta[groups[-1][2]:i1])) <= 1:
            last = groups[-1]
            last[0] = join(last[0], span_a)
            last[1] = join(last[1], span_b)
            last[2] = i2
        else:
            groups.append([span_a, span_b, i2])

    def trimmed(line, span):
        start, end = span
        part = line[start:end]
        if part.strip():
            start += len(part) - len(part.lstrip())
            end -= len(part) - len(part.rstrip())
        return start, end

    ra = [trimmed(a, g[0]) for g in groups if g[0]]
    rb = [trimmed(b, g[1]) for g in groups if g[1]]
    return score, ra, rb


def pair_lines(old, new):
    """Pairs (i, j) of similar lines, in order, with the most similarity overall."""
    n, m = len(old), len(new)
    score = [[word_diff(a, b)[0] for b in new] for a in old]
    best = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            take = score[i][j] + best[i + 1][j + 1] if score[i][j] >= SIMILAR else -1.0
            best[i][j] = max(best[i + 1][j], best[i][j + 1], take)
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        if score[i][j] >= SIMILAR and best[i][j] == score[i][j] + best[i + 1][j + 1]:
            pairs.append((i, j))
            i, j = i + 1, j + 1
        elif best[i][j] == best[i + 1][j]:
            i += 1
        else:
            j += 1
    return pairs


def diff(old_text, new_text, words=True):
    """Marks for each line of both listings: None, or (kind, changed ranges)."""
    old, new = source_lines(old_text), source_lines(new_text)
    flat_old = [" ".join(line.split()) for line in old]
    flat_new = [" ".join(line.split()) for line in new]

    def match(shift):
        # Blank lines match each other at any indentation.
        ko = [(indent(l), f) if f else None for l, f in zip(old, flat_old)]
        kn = [(indent(l) - shift, f) if f else None for l, f in zip(new, flat_new)]
        ops = difflib.SequenceMatcher(None, ko, kn, autojunk=False).get_opcodes()
        shared = sum(1 for tag, i1, i2, _, _ in ops if tag == "equal"
                     for i in range(i1, i2) if flat_old[i])
        return shared, ops

    # An excerpt may be shifted left as a whole, so first match lines on
    # their text alone and see how far apart the shared ones are indented.
    # Then match again with indentation, so `}` closes the block it closed
    # and a line that only moved in or out counts as changed.
    flat = difflib.SequenceMatcher(None, flat_old, flat_new, autojunk=False).get_opcodes()
    shifts = collections.Counter(
        indent(new[j1 + k]) - indent(old[i1 + k])
        for tag, i1, i2, j1, j2 in flat if tag == "equal"
        for k in range(i2 - i1) if flat_old[i1 + k]
    )
    known = bool(shifts)  # with no shared line, indentation is not compared
    shift = max(shifts or [0], key=lambda s: (match(s)[0], shifts[s], -abs(s)))
    ops = match(shift)[1]

    mo, mn = [None] * len(old), [None] * len(new)

    def pair(i, j):
        a, b = old[i], new[j]
        ia, ib = indent(a), indent(b)
        if known and ib - ia != shift:
            ia = ib = 0  # the indentation itself changed: diff it too
        _, ra, rb = word_diff(a[ia:], b[ib:])
        mo[i] = ("del", [(s + ia, e + ia) for s, e in ra])
        mn[j] = ("ins", [(s + ib, e + ib) for s, e in rb])

    for tag, i1, i2, j1, j2 in ops:
        if tag == "equal":
            continue
        for i in range(i1, i2):
            mo[i] = ("del", [])
        for j in range(j1, j2):
            mn[j] = ("ins", [])
        if words:
            for i, j in pair_lines(old[i1:i2], new[j1:j2]):
                pair(i1 + i, j1 + j)
    return mo, mn


# ---------- rendering ----------

def render(lang, raw, numbered=False, marks=None):
    text = plain(raw)
    merged = []
    for tok, cls in lex(lang, text):
        if merged and merged[-1][1] == cls:
            merged[-1][0] += tok
        else:
            merged.append([tok, cls])

    def token(tok, cls):
        return f'<span class="{cls}">{esc(tok)}</span>' if cls else esc(tok)

    def line(segments, mark):
        kind, ranges = mark or (None, [])
        # Cut tokens where a changed range starts or ends, then wrap each run
        # of changed pieces in one chg span.
        cuts = sorted({p for r in ranges for p in r})
        pieces, pos = [], 0
        for tok, cls in segments:
            points = [pos] + [p for p in cuts if pos < p < pos + len(tok)] + [pos + len(tok)]
            for s, e in zip(points, points[1:]):
                changed = any(rs <= s and e <= re_ for rs, re_ in ranges)
                pieces.append((tok[s - pos:e - pos], cls, changed))
            pos += len(tok)
        body = []
        for changed, run in itertools.groupby(pieces, key=lambda p: p[2]):
            toks = []
            for tok, cls, _ in run:
                if toks and toks[-1][1] == cls:
                    toks[-1][0] += tok
                else:
                    toks.append([tok, cls])
            inner = "".join(token(tok, cls) for tok, cls in toks)
            body.append(f'<span class="chg">{inner}</span>' if changed else inner)
        name = f"code-line {kind}" if kind else "code-line"
        return f'<span class="{name}">' + "".join(body) + "</span>"

    if numbered:
        # Split tokens after lexing, so multiline strings/comments keep their
        # colour. Newlines stay outside the line wrappers: stripping spans
        # recovers the exact source, including blank lines and a trailing LF.
        rows = [[]]
        for tok, cls in merged:
            for i, part in enumerate(tok.split("\n")):
                if i:
                    rows.append([])
                if part:
                    rows[-1].append((part, cls))
        ends_with_lf = not rows[-1]
        if ends_with_lf:
            rows.pop()
        marks = marks or [None] * len(rows)
        out = "\n".join(line(row, mark) for row, mark in zip(rows, marks))
        if ends_with_lf and rows:
            out += "\n"
    else:
        out = "".join(token(tok, cls) for tok, cls in merged)
    if plain(out) != text:
        sys.exit("internal error: highlighting changed the code text")
    return out


def role(page, start):
    """What a listing is, from the markup right before it."""
    head = page[max(0, start - 400):start]
    if re.search(r'<h3 class="wrong">[^<]*</h3>\s*\Z', head):
        return "wrong"
    if re.search(r'<h3 class="right">[^<]*</h3>\s*\Z', head):
        return "right"
    if re.search(r'<div class="code-frame diff-added"[^>]*>\s*'
                 r'(?:<p class="code-filename">[^<]*</p>\s*)?\Z', head):
        return "added"
    return None


def highlight(path):
    parents = path.resolve().parents
    lang = parents[3].name if len(parents) > 3 else ""
    if lang not in LANGS:
        sys.exit(f"error: {path}: not a drill page ({{lang}}/{{type}}/YYYY/MM/*.html)")
    before = path.read_text(encoding="utf-8")
    # New templates opt in; published pages keep their original markup.
    numbered = bool(re.search(r'<main\b[^>]*\bclass="[^"]*\bdrill\b[^"]*"', before))
    blocks = list(BLOCK.finditer(before))
    texts = [plain(m.group(2)) for m in blocks]
    marks = [None] * len(blocks)
    if numbered:
        roles = [role(before, m.start()) for m in blocks]
        wrong = [i for i, r in enumerate(roles) if r == "wrong"]
        right = [i for i, r in enumerate(roles) if r == "right"]
        for i, j in zip(wrong, right):
            marks[i], marks[j] = diff(texts[i], texts[j])
        for j, r in enumerate(roles):
            if r != "added":
                continue
            # A WRITE reference: what the reader adds to the question's listing.
            base = next((i for i in range(j) if roles[i] is None), None)
            marks[j] = diff(texts[base] if base is not None else "", texts[j], words=False)[1]
    out, pos = [], 0
    for m, mark in zip(blocks, marks):
        out += [before[pos:m.start(2)], render(lang, m.group(2), numbered, mark)]
        pos = m.end(2)
    out.append(before[pos:])
    return before, "".join(out)


def is_stale(path):
    """Whether a page's listings differ from what this script writes."""
    before, after = highlight(pathlib.Path(path))
    return before != after


def main(args):
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    check = args[0] == "--check"
    files = args[1:] if check else args
    if not files:
        sys.exit("error: no files given")

    stale = []
    for name in files:
        path = pathlib.Path(name)
        before, after = highlight(path)
        if before == after:
            continue
        stale.append(name)
        if not check:
            path.write_text(after, encoding="utf-8")

    if check:
        for name in stale:
            print(f"not highlighted (run script/highlight.py {name}): {name}")
        sys.exit(1 if stale else 0)
    for name in stale:
        print(f"highlighted: {name}")


if __name__ == "__main__":
    main(sys.argv[1:])
