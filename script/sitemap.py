#!/usr/bin/env python3
"""Namaran sitemap generator.

An authoring aid like script/content.py: it runs locally or in GitHub
Actions and never on Cloudflare Pages. It writes sitemap.xml at the
repository root as a plain static file, so the deployed site gains no
request-time code for it (doc/basic-design.md §9.3 explains why this is
not done in the middleware).

Usage:
  script/sitemap.py           rewrite sitemap.xml
  script/sitemap.py --check   exit 1 if sitemap.xml is not up to date

Listed URLs are the canonical ones only:
  /                          the root page
  /topics                    the topic index (script/topics.py)
  /tag/{tag}                 one page per tag, same generator
  /{lang}/{type}/archive     each archive page; lastmod = its newest date
  /{lang}/{type}/{date}      each dated page listed in that archive.html
                             whose file exists; lastmod = the date, since a
                             published page is never edited (§7.1)
The bare /{lang}/{type} aliases are left out: they serve a dated page's
bytes, and that page's <link rel="canonical"> points at the dated URL.

archive.html is the source of truth for "published" (§7.1a), the same one
the middleware reads. Dates after today in Asia/Tokyo are left out, because
the middleware answers those with 404 (§5.1).

Nothing read from a file is copied into the XML as text: languages and
types come from the fixed lists in script/namaran.py, and a date is only
used after it matches YYYY-MM-DD and names an existing file. Whatever an
archive.html contains, the output can only be these URL shapes. The output
is sorted and depends only on the repository and today's date, so
regenerating it with nothing new published is a no-op diff.
"""

import re
import sys

from namaran import LANGS, LEVELS, ROOT, SITE, STRICT_DATE_RE, TYPES, page_file, today_in_japan

OUT = ROOT / "sitemap.xml"
TAG_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def published_dates(lang, typ, today):
    """Published dates for one combo, newest first."""
    archive = ROOT / lang / typ / "archive.html"
    if not archive.is_file():
        return []
    found = re.findall(rf'href="/{lang}/{typ}/(\d{{4}}-\d{{2}}-\d{{2}})"',
                       archive.read_text(encoding="utf-8"))
    return [d for d in sorted(set(found), reverse=True)
            if STRICT_DATE_RE.fullmatch(d) and d <= today
            and (ROOT / page_file(lang, typ, d)).is_file()]


def render():
    today = today_in_japan()
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
           f"  <url><loc>{SITE}/</loc></url>",
           # No lastmod, same as the root page: both change whenever anything
           # is published, and a date that is right by accident is worth
           # less than none.
           f"  <url><loc>{SITE}/topics</loc></url>",
           f"  <url><loc>{SITE}/levels</loc></url>"]

    # One page per difficulty, also written by script/topics.py. The four
    # levels are a fixed list, like the languages and types.
    for level in LEVELS:
        if (ROOT / "level" / f"{level}.html").is_file():
            out.append(f"  <url><loc>{SITE}/level/{level}</loc></url>")

    # One page per tag, written by script/topics.py. The file name is the
    # tag, and a tag is kebab-case ASCII by construction (§7.4); anything
    # else is skipped rather than copied into the XML.
    for tag_file in sorted((ROOT / "tag").glob("*.html")):
        if TAG_RE.fullmatch(tag_file.stem):
            out.append(f"  <url><loc>{SITE}/tag/{tag_file.stem}</loc></url>")

    for lang in LANGS:
        for typ in TYPES:
            dates = published_dates(lang, typ, today)
            if not dates:
                continue
            out.append(f"  <url><loc>{SITE}/{lang}/{typ}/archive</loc><lastmod>{dates[0]}</lastmod></url>")
            out.extend(f"  <url><loc>{SITE}/{lang}/{typ}/{d}</loc><lastmod>{d}</lastmod></url>"
                       for d in dates)

    out.append("</urlset>")
    return "\n".join(out) + "\n"


def main(args):
    mode = args[0] if args else ""
    if mode in ("-h", "--help", "help"):
        print(__doc__.strip())
    elif mode == "":
        text = render()
        OUT.write_text(text, encoding="utf-8")
        print(f"wrote sitemap.xml ({text.count('<url>')} URLs)")
    elif mode == "--check":
        if OUT.is_file() and OUT.read_text(encoding="utf-8") == render():
            print("sitemap.xml is up to date")
        else:
            print("sitemap.xml is out of date; run script/sitemap.py", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"error: unknown argument: {mode}", file=sys.stderr)
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
