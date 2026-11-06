"""What every Namaran script shares: the fixed lists and the page layout.

The scripts under script/ are authoring aids. They run in GitHub Actions
(and on a writer's machine), never on Cloudflare Pages: the site itself is
static HTML and CSS. Each one is a plain `python3 script/NAME.py` program
using the standard library only; .python-version pins the Python CI sets up.
"""

import datetime
import pathlib
import re
import sys
import zoneinfo

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
SITE = "https://namaran.jocarium.productions"

# Language slug -> plain name (titles, JSON-LD, meta description).
LANGS = {"c": "C", "cpp": "C++", "rust": "Rust", "haskell": "Haskell", "zig": "Zig"}
# The lang-nav buttons name a specific language edition/standard, so readers
# know exactly which dialect a drill assumes. Everywhere else keeps the plain
# name: the edition suffix is a nav-button-only convention. Must match
# CLAUDE.md's version table and index.html.
LANG_NAV_LABELS = {
    "c": "C23",
    "cpp": "C++26",
    "rust": "Rust 2024",
    "haskell": "Haskell 2010",
    "zig": "Zig 0.17",
}
CODE_EXT = {"c": "c", "cpp": "cpp", "rust": "rs", "haskell": "hs", "zig": "zig"}
TYPES = {"read": "READ", "write": "WRITE", "debug": "DEBUG"}
# Difficulty, easiest first: the animal and the level it stands for
# (doc/requirements.md §7).
LEVELS = {
    "hedgehog": ("ハリネズミ", "基礎"),
    "peacock": ("孔雀", "標準"),
    "bison": ("バイソン", "高度"),
    "whale": ("クジラ", "特級"),
}

DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
# A real calendar-shaped date: month 01-12, day 01-31.
STRICT_DATE_RE = re.compile(r"\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])")


def page_file(lang, typ, date):
    """The dated page, relative to the repository root. Pages are filed by
    year and month; the URL stays /{lang}/{typ}/{date}
    (functions/_middleware.js maps one onto the other)."""
    return f"{lang}/{typ}/{date[:4]}/{date[5:7]}/{date}.html"


def today_in_japan():
    """Today in Asia/Tokyo, the day functions/_middleware.js publishes."""
    return datetime.datetime.now(zoneinfo.ZoneInfo("Asia/Tokyo")).strftime("%Y-%m-%d")


def all_combos():
    return [(lang, typ) for lang in LANGS for typ in TYPES]


def parse_combos(args, status=1):
    """LANG/TYPE arguments as (lang, typ) pairs; all 15 when there are none."""
    if not args:
        return all_combos()
    combos = []
    for pair in args:
        lang, slash, typ = pair.partition("/")
        if not slash or lang not in LANGS or typ not in TYPES:
            die(f"expected LANG/TYPE (e.g. c/read), got: {pair}", status)
        combos.append((lang, typ))
    return combos


def die(msg, status=1):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(status)


def wants_help(args):
    """Print the calling script's docstring for -h / --help / help."""
    if args[:1] in (["-h"], ["--help"], ["help"]):
        print(sys.modules["__main__"].__doc__.strip())
        sys.exit(0)
