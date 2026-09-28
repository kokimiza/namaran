#!/usr/bin/env bash
# Namaran drill patch guard.
#
# The namara-daily workflow lets Claude Code run arbitrary commands in its
# `write` job, so everything that job hands on — the patch with the day's
# pages — is untrusted input. This script is the boundary: the `verify` and
# `publish` jobs run it from their own checkout of main (never from the
# patch) before applying the patch. Anything it doesn't recognize is
# rejected; it never tries to repair a patch.
#
# Usage:
#   script/check-patch.sh DATE PATCH_FILE LANG/TYPE[=LEVEL] ...
#
#   LEVEL is the difficulty script/level.sh drew for that combo before
#   Claude ran (hedgehog, peacock, bison or whale). When it is given, the
#   page must carry exactly that level: a drill does not get to be easier
#   than the day's draw said.
#
# A patch passes only if all of the following hold:
#   * DATE is YYYY-MM-DD and every LANG/TYPE is one of the 12 combos
#   * it is a plain text git diff: no binary hunks, renames, copies,
#     deletions or mode changes
#   * every file it touches is, for one of the given combos, either
#       {lang}/{type}/DATE.html   created as a new regular file (100644), or
#       {lang}/{type}/archive.html   modified, only by adding lines of the
#                                    exact form content.sh writes for DATE,
#     or script/tags.tsv, modified only by adding "slug<TAB>name" lines for
#     tags the day's own pages use (doc/basic-design.md §7.4)
#   * each new page carries its topic metadata on <main> (data-topic,
#     data-tags, data-concepts — doc/basic-design.md §7.1, §7.4) in the
#     shape script/topics.sh will copy into the archives and topics.html,
#     and its difficulty (data-level), matching the drawn LEVEL if one was
#     given
#   * each new page, as the patch creates it, contains no active or external
#     content: no <script> other than the one JSON-LD block, no inline event
#     handlers, no javascript: URLs, no <iframe>/<object>/<embed>/<form>/
#     <base>/<style>/<img>/<svg>/<meta http-equiv>, and no <link> other than
#     the page's canonical URL and /style.css. The site's CSP (_headers)
#     already blocks all of these in the browser; this keeps them from being
#     published at all.

set -euo pipefail

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  ""|-h|--help|help) usage; exit 0 ;;
esac
[ "$#" -ge 3 ] || { usage >&2; exit 2; }

exec python3 - "$@" <<'PY'
import re
import sys
from html.parser import HTMLParser

SITE = "https://namaran.jocarium.productions"
LANGS = ("c", "cpp", "rust", "haskell")
TYPES = ("read", "write", "debug")
LEVELS = ("hedgehog", "peacock", "bison", "whale")

SITE_TAGS = "script/tags.tsv"
TAGS_FILE = SITE_TAGS

date, patch_file, *combos = sys.argv[1:]
problems = []
# Tags the day's pages use, and the vocabulary lines the patch adds for them.
used_tags, tag_lines = set(), []

def fail(msg):
    problems.append(msg)

if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])", date):
    sys.exit(f"error: not a YYYY-MM-DD date: {date!r}")
allowed_pages, allowed_archives, drawn_levels = {}, {}, {}
for combo in combos:
    combo, _, level = combo.partition("=")
    lang, _, typ = combo.partition("/")
    if lang not in LANGS or typ not in TYPES:
        sys.exit(f"error: not a LANG/TYPE combo: {combo!r}")
    if level and level not in LEVELS:
        sys.exit(f"error: not a level ({', '.join(LEVELS)}): {level!r}")
    allowed_pages[f"{lang}/{typ}/{date}.html"] = (lang, typ)
    drawn_levels[f"{lang}/{typ}/{date}.html"] = level
    allowed_archives[f"{lang}/{typ}/archive.html"] = (lang, typ)

with open(patch_file, "rb") as f:
    raw = f.read()
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError:
    sys.exit("REJECT: patch is not valid UTF-8")
if "\r" in text:
    sys.exit("REJECT: patch contains carriage returns")

# Split into per-file sections on "diff --git" headers.
sections = re.split(r"^(?=diff --git )", text, flags=re.M)
if sections and not sections[0].startswith("diff --git "):
    if sections[0].strip():
        fail("patch has content before the first diff header")
    sections = sections[1:]
if not sections:
    fail("patch is empty")

seen = set()
for sec in sections:
    lines = sec.split("\n")
    m = re.fullmatch(r"diff --git a/(\S+) b/(\S+)", lines[0])
    if not m or m.group(1) != m.group(2):
        fail(f"unexpected diff header: {lines[0][:120]!r}")
        continue
    path = m.group(1)
    if path in seen:
        fail(f"{path}: appears more than once")
    seen.add(path)

    # Extended header lines before the first hunk.
    header, body_start = [], None
    for i, line in enumerate(lines[1:], start=1):
        if line.startswith("@@"):
            body_start = i
            break
        header.append(line)
    if body_start is None:
        fail(f"{path}: no hunks (mode-only, empty or binary change)")
        continue
    for h in header:
        if re.fullmatch(r"index [0-9a-f]+\.\.[0-9a-f]+( 100644)?", h):
            continue
        if h in (f"--- a/{path}", f"+++ b/{path}", "--- /dev/null", "new file mode 100644"):
            continue
        fail(f"{path}: disallowed header line {h[:80]!r}")

    hunk = lines[body_start:]
    if hunk and hunk[-1] == "":
        hunk = hunk[:-1]
    added = [l[1:] for l in hunk if l.startswith("+")]
    removed = [l for l in hunk if l.startswith("-")]
    others = [l for l in hunk if not (l.startswith(("+", "-", " ", "@@")) or l == "\\ No newline at end of file")]
    if others:
        fail(f"{path}: malformed hunk line {others[0][:80]!r}")

    if path in allowed_pages:
        lang, typ = allowed_pages[path]
        if "new file mode 100644" not in header or "--- /dev/null" not in header:
            fail(f"{path}: must be created as a new regular file")
        if removed or any(l.startswith(" ") for l in hunk):
            fail(f"{path}: a new page must consist of added lines only")
        page = "\n".join(added)
        check_page = True
    elif path == TAGS_FILE:
        if any(h.startswith(("new file", "--- /dev/null")) for h in header):
            fail(f"{path}: must already exist")
        if removed:
            fail(f"{path}: must not remove or change existing lines")
        tag_lines = added
        check_page = False
    elif path in allowed_archives:
        lang, typ = allowed_archives[path]
        if any(h.startswith(("new file", "--- /dev/null")) for h in header):
            fail(f"{path}: archive.html must already exist")
        if removed:
            fail(f"{path}: must not remove lines")
        entry = f'    <li><a href="/{lang}/{typ}/{date}">{date}</a></li>'
        if added != [entry]:
            fail(f"{path}: may only add the line {entry.strip()!r}")
        check_page = False
    else:
        fail(f"{path}: not a file this run may change")
        check_page = False

    if not check_page:
        continue

    low = page.lower()

    # Exactly one script element, the JSON-LD block. Inside it, "<!--" or a
    # second "<script" would switch the HTML parser into script-data escape
    # states, where "</script>" no longer ends the block.
    jsonld_open = '<script type="application/ld+json">'
    if re.findall(r"<script\b[^>]*>", low) != [jsonld_open] or low.count("</script") != 1:
        fail(f"{path}: must contain exactly one {jsonld_open} and no other script")
        markup = low
    else:
        before, rest = low.split(jsonld_open, 1)
        jsonld, after = rest.split("</script", 1)
        if "<!--" in jsonld:
            fail(f"{path}: '<!--' inside the JSON-LD block")
        markup = before + after

    # Everything else is checked on the tags an HTML parser actually sees, by
    # allowlist: unknown elements, attributes or link targets are rejected.
    allowed_elements = {
        "html", "head", "meta", "title", "link", "body", "div", "header", "h1", "h2", "h3",
        "p", "a", "nav", "main", "pre", "code", "details", "summary", "aside", "ul", "ol", "li",
        "footer", "strong", "em", "br", "span", "kbd", "var", "samp", "sup", "sub",
        "table", "thead", "tbody", "tr", "th", "td", "blockquote", "hr",
    }
    allowed_attrs = {"lang", "charset", "name", "content", "rel", "href", "class", "aria-label", "aria-current"}
    # The drill's subject, carried as metadata so the page itself can stay
    # quiet (doc/basic-design.md §7.1). script/topics.sh copies these into
    # the archive lists and topics.html, so they are checked here, at the
    # boundary, before anything written by the write job reaches a page.
    main_attrs = {"data-topic", "data-tags", "data-concepts", "data-level"}
    tag_re = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")

    def check_main(attrs):
        d = dict(attrs)
        missing = sorted(main_attrs - set(d))
        if missing:
            fail(f"{path}: <main> is missing {', '.join(missing)}")
        topic = (d.get("data-topic") or "").strip()
        if not topic or len(topic) > 120:
            fail(f"{path}: data-topic must be 1-120 characters, got {len(topic)}")
        used_tags.update((d.get("data-tags") or "").split())
        tags = (d.get("data-tags") or "").split()
        if not 2 <= len(tags) <= 8:
            fail(f"{path}: data-tags must hold 2-8 tags, got {len(tags)}")
        for tag in tags:
            if not tag_re.match(tag):
                fail(f"{path}: tag {tag!r} is not lowercase kebab-case ASCII")
        concepts = [c.strip() for c in (d.get("data-concepts") or "").split(",") if c.strip()]
        if not 2 <= len(concepts) <= 12 or any(len(c) > 60 for c in concepts):
            fail(f"{path}: data-concepts must hold 2-12 wordings of at most 60 characters")
        level = d.get("data-level")
        if level not in LEVELS:
            fail(f"{path}: data-level must be one of {', '.join(LEVELS)}, got {level!r}")
        elif drawn_levels[path] and level != drawn_levels[path]:
            fail(f"{path}: data-level is {level!r}, but the draw for this drill was {drawn_levels[path]!r}")
        for value in d.values():
            if re.search(r"[\x00-\x1f\x7f]", value or ""):
                fail(f"{path}: control character in a <main> attribute")
    expected_links = {
        ("canonical", f"{SITE}/{lang}/{typ}/{date}"),
        ("stylesheet", "/style.css"),
    }

    def href_ok(value):
        return (value.startswith("/") and not value.startswith("//")) \
            or value.startswith(SITE + "/") or value == SITE \
            or value == "https://github.com/kokimiza/namara/issues"

    class Guard(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.links = []

        def handle_starttag(self, tag, attrs):
            if tag not in allowed_elements:
                fail(f"{path}: disallowed element <{tag}>")
                return
            for attr, value in attrs:
                if attr in main_attrs:
                    if tag != "main":
                        fail(f"{path}: {attr!r} belongs on <main>, not <{tag}>")
                elif attr not in allowed_attrs:
                    fail(f"{path}: disallowed attribute {attr!r} on <{tag}>")
                elif attr == "href" and not href_ok(value or ""):
                    fail(f"{path}: unexpected link target {value!r}")
            if tag == "main":
                check_main(attrs)
            if tag == "link":
                d = dict(attrs)
                self.links.append((d.get("rel"), d.get("href")))

        handle_startendtag = handle_starttag

        def handle_comment(self, data):
            fail(f"{path}: HTML comment")

        def handle_pi(self, data):
            fail(f"{path}: processing instruction")

        def unknown_decl(self, data):
            fail(f"{path}: unknown declaration {data[:40]!r}")

        def handle_decl(self, decl):
            if decl.lower() != "doctype html":
                fail(f"{path}: unexpected declaration {decl[:40]!r}")

    guard = Guard()
    guard.feed(markup)
    guard.close()
    if sorted(map(str, guard.links)) != sorted(map(str, expected_links)):
        fail(f"{path}: <link> elements must be exactly the canonical URL and /style.css, got {guard.links}")

# A new tag needs a Japanese name before it can appear in the index, and the
# vocabulary is shared, so it lives in one file rather than on the page
# (doc/basic-design.md §7.4). That makes script/tags.tsv the one file outside
# {lang}/{type}/ this run may touch — append-only, and only for tags the
# day's own pages use.
for line in tag_lines:
    slug, tab, name = line.partition("\t")
    if not tab or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
        fail(f"{SITE_TAGS}: {line[:60]!r} is not 'slug<TAB>name'")
    elif slug not in used_tags:
        fail(f"{SITE_TAGS}: {slug!r} is not a tag any of this run's pages use")
    elif not name.strip() or len(name.strip()) > 15 or re.search(r"[\x00-\x1f\x7f]", name):
        fail(f"{SITE_TAGS}: {slug!r} needs a name of 1-15 plain characters")

missing = sorted(set(allowed_pages) - seen)
if missing:
    fail("pages missing from the patch: " + ", ".join(missing))

if problems:
    print("REJECT:")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)
print(f"patch OK: {len(seen)} file(s) for {date}")
PY
