#!/usr/bin/env python3
"""Namaran content-management script.

This is an *authoring aid* (run locally or by the namaran-daily workflow),
not part of the deployed site. It never runs on Cloudflare Pages and the
site never depends on it — it only replaces hand-copying the same
boilerplate (nav, JSON-LD, footer) into a new file and a new archive.html
line every day. The one thing it deliberately does NOT do is invent the
actual problem: code, question, and answer are written by the namaran-daily
skill against the criteria in doc/requirements.md §11/§24, so `new` always
leaves those as clearly marked TODOs for the skill to fill in.

Usage:
  script/content.py new  [DATE] [LANG/TYPE ...]
  script/content.py undo [DATE] [LANG/TYPE ...]

  DATE defaults to today in Asia/Tokyo (matches functions/_middleware.js).
  LANG/TYPE pairs default to all 15 (5 languages x 3 exercise types) when
  omitted, e.g.: script/content.py new 2026-08-25 c/read rust/debug

`new`  creates {lang}/{type}/YYYY/MM/{date}.html (doc/basic-design.md §4)
       from script/template-{type}.html and
       prepends a matching <li> to {lang}/{type}/archive.html. It never
       overwrites an existing dated file (doc/basic-design.md: published
       pages are never edited), and skips an archive line that's already
       there, so re-running `new` for the same day is always safe.

`undo` reverses exactly that: removes the dated file and its archive line.
       As a safety check, it only deletes a dated file that still contains
       a "TODO:" marker — i.e. one nobody has started writing content
       into yet. A file with the TODOs filled in is left alone; undo it
       by hand if you really mean to.
"""

import re
import sys

from namaran import (CODE_EXT, DATE_RE, LANG_NAV_LABELS, LANGS, ROOT, SCRIPT_DIR, TYPES,
                    die, page_file, parse_combos, today_in_japan, wants_help)


def nav(cls, label, items, active):
    """A lang-nav or type-nav: one link per (key, text, href)."""
    out = [f'<nav class="{cls}" aria-label="{label}">']
    for key, text, href in items:
        if key == active:
            out.append(f'  <a href="{href}" class="active" aria-current="page">{text}</a>')
        else:
            out.append(f'  <a href="{href}">{text}</a>')
    out.append("</nav>")
    return "\n".join(out)


def render(lang, typ, date):
    """script/template-{type}.html for one (lang, type, date).

    Each type has its own template because the question and answer differ
    in shape: READ asks one fixed question, WRITE pairs input/output
    examples, DEBUG answers as Wrong / Right. Block placeholders
    (@@LANG_NAV@@ etc.) must appear alone on their own line in the
    template; everything else is a plain inline substitution.
    """
    blocks = {
        "@@LANG_NAV@@": nav("lang-nav", "Language",
                            [(l, LANG_NAV_LABELS[l], f"/{l}/{typ}/{date}") for l in LANGS], lang),
        "@@TYPE_NAV@@": nav("type-nav", "Exercise type",
                            [(t, TYPES[t], f"/{lang}/{t}/{date}") for t in TYPES], typ),
    }
    inline = {
        "@@DATE@@": date,
        "@@LANG_SLUG@@": lang,
        "@@LANG_LABEL@@": LANGS[lang],
        "@@TYPE_SLUG@@": typ,
        "@@TYPE_LABEL@@": TYPES[typ],
        "@@CODE_EXT@@": CODE_EXT[lang],
    }
    out = []
    template = (SCRIPT_DIR / f"template-{typ}.html").read_text(encoding="utf-8")
    for line in lines_of(template):
        if line in blocks:
            out.append(blocks[line])
            continue
        for key, value in inline.items():
            line = line.replace(key, value)
        out.append(line)
    return "\n".join(out) + "\n"


def lines_of(text):
    """Lines split on LF only, the last one with or without its LF."""
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def archive_link(lang, typ, date):
    return f'/{lang}/{typ}/{date}"'


def insert_entry(lines, entry, date):
    """Insert entry into archive.html's lines, keeping the list newest-first.

    It goes right before the first line holding a date older than the new
    one (ISO 8601 dates compare correctly as plain strings). If every
    existing entry is newer (or the list is still empty), it goes right
    before </ul> — the oldest slot. This matters for backfilling a date
    behind an already-listed newer one, not just for the usual append.
    """
    for i, line in enumerate(lines):
        m = DATE_RE.search(line)
        if (m and date > m.group(0)) or "</ul>" in line:
            return lines[:i] + [entry] + lines[i:]
    return lines


def parse_args(args):
    date = args[0] if args else today_in_japan()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die(f"not a YYYY-MM-DD date: {date}")
    return date, parse_combos(args[1:])


def cmd_new(args):
    date, combos = parse_args(args)
    created = skipped_file = archive_updated = archive_already = 0
    for lang, typ in combos:
        rel = page_file(lang, typ, date)
        file = ROOT / rel
        archive = ROOT / lang / typ / "archive.html"
        file.parent.mkdir(parents=True, exist_ok=True)

        if file.exists():
            print(f"skip (already exists): {rel}")
            skipped_file += 1
        else:
            file.write_text(render(lang, typ, date), encoding="utf-8")
            print(f"created: {rel}")
            created += 1

        if not archive.is_file():
            print(f"warning: no archive.html for {lang}/{typ} yet — skipped archive update",
                  file=sys.stderr)
            continue
        text = archive.read_text(encoding="utf-8")
        if archive_link(lang, typ, date) in text:
            archive_already += 1
            continue
        entry = f'    <li><a href="/{lang}/{typ}/{date}">{date}</a></li>'
        lines = insert_entry(lines_of(text), entry, date)
        archive.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"archived: {lang}/{typ}/archive.html += {date}")
        archive_updated += 1

    print()
    print(f"{created} created, {skipped_file} already existed, "
          f"{archive_updated} archive.html updated, {archive_already} already listed.")
    if created:
        print("Fill in the TODOs (code / question / answer) before publishing.")


def cmd_undo(args):
    date, combos = parse_args(args)
    removed = kept = archive_removed = 0
    for lang, typ in combos:
        rel = page_file(lang, typ, date)
        file = ROOT / rel
        archive = ROOT / lang / typ / "archive.html"

        if file.is_file():
            if "TODO:" not in file.read_text(encoding="utf-8"):
                print(f"keep (has been edited, no TODO markers left): {rel}", file=sys.stderr)
                kept += 1
                continue
            file.unlink()
            # The month and year directories go too if this was their only page.
            for d in (file.parent, file.parent.parent):
                try:
                    d.rmdir()
                except OSError:
                    break
            print(f"removed: {rel}")
            removed += 1

        if archive.is_file():
            text = archive.read_text(encoding="utf-8")
            if archive_link(lang, typ, date) in text:
                # Matches the link, not the whole line: script/topics.py (§9.5)
                # appends the drill's topic to it afterwards, so the tail of
                # the line varies.
                link = f'/{lang}/{typ}/{date}">{date}</a>'
                lines = [l for l in lines_of(text) if link not in l]
                archive.write_text("".join(l + "\n" for l in lines), encoding="utf-8")
                print(f"unarchived: {lang}/{typ}/archive.html -= {date}")
                archive_removed += 1

    print()
    print(f"{removed} removed, {kept} kept (edited — remove by hand if you're sure), "
          f"{archive_removed} archive.html entries removed.")


def main(args):
    if not args:
        print(__doc__.strip())
        return
    wants_help(args)
    sub, rest = args[0], args[1:]
    if sub == "new":
        cmd_new(rest)
    elif sub == "undo":
        cmd_undo(rest)
    else:
        print(f"error: unknown subcommand: {sub}", file=sys.stderr)
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
