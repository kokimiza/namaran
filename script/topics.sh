#!/usr/bin/env bash
# Namaran topic index generator.
#
# An authoring aid like script/sitemap.sh: it runs locally or in GitHub
# Actions, never on Cloudflare Pages, and writes plain static files. It
# builds the *index layer* — the one place where a drill's subject is
# written out as words readers and search engines can actually read:
#
#   {lang}/{type}/archive.html   each <li> gets the drill's topic next to
#                                its date
#   topics.html                  the list of tags
#   tag/{tag}.html               one page per tag, listing every drill that
#                                touches that concept
#
# A drill page itself stays quiet: it shows a date, a filename and code, and
# carries its subject as metadata only (doc/basic-design.md §7.1). Naming
# the concept on the page being solved would hand over half the answer; on
# an archive or a topic index, where the point is to find a drill again,
# naming it is exactly what is wanted (§7.3).
#
# Usage:
#   script/topics.sh           rewrite the archive lists and topics.html
#   script/topics.sh --check   exit 1 if either is not up to date
#   script/topics.sh --tags    print the tag vocabulary, most used first
#
# Where each field comes from, per drill page:
#
#   topic     <main data-topic="…">, else the JSON-LD about.name with its
#             "{Language} — " prefix removed. The fallback is what makes the
#             archives complete: pages published before this metadata
#             existed are never edited (§7.1), but every one of them already
#             carries about.name, and that is the same sentence.
#   tags      <main data-tags="…">, space separated, kebab-case (§7.4).
#             Pages older than the metadata have none and so have no tag
#             page — they are reachable through their archive.
#   concepts  <main data-concepts="…">, comma separated. The natural-language
#             wording of the same subject, printed on the tag pages so that a
#             reader searching "値渡し" or "pass by value" lands somewhere.
#
# Which dates exist is *not* decided here: archive.html stays the source of
# truth for what is published (§7.1a), the same file the middleware reads.
# This script only rewrites the text of lines that are already there, so it
# can never publish or unpublish a drill.
#
# Everything it copies out of a page is treated as untrusted text: it is
# HTML-escaped on the way out, and must be short and single-line, or the run
# fails loudly rather than writing something odd into a page. A topic may
# well contain < or > (operator<<, Vec<String>, i <= n) — that is text, and
# it is escaped like any other. The output is deterministic, so
# re-running it with nothing new published is a no-op diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  ""|--check|--tags) ;;
  *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

exec python3 - "$ROOT_DIR" "${1:-}" <<'PY'
import html
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]

SITE = "https://namaran.jocarium.productions"
LANGS = {"c": "C", "cpp": "C++", "rust": "Rust", "haskell": "Haskell"}
TYPES = {"read": "READ", "write": "WRITE", "debug": "DEBUG"}

TAG_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
MAX_TOPIC = 120
MAX_CONCEPT = 60


def die(msg):
    sys.exit(f"error: {msg}")


def clean(value, what, where, limit):
    """One line of plain text, or the run stops. Page content is untrusted."""
    text = html.unescape(value).strip()
    if not text:
        die(f"{where}: empty {what}")
    if len(text) > limit:
        die(f"{where}: {what} is longer than {limit} characters: {text[:40]!r}…")
    if re.search(r"[\x00-\x1f\x7f]", text):
        die(f"{where}: {what} contains a control character: {text[:40]!r}")
    return text


def read_drill(lang, typ, date):
    """topic, tags and concepts for one published page."""
    page = root / lang / typ / f"{date}.html"
    where = f"{lang}/{typ}/{date}.html"
    s = page.read_text(encoding="utf-8")

    m = re.search(r"<main\b[^>]*>", s)
    attrs = dict(re.findall(r'([a-z-]+)="([^"]*)"', m.group(0))) if m else {}

    topic = attrs.get("data-topic")
    if topic is None:
        # Published before this metadata existed (§7.1: never edited).
        m = re.search(r'"about":\s*\{[^}]*"name":\s*"((?:[^"\\]|\\.)*)"', s)
        if not m:
            die(f"{where}: no data-topic and no JSON-LD about.name to fall back on")
        topic = json.loads('"' + m.group(1) + '"')
        prefix = f"{LANGS[lang]} — "
        if topic.startswith(prefix):
            topic = topic[len(prefix):]
    topic = clean(topic, "topic", where, MAX_TOPIC)

    tags = []
    for tag in attrs.get("data-tags", "").split():
        if not TAG_RE.match(tag):
            die(f"{where}: tag {tag!r} is not kebab-case ASCII (doc/basic-design.md §7.4)")
        if tag not in tags:
            tags.append(tag)

    concepts = [
        clean(c, "concept", where, MAX_CONCEPT)
        for c in attrs.get("data-concepts", "").split(",")
        if c.strip()
    ]
    return {"lang": lang, "type": typ, "date": date, "topic": topic,
            "tags": tags, "concepts": concepts}


def published_dates(lang, typ):
    """Dates listed in archive.html, in the order they are listed."""
    archive = root / lang / typ / "archive.html"
    if not archive.is_file():
        return []
    dates = re.findall(rf'href="/{lang}/{typ}/(\d{{4}}-\d{{2}}-\d{{2}})"',
                       archive.read_text(encoding="utf-8"))
    return [d for d in dates if (root / lang / typ / f"{d}.html").is_file()]


def e(text):
    return html.escape(text, quote=False)


drills = []
for lang in LANGS:
    for typ in TYPES:
        for date in published_dates(lang, typ):
            drills.append(read_drill(lang, typ, date))

if mode == "--tags":
    counts = {}
    for d in drills:
        for tag in d["tags"]:
            counts[tag] = counts.get(tag, 0) + 1
    for tag, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{n:4}  {tag}")
    if not counts:
        print("(no tags yet)")
    sys.exit(0)


def render_archive(lang, typ):
    """archive.html with its <ul class="past-list"> rewritten."""
    archive = root / lang / typ / "archive.html"
    s = archive.read_text(encoding="utf-8")
    lines = []
    for date in published_dates(lang, typ):
        d = next(x for x in drills
                 if (x["lang"], x["type"], x["date"]) == (lang, typ, date))
        lines.append(
            f'    <li><a href="/{lang}/{typ}/{date}">{date}</a>'
            f' <span class="past-topic">{e(d["topic"])}</span></li>'
        )
    block = '  <ul class="past-list">\n' + "\n".join(lines) + "\n  </ul>"
    new, n = re.subn(r'  <ul class="past-list">.*?  </ul>', lambda _: block, s,
                     count=1, flags=re.S)
    if n != 1:
        die(f"{lang}/{typ}/archive.html: no <ul class=\"past-list\"> block to rewrite")
    return archive, new


def shell(title, description, canonical, breadcrumb, body):
    """The page frame every generated index page shares."""
    crumbs = ",\n".join(
        f'    {{ "@type": "ListItem", "position": {i}, "name": "{name}"'
        + (f', "item": "{url}" }}' if url else " }")
        for i, (name, url) in enumerate(breadcrumb, start=1)
    )
    return f"""<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="description" content="{description}">
<title>{title}</title>
<link rel="canonical" href="{canonical}">
<link rel="stylesheet" href="/style.css">
<script type="application/ld+json">
{{
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  "itemListElement": [
{crumbs}
  ]
}}
</script>
</head>
<body>
<div class="page">

<header class="masthead">
  <h1><a href="/">Namaran</a></h1>
  <p class="tagline">Code daily. Without assist.</p>
</header>

<main>
{body}
</main>

<footer>
  <p>A daily maintenance routine for programmers.</p>
  <p><a href="https://github.com/kokimiza/namara/issues">Spot a mistake? Fix it on GitHub.</a></p>
</footer>

</div>
</body>
</html>
"""


def drill_line(d):
    label = f'{LANGS[d["lang"]]} / {TYPES[d["type"]]} · {d["date"]}'
    concepts = ""
    if d["concepts"]:
        concepts = f' <span class="past-concepts">{e(", ".join(d["concepts"]))}</span>'
    return (f'    <li><a href="/{d["lang"]}/{d["type"]}/{d["date"]}">{label}</a>'
            f' <span class="past-topic">{e(d["topic"])}</span>{concepts}</li>')


def render_tag_page(tag, entries):
    """/tag/{tag} — every drill that touches one concept.

    One page per tag, not one page with every tag on it: twelve drills a day
    with a handful of tags each would turn a single index into a megabyte
    inside a year, and a page about one concept is the better answer to
    someone searching for that concept anyway.
    """
    entries = sorted(entries, key=lambda d: (d["date"], d["lang"], d["type"]), reverse=True)
    words = []
    for d in entries:
        for c in d["concepts"]:
            if c not in words:
                words.append(c)
    description = f"{tag}を扱ったNamaranのコーディングドリル。"
    if words:
        description += "、".join(words[:6])[:120] + "。"
    body = f"""  <h2>{tag}</h2>

  <p class="lede">
    「{tag}」を扱った{len(entries)}問。日付ページを開くと、その日のドリルがそのまま読めます。
  </p>

  <ul class="past-list">
{chr(10).join(drill_line(d) for d in entries)}
  </ul>

  <p><a href="/topics">ほかのお題を見る</a></p>"""
    return root / "tag" / f"{tag}.html", shell(
        title=f"{tag} — Namaran",
        description=e(description),
        canonical=f"{SITE}/tag/{tag}",
        breadcrumb=[("Namaran", f"{SITE}/"), ("Topics", f"{SITE}/topics"), (tag, None)],
        body=body,
    )


def render_topics_index(by_tag):
    if by_tag:
        tags = "\n".join(
            f'    <li><a href="/tag/{tag}">{tag}</a></li>' for tag in sorted(by_tag)
        )
        listing = f'  <ul class="past-list tag-list">\n{tags}\n  </ul>'
    else:
        listing = "  <p>まだタグの付いたドリルがありません。</p>"

    archives = "\n".join(
        f'    <li><a href="/{lang}/{typ}/archive">{LANGS[lang]} / {TYPES[typ]}</a></li>'
        for lang in LANGS for typ in TYPES
    )
    body = f"""  <h2>Topics</h2>

  <p class="lede">
    過去に出したドリルを、扱っている概念から辿るための索引です。解く画面には概念の名前を出していないので、探すのはここから。
  </p>

{listing}

  <h2>Archive</h2>
  <p>
    日付から辿るなら、言語と種別ごとのアーカイブへ。タグはこの索引を作るより前に公開したドリルには付いていないので、それより前のものはアーカイブから探してください。
  </p>
  <ul class="past-list">
{archives}
  </ul>"""
    return root / "topics.html", shell(
        title="お題から探す — Namaran",
        description="Namaranの過去のドリルを、扱っている概念のタグから探す索引。C・C++・Rust・Haskellの読む/書く/直すドリルを、お題ごとにまとめています。",
        canonical=f"{SITE}/topics",
        breadcrumb=[("Namaran", f"{SITE}/"), ("Topics", None)],
        body=body,
    )


by_tag = {}
for d in drills:
    for tag in d["tags"]:
        by_tag.setdefault(tag, []).append(d)

outputs = [render_archive(lang, typ) for lang in LANGS for typ in TYPES]
outputs.append(render_topics_index(by_tag))
outputs.extend(render_tag_page(tag, entries) for tag, entries in sorted(by_tag.items()))

# A tag page whose tag no longer appears anywhere is removed: everything
# under tag/ is written by this script and by nothing else.
tag_dir = root / "tag"
tag_dir.mkdir(exist_ok=True)
wanted = {p for p, _ in outputs}
stale_files = sorted(p for p in tag_dir.glob("*.html") if p not in wanted)

stale = [p for p, text in outputs
         if not p.is_file() or p.read_text(encoding="utf-8") != text]

if mode == "--check":
    if stale or stale_files:
        print("out of date (run script/topics.sh):")
        for p in stale:
            print(f"  - {p.relative_to(root)}")
        for p in stale_files:
            print(f"  - {p.relative_to(root)} (no longer has a tag)")
        sys.exit(1)
    print(f"topic index is up to date ({len(drills)} drills, {len(by_tag)} tags)")
    sys.exit(0)

for p, text in outputs:
    p.parent.mkdir(exist_ok=True)
    p.write_text(text, encoding="utf-8")
for p in stale_files:
    p.unlink()
tagged = sum(1 for d in drills if d["tags"])
print(f"{len(outputs)} file(s) written ({len(stale)} changed, {len(stale_files)} removed): "
      f"{len(drills)} drills, {tagged} tagged, {len(by_tag)} tags")
PY
