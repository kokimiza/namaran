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
#   topics.html                  every tag, named in Japanese
#   tag/{slug}.html              one page per tag, listing every drill that
#                                touches that concept
#   levels.html                  the four difficulty animals, with counts
#   level/{level}.html           one page per difficulty, listing every drill
#                                drawn at that level (the animal's .svg sits
#                                beside it; that one is drawn by hand)
#
# A drill page itself stays quiet: it shows a date, a filename and code, and
# carries its subject as metadata only (doc/basic-design.md §7.1). Naming
# the concept on the page being solved would hand over half the answer; on
# an archive or a topic index, where the point is to find a drill again,
# naming it is exactly what is wanted (§7.3).
#
# Usage:
#   script/topics.sh           rewrite the archive lists, topics.html, tag/,
#                              levels.html and level/*.html
#   script/topics.sh --check   exit 1 if any of them is not up to date
#   script/topics.sh --tags    print the tag vocabulary, most used first
#
# Where each field comes from, per drill page:
#
#   topic     <main data-topic="…"> — a Japanese heading of at most 15
#             characters. The same string is the page's whole <title>.
#   tags      <main data-tags="…">, space separated. A tag is an ASCII
#             kebab-case slug, and it is only ever a URL: what a reader sees
#             is its Japanese name from script/tags.tsv (§7.4). A tag with
#             no line there stops the run — an index full of slugs nobody
#             can read is the thing this layer exists to avoid.
#   concepts  <main data-concepts="…">, comma separated. The natural-language
#             wording of the same subject, printed on the tag pages so that a
#             reader searching "値渡し" or "pass by value" lands somewhere.
#   level     <main data-level="…">: hedgehog, peacock, bison or whale, the
#             difficulty script/level.sh drew for the drill. Every archive and
#             tag line carries the same animal the drill page shows next to
#             its date (style.css draws both from /level/{level}.svg), with
#             its Japanese name as the accessible label.
#
# script/tags.tsv is the tag vocabulary: "slug<TAB>日本語の名前", one per
# line. This script rewrites it sorted and deduplicated, so a new tag can be
# appended anywhere by hand.
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
# it is escaped like any other. The output is deterministic, so re-running it
# with nothing new published is a no-op diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '2,63p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  ""|--check|--tags) ;;
  *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

exec python3 - "$ROOT_DIR" "${1:-}" <<'PY'
import html
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]

SITE = "https://namaran.jocarium.productions"
LANGS = {"c": "C", "cpp": "C++", "rust": "Rust", "haskell": "Haskell"}
TYPES = {"read": "READ", "write": "WRITE", "debug": "DEBUG"}
# Difficulty, easiest first: the animal and the level it stands for
# (doc/requirements.md §7).
LEVELS = {
    "hedgehog": ("ハリネズミ", "基礎"),
    "peacock": ("孔雀", "初級"),
    "bison": ("バイソン", "中級"),
    "whale": ("クジラ", "上級"),
}
# What each level asks of the reader, and how often the daily draw
# (script/level.sh) lands on it — doc/requirements.md §7.1.
LEVEL_NOTES = {
    "hedgehog": ("読んだそばから答えが出る。関わる規則は1つ", "44.7%"),
    "peacock": ("規則を1つ正確に思い出すか、数ステップ追う", "27.6%"),
    "bison": ("2つ以上の規則が絡む。実務で一度踏んで覚える罠", "17.1%"),
    "whale": ("言語の深い部分を複数組み合わせて初めて解ける", "10.6%"),
}

TAG_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
MAX_TOPIC = 15
MAX_LABEL = 15
MAX_CONCEPT = 60
TAGS_FILE = root / "script" / "tags.tsv"


def die(msg):
    sys.exit(f"error: {msg}")


def clean(value, what, where, limit):
    """One line of plain text, or the run stops. Page content is untrusted."""
    text = html.unescape(value).strip()
    if not text:
        die(f"{where}: empty {what}")
    if len(text) > limit:
        die(f"{where}: {what} is longer than {limit} characters: {text[:40]!r}")
    if re.search(r"[\x00-\x1f\x7f]", text):
        die(f"{where}: {what} contains a control character: {text[:40]!r}")
    return text


def read_labels():
    """slug -> Japanese name, from script/tags.tsv."""
    if not TAGS_FILE.is_file():
        return {}
    labels = {}
    for n, line in enumerate(TAGS_FILE.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        slug, _, label = line.partition("\t")
        if not TAG_RE.match(slug):
            die(f"script/tags.tsv:{n}: {slug!r} is not a kebab-case ASCII slug")
        label = clean(label, "tag name", f"script/tags.tsv:{n}", MAX_LABEL)
        if slug in labels and labels[slug] != label:
            die(f"script/tags.tsv: {slug!r} has two different names")
        labels[slug] = label
    return labels


def read_drill(lang, typ, date):
    """topic, tags and concepts for one published page."""
    page = root / lang / typ / f"{date}.html"
    where = f"{lang}/{typ}/{date}.html"
    s = page.read_text(encoding="utf-8")

    m = re.search(r"<main\b[^>]*>", s)
    attrs = dict(re.findall(r'([a-z-]+)="([^"]*)"', m.group(0))) if m else {}
    if "data-topic" not in attrs:
        die(f"{where}: <main> has no data-topic")
    topic = clean(attrs["data-topic"], "topic", where, MAX_TOPIC)

    tags = []
    for tag in attrs.get("data-tags", "").split():
        if not TAG_RE.match(tag):
            die(f"{where}: tag {tag!r} is not kebab-case ASCII (doc/basic-design.md §7.4)")
        if tag not in labels:
            die(f"{where}: tag {tag!r} has no Japanese name in script/tags.tsv")
        if tag not in tags:
            tags.append(tag)

    concepts = [
        clean(c, "concept", where, MAX_CONCEPT)
        for c in attrs.get("data-concepts", "").split(",")
        if c.strip()
    ]

    level = attrs.get("data-level")
    if level not in LEVELS:
        die(f"{where}: data-level must be one of {', '.join(LEVELS)}, got {level!r}")
    return {"lang": lang, "type": typ, "date": date, "topic": topic,
            "tags": tags, "concepts": concepts, "level": level}


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


def level_mark(level):
    """The difficulty animal. style.css paints it; the label is for whoever
    can't see it, and the tooltip for whoever doesn't know the animals yet."""
    animal, grade = LEVELS[level]
    label = f"{animal}（{grade}）"
    return (f'<span class="level" data-level="{level}" role="img"'
            f' aria-label="{label}" title="{label}"></span>')


labels = read_labels()
drills = []
for lang in LANGS:
    for typ in TYPES:
        for date in published_dates(lang, typ):
            drills.append(read_drill(lang, typ, date))

by_tag = {}
for d in drills:
    for tag in d["tags"]:
        by_tag.setdefault(tag, []).append(d)

# Most used first: on a page of two hundred Japanese names there is no
# alphabet to fall back on, so the order has to mean something.
tag_order = sorted(by_tag, key=lambda t: (-len(by_tag[t]), t))

if mode == "--tags":
    for tag in tag_order:
        print(f"{len(by_tag[tag]):4}  {tag:<28} {labels[tag]}")
    unused = sorted(set(labels) - set(by_tag))
    for tag in unused:
        print(f"{0:4}  {tag:<28} {labels[tag]}  (not used yet)")
    if not labels:
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
            f'    <li><a href="/{lang}/{typ}/{date}">{date}</a> {level_mark(d["level"])}'
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
    where = f'{LANGS[d["lang"]]} / {TYPES[d["type"]]} · {d["date"]}'
    concepts = ""
    if d["concepts"]:
        concepts = f' <span class="past-concepts">{e(", ".join(d["concepts"]))}</span>'
    return (f'    <li><a href="/{d["lang"]}/{d["type"]}/{d["date"]}">{where}</a> {level_mark(d["level"])}'
            f' <span class="past-topic">{e(d["topic"])}</span>{concepts}</li>')


def render_tag_page(tag, entries):
    """/tag/{slug} — every drill that touches one concept.

    One page per tag, not one page with every tag on it: twelve drills a day
    with a handful of tags each would turn a single index into a megabyte
    inside a year, and a page about one concept is the better answer to
    someone searching for that concept anyway.
    """
    name = labels[tag]
    entries = sorted(entries, key=lambda d: (d["date"], d["lang"], d["type"]), reverse=True)
    words = []
    for d in entries:
        for c in d["concepts"]:
            if c not in words:
                words.append(c)
    description = f"「{name}」を扱ったNamaranのコーディングドリル{len(entries)}問。"
    if words:
        description += "、".join(words[:6])[:100] + "。"
    body = f"""  <h2>{e(name)}</h2>

  <p class="lede">
    「{e(name)}」を扱った{len(entries)}問。日付を開くと、その日のドリルがそのまま読めます。日付の横の動物は難易度で、ハリネズミ・孔雀・バイソン・クジラの順に重くなります。
  </p>

  <ul class="past-list">
{chr(10).join(drill_line(d) for d in entries)}
  </ul>

  <p><a href="/topics">ほかのお題を見る</a></p>"""
    return root / "tag" / f"{tag}.html", shell(
        title=e(name),
        description=e(description),
        canonical=f"{SITE}/tag/{tag}",
        breadcrumb=[("Namaran", f"{SITE}/"), ("お題から探す", f"{SITE}/topics"),
                    (e(name), None)],
        body=body,
    )


by_level = {level: [] for level in LEVELS}
for d in drills:
    by_level[d["level"]].append(d)


def level_listing():
    """The four animals on /levels, easiest first, each linking to its own page."""
    items = "\n".join(
        f'    <li><a href="/level/{level}"><span class="level" data-level="{level}" aria-hidden="true"></span>'
        f'{animal}</a> <span class="tag-count">{grade} · {len(by_level[level])}</span></li>'
        for level, (animal, grade) in LEVELS.items()
    )
    return f'  <ul class="past-list tag-list level-list">\n{items}\n  </ul>'


def render_levels_index():
    """/levels — the difficulty counterpart of /topics."""
    body = f"""  <h2>難易度から探す</h2>

  <p class="lede">
    過去に出したドリルを、難易度から辿るための索引です。難易度は星ではなく4匹の動物で表していて、ハリネズミ・孔雀・バイソン・クジラの順に重くなります。数字はその難易度の問題数です。
  </p>

{level_listing()}

  <p>
    毎日の12問の難易度は、1問ずつ独立に抽選で決まります。出る確率はハリネズミ44.7%・孔雀27.6%・バイソン17.1%・クジラ10.6%で、1段ごとに黄金比で割った値です。過去の傾向は見ないので、12問すべてがクジラの日もあります。
  </p>"""
    return root / "levels.html", shell(
        title="難易度から探す",
        description="Namaranの過去のドリルを難易度から探す索引。ハリネズミ(基礎)・孔雀(初級)・バイソン(中級)・クジラ(上級)の4段階で、C・C++・Rust・Haskellのドリルをまとめています。",
        canonical=f"{SITE}/levels",
        breadcrumb=[("Namaran", f"{SITE}/"), ("難易度から探す", None)],
        body=body,
    )


def render_level_page(level):
    """/level/{level} — every drill drawn at one difficulty, newest first.

    A line is an archive line with the language and type in front: the
    animal is the same on every line, so it is said once, in the heading.
    """
    animal, grade = LEVELS[level]
    note, odds = LEVEL_NOTES[level]
    entries = sorted(by_level[level], key=lambda d: (d["date"], d["lang"], d["type"]), reverse=True)
    if entries:
        lines = "\n".join(
            f'    <li><a href="/{d["lang"]}/{d["type"]}/{d["date"]}">'
            f'{LANGS[d["lang"]]} / {TYPES[d["type"]]} · {d["date"]}</a>'
            f' <span class="past-topic">{e(d["topic"])}</span></li>'
            for d in entries
        )
        listing = f'  <ul class="past-list">\n{lines}\n  </ul>'
    else:
        listing = "  <p>まだこの難易度のドリルはありません。</p>"
    body = f"""  <h2><span class="level" data-level="{level}" aria-hidden="true"></span>{animal}（{grade}）</h2>

  <p class="lede">
    {animal}（{grade}）のドリル{len(entries)}問。{note}。毎日の抽選で出る確率は{odds}です。
  </p>

{listing}

  <p><a href="/levels">ほかの難易度を見る</a></p>"""
    return root / "level" / f"{level}.html", shell(
        title=f"{animal}（{grade}）",
        description=f"Namaranの難易度「{animal}（{grade}）」のコーディングドリル{len(entries)}問。{note}。",
        canonical=f"{SITE}/level/{level}",
        breadcrumb=[("Namaran", f"{SITE}/"), ("難易度から探す", f"{SITE}/levels"),
                    (f"{animal}（{grade}）", None)],
        body=body,
    )


def render_topics_index():
    if tag_order:
        items = "\n".join(
            f'    <li><a href="/tag/{tag}">{e(labels[tag])}</a>'
            f' <span class="tag-count">{len(by_tag[tag])}</span></li>'
            for tag in tag_order
        )
        listing = f'  <ul class="past-list tag-list">\n{items}\n  </ul>'
    else:
        listing = "  <p>まだタグの付いたドリルがありません。</p>"

    body = f"""  <h2>お題から探す</h2>

  <p class="lede">
    過去に出したドリルを、扱っているお題から辿るための索引です。解く画面にはお題の名前を出していないので、探すのはここから。
  </p>

{listing}"""
    return root / "topics.html", shell(
        title="お題から探す",
        description="Namaranの過去のドリルを、扱っているお題から探す索引。C・C++・Rust・Haskellの読む・書く・直すドリルを、お題ごとにまとめています。",
        canonical=f"{SITE}/topics",
        breadcrumb=[("Namaran", f"{SITE}/"), ("お題から探す", None)],
        body=body,
    )


outputs = [render_archive(lang, typ) for lang in LANGS for typ in TYPES]
outputs.append(render_topics_index())
outputs.extend(render_tag_page(tag, entries) for tag, entries in sorted(by_tag.items()))
outputs.append(render_levels_index())
# Always all four, even a level nothing has been drawn at yet: the set of
# levels is fixed, so level/ never has a page to remove.
outputs.extend(render_level_page(level) for level in LEVELS)
# The vocabulary file is normalized here, so a new tag can be appended to the
# end of it by hand and still land in the right place.
outputs.append((TAGS_FILE, "".join(f"{s}\t{labels[s]}\n" for s in sorted(labels))))

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
print(f"{len(outputs)} file(s) written ({len(stale)} changed, {len(stale_files)} removed): "
      f"{len(drills)} drills, {len(by_tag)} tags")
PY
