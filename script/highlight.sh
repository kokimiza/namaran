#!/usr/bin/env bash
# Namaran syntax highlighter.
#
# An *authoring aid*, like script/content.sh: it rewrites the code listings of
# drill pages in place, so the site keeps shipping plain static HTML with no
# client JS (the CSP forbids it) and no build step (the output is committed).
#
# Usage:
#   script/highlight.sh [--check] FILE ...
#
#   FILE is a drill page, {lang}/{type}/*.html; the language is read from the
#   path. Every <pre class="code"><code>…</code></pre> block is re-lexed and its
#   tokens wrapped in <span class="…">. Existing spans are stripped first, so
#   running it again — after editing the code, or on an already highlighted
#   page — always gives the same result.
#
#   --check  change nothing; exit 1 and list the files whose listings are not
#            exactly what this script would write. script/verify.sh uses this
#            as a gate, so a page cannot be published unhighlighted or with
#            hand-edited spans.
#
# Only the markup changes: for every block, the text a reader sees (spans
# removed, entities decoded) is asserted to be identical before and after.
# Output escapes only < > & (as &lt; &gt; &amp;), the same set the pages use.
#
# Token classes (colours live in style.css, "syntax" section):
#   kw keyword   ty type / constructor   fn function name   st string / char
#   nu number / literal constant   cm comment   pp preprocessor, attribute,
#   pragma   mc macro call   lt lifetime   op Haskell reserved operator
#
# The lexers are deliberately small, regex-based, and wrong in the corners
# (no nested block comments, no C++ context-sensitive keywords). A token
# they misjudge gets the wrong colour, never different text.

set -euo pipefail

case "${1:-}" in
  ""|-h|--help|help) sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

exec python3 - "$@" <<'PY'
import html
import pathlib
import re
import sys

LANGS = ("c", "cpp", "rust", "haskell")
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


# ---------- driver ----------

LEXERS = {
    "c": c_like(cpp=False),
    "cpp": c_like(cpp=True),
    "rust": (RS_RULES, rs_classify),
    "haskell": (HS_RULES, hs_classify),
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


def render(lang, raw):
    text = plain(raw)
    merged = []
    for tok, cls in lex(lang, text):
        if merged and merged[-1][1] == cls:
            merged[-1][0] += tok
        else:
            merged.append([tok, cls])
    out = "".join(
        f'<span class="{cls}">{esc(tok)}</span>' if cls else esc(tok)
        for tok, cls in merged
    )
    if plain(out) != text:
        sys.exit("internal error: highlighting changed the code text")
    return out


def highlight(path):
    lang = path.resolve().parent.parent.name
    if lang not in LANGS:
        sys.exit(f"error: {path}: not a drill page ({{lang}}/{{type}}/*.html)")
    before = path.read_text(encoding="utf-8")
    after = BLOCK.sub(lambda m: m.group(1) + render(lang, m.group(2)) + m.group(3), before)
    return before, after


args = sys.argv[1:]
check = args[:1] == ["--check"]
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
        print(f"not highlighted (run script/highlight.sh {name}): {name}")
    sys.exit(1 if stale else 0)
for name in stale:
    print(f"highlighted: {name}")
PY
