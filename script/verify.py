#!/usr/bin/env python3
"""Namaran drill verifier.

A *local and CI authoring aid*, like script/content.py — it never runs on
Cloudflare Pages. It checks one day's drill pages, and compiles and
statically analyzes the source files that back up what those pages claim,
so that a drill is never published with code that doesn't behave the way
its answer says. The same command is the gate in
.github/workflows/namaran-daily.yml: nothing is pushed unless it passes.

Usage:
  script/verify.py DATE VERIFY_DIR [LANG/TYPE ...]

  LANG/TYPE pairs default to all 15 (5 languages x 3 exercise types).

VERIFY_DIR holds one directory per combo, VERIFY_DIR/{lang}/{type}/, with
complete, compilable source files named NAME.KIND.EXT:

  NAME.ok.EXT    must compile with warnings as errors and pass static
                 analysis (see "Toolchains" below). A drill's correct
                 code: the READ program, the WRITE reference, the fixed
                 DEBUG program. A Zig ok file that declares top-level
                 `test` blocks must also pass `zig test` (where
                 std.testing.allocator fails a test that leaks).
  NAME.stdout    optional, next to NAME.ok.EXT: the program is run (10s
                 timeout, sanitizers on for C/C++, runtime safety checks
                 for Zig) and its stdout must match this file byte for
                 byte. Required for every READ ok file, so the published
                 answer is the observed output.
  NAME.ng.EXT    must FAIL to compile: a READ "this doesn't compile"
                 answer. Not allowed for DEBUG.
  NAME.bug.EXT   must compile (warnings allowed); never analyzed. The
                 broken DEBUG program: DEBUG code always compiles and
                 fails at run time (undefined behavior, a hang, a wrong
                 result).
  NAME.bug.stdout  optional, next to NAME.bug.EXT: the broken program is
                 built as it is (warnings allowed, no sanitizers) and run
                 (10s timeout), and its stdout must match this file. That
                 is the wrong output a DEBUG question quotes, so the drill
                 cannot claim one nobody observed. Leave it out when the
                 bug has no fixed output (undefined behavior, a hang, a
                 crash) — and then the question must not quote one either.

Per combo, at least: READ one file of any kind; WRITE one ok file; DEBUG
one ok file plus one bug file, and no ng file.

Every ok, ng and bug file must also be laid out exactly as
script/format.py writes it (the repository's .clang-format, rustfmt.toml
and fourmolu.yaml; zig fmt has no settings). The only exemption is an ng
file the formatter cannot read at all, since a syntax error may be what a
READ drill asks about.

Page checks, for {lang}/{type}/YYYY/MM/DATE.html: JSON-LD parses, no TODO left,
the topic metadata is there and agrees with itself (<main>'s data-topic —
at most 15 characters and the page's whole <title> — plus data-tags, which
must all be named in script/tags.tsv, data-concepts, the meta description
and the JSON-LD about.name / keywords / description — see
doc/basic-design.md §7.1 and §7.4), data-level is one of the four
difficulty animals (hedgehog, peacock, bison, whale — §7.1),
lang-nav/type-nav point at the same date, the archive.html line exists,
<code> contents are HTML-escaped (the highlighter's <span>s aside), every
non-comment line of every <pre class="code"> block appears in one of that
combo's ok/ng/bug files, indented as it is there (a block may be shifted
left as a whole, nothing more) — so the code readers see is the code that
was checked and formatted — READ/DEBUG question code (outside
<details>) is at most 18 lines, a WRITE page's examples sit in
<div class="examples">, a DEBUG answer is Wrong + listing then Right +
listing, the Japanese prose has none of the patterns the humanizer-ja-tech
revision pass removes (AI stock phrases, dashes, full-width alphanumerics,
だ・である sentences), footnote references and notes match one to one —
and the listings are highlighted exactly
as script/highlight.py would write them.

Toolchains (override the command names with environment variables):
  C        NAMARAN_CC     (gcc-14)   -std=c23   -Wall -Wextra -Wpedantic -Werror -fanalyzer
  C++      NAMARAN_CXX    (g++-14)   -std=c++26 -Wall -Wextra -Wpedantic -Werror
  Rust     NAMARAN_CLIPPY (clippy-driver) / NAMARAN_RUSTC (rustc)  --edition 2024, clippy -D warnings
  Haskell  NAMARAN_GHC    (ghc) / NAMARAN_HLINT (hlint)  -XHaskell2010 -Wall -Werror, hlint warnings/errors
  Zig      NAMARAN_ZIG    (zig 0.17.0)  zig build-exe (Debug: runtime safety checks on), zig test
           when the file has tests. Zig has no warnings: what the others gate with
           -Werror (unused locals, a var never mutated, ...) is already a compile error.
  Formatters: see script/format.py (clang-format, rustfmt, fourmolu, zig fmt; pinned versions).

The language versions here must match CLAUDE.md's version table.
"""

import html
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import format as formatter
import highlight
from namaran import CODE_EXT, ROOT, die, page_file, parse_combos

CC = os.environ.get("NAMARAN_CC", "gcc-14")
CXX = os.environ.get("NAMARAN_CXX", "g++-14")
RUSTC = os.environ.get("NAMARAN_RUSTC", "rustc")
CLIPPY = os.environ.get("NAMARAN_CLIPPY", "clippy-driver")
GHC = os.environ.get("NAMARAN_GHC", "ghc")
HLINT = os.environ.get("NAMARAN_HLINT", "hlint")
ZIG = os.environ.get("NAMARAN_ZIG", "zig")

failures = 0


def fail(msg, details=()):
    """One failed check, with up to its first lines of details indented below."""
    global failures
    print(f"  FAIL: {msg}")
    for line in details:
        print(f"        {line}")
    failures += 1


def passed(msg):
    print(f"  ok:   {msg}")


def head(text, n):
    return text.splitlines()[:n]


def run(cmd, cwd=None):
    """(succeeded, combined stdout and stderr) of a build or analysis step."""
    try:
        r = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as e:
        return False, f"{cmd[0]}: {e.strerror}"
    return r.returncode == 0, r.stdout.decode("utf-8", "replace")


def steps(*cmds):
    """Run commands in order until one fails: (succeeded, log of the last one run)."""
    ok, log = True, ""
    for cmd in cmds:
        ok, log = cmd() if callable(cmd) else run(cmd)
        if not ok:
            break
    return ok, log


def hlint(src):
    """hlint suggestions are style preferences and don't fail the check;
    warnings and errors do."""
    try:
        r = subprocess.run([HLINT, "--json", str(src)], capture_output=True, text=True)
    except OSError as e:
        return False, f"{HLINT}: {e.strerror}"
    try:
        hints = [h for h in json.loads(r.stdout or "[]") if h["severity"] in ("Warning", "Error")]
    except (ValueError, KeyError, TypeError) as e:
        return False, f"hlint output is not what was expected ({e}):\n{r.stderr}"
    log = "\n".join(f"hlint {h['severity']}: line {h['startLine']}: {h['hint']}: {h['from']!r} -> {h['to']!r}"
                    for h in hints)
    return not hints, log


def compile_ok(lang, src, binary, out):
    """Strict build + static analysis of a correct file."""
    sanitize = ["-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-o", binary, src]
    if lang == "c":
        return run([CC, "-std=c23", "-Wall", "-Wextra", "-Wpedantic", "-Werror", "-fanalyzer", *sanitize])
    if lang == "cpp":
        return run([CXX, "-std=c++26", "-Wall", "-Wextra", "-Wpedantic", "-Werror", *sanitize])
    if lang == "rust":
        return run([CLIPPY, "--edition", "2024", "--crate-name", "verify", "-D", "warnings",
                    "-C", "debug-assertions=on", "-o", binary, src])
    if lang == "haskell":
        return steps([GHC, "-XHaskell2010", "-Wall", "-Werror", "-outputdir", out, "-o", binary, src],
                     lambda: hlint(src))
    # Zig analyzes only what main reaches, so a file's tests are run
    # separately; std.testing.allocator fails a test that leaks.
    cache = ["--cache-dir", f"{out}/zig-cache"]
    build = [ZIG, "build-exe", "-O", "Debug", *cache, f"-femit-bin={binary}", src]
    if re.search(r"^test\b", pathlib.Path(src).read_text(encoding="utf-8"), re.M):
        return steps(build, [ZIG, "test", "-O", "Debug", *cache, src])
    return run(build)


def compile_plain(lang, src, binary, out):
    """Build a broken program as it is: warnings allowed, no sanitizers, so
    that what it prints is what a reader would see. Only used when a
    NAME.bug.stdout says the wrong output is worth checking."""
    (out / "run").mkdir(exist_ok=True)
    return run({
        "c": [CC, "-std=c23", "-g", "-o", binary, src],
        "cpp": [CXX, "-std=c++26", "-g", "-o", binary, src],
        "rust": [RUSTC, "--edition", "2024", "--crate-name", "verify", "-C", "debug-assertions=on",
                 "-o", binary, src],
        "haskell": [GHC, "-XHaskell2010", "-outputdir", f"{out}/run", "-o", binary, src],
        "zig": [ZIG, "build-exe", "-O", "Debug", "--cache-dir", f"{out}/zig-cache", f"-femit-bin={binary}", src],
    }[lang])


def check_only(lang, src, out):
    """Does this file compile at all? (no warnings gate)"""
    return run({
        "c": [CC, "-std=c23", "-pedantic-errors", "-fsyntax-only", src],
        "cpp": [CXX, "-std=c++26", "-pedantic-errors", "-fsyntax-only", src],
        "rust": [RUSTC, "--edition", "2024", "--crate-name", "verify", "--emit=metadata",
                 "-o", f"{out}/verify.rmeta", src],
        "haskell": [GHC, "-XHaskell2010", "-fno-code", "-outputdir", out, src],
        "zig": [ZIG, "build-exe", "--cache-dir", f"{out}/zig-cache", "-fno-emit-bin", src],
    }[lang])


def run_program(binary, out, expected, name):
    """Run a built program (10s timeout) in out and compare its stdout with
    the file expected. Returns None if it matches, else (message, details)."""
    actual = out / "actual.stdout"
    try:
        r = subprocess.run([binary], cwd=out, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=10)
        ran, stderr = r.returncode == 0, r.stderr
    except subprocess.TimeoutExpired as e:
        ran, stderr = False, (e.stderr or b"").rstrip(b"\n") + b"\n(timed out after 10s)"
    if not ran:
        return "failed", head(stderr.decode("utf-8", "replace").lstrip("\n"), 20)
    actual.write_bytes(r.stdout)
    if r.stdout != expected.read_bytes():
        d = subprocess.run(["diff", str(expected), str(actual)], capture_output=True, text=True)
        return "differs", head(d.stdout, 20)
    return None


def check_format(kind, src, base):
    """Is src laid out as script/format.py writes it? ok and bug files
    compile, so their formatter can always read them; an ng file it cannot
    read (a syntax error) is the one exemption."""
    log = []
    status = formatter.run([str(src)], True, log.append)
    if status == formatter.OK:
        passed(f"{base} (formatting)")
    elif status == formatter.CHANGED:
        fail(f"{base} is not formatted as script/format.py writes it "
             "(run it on the file, then copy the lines to the page again):", log[:40])
    elif status == formatter.UNREADABLE and kind == "ng":
        passed(f"{base} (formatting not checked: the formatter cannot read it)")
    elif status == formatter.UNREADABLE:
        fail(f"{base}: the formatter cannot read it:", log[:40])
    else:
        fail(f"{base}: script/format.py could not run:", log[:40])


def verify_sources(lang, typ, src_dir, work):
    ext = CODE_EXT[lang]
    counts = {"ok": 0, "ng": 0, "bug": 0}
    for f in sorted(p for p in src_dir.iterdir() if not p.name.startswith(".")):
        base = f.name
        kind = next((k for k in counts if base.endswith(f".{k}.{ext}")), None)
        if kind is None:
            if base.endswith(".bug.stdout"):
                if not (src_dir / f"{base.removesuffix('.stdout')}.{ext}").is_file():
                    fail(f"{base} has no matching {base.removesuffix('.stdout')}.{ext}")
            elif base.endswith(".stdout"):
                if not (src_dir / f"{base.removesuffix('.stdout')}.ok.{ext}").is_file():
                    fail(f"{base} has no matching {base.removesuffix('.stdout')}.ok.{ext}")
            else:
                fail(f"unexpected file (want NAME.ok|ng|bug.{ext} or NAME.stdout): {base}")
            continue
        name = base.removesuffix(f".{kind}.{ext}")
        counts[kind] += 1
        out = work / f"{lang}-{typ}-{name}-{kind}"
        out.mkdir(parents=True, exist_ok=True)
        binary = str(out / "prog")
        src = str(f)

        check_format(kind, f, base)

        if kind == "ok":
            ok, log = compile_ok(lang, src, binary, str(out))
            if not ok:
                fail(f"{base} does not pass the strict build / static analysis:", head(log, 40))
                continue
            expected = src_dir / f"{name}.stdout"
            if expected.is_file():
                wrong = run_program(binary, out, expected, name)
                if wrong is None:
                    passed(f"{base} (analyzed, stdout matches)")
                elif wrong[0] == "failed":
                    fail(f"{base}: running it failed or timed out:", wrong[1])
                else:
                    fail(f"{base}: stdout differs from {name}.stdout:", wrong[1])
            elif typ == "read":
                fail(f"{base}: READ ok files need a {name}.stdout with the answer's output")
            else:
                passed(f"{base} (analyzed)")
        elif kind == "ng":
            if check_only(lang, src, str(out))[0]:
                fail(f"{base} was expected NOT to compile, but it does")
            else:
                passed(f"{base} (fails to compile, as expected)")
        else:
            ok, log = check_only(lang, src, str(out))
            if not ok:
                fail(f"{base} was expected to compile, but it doesn't:", head(log, 40))
                continue
            expected = src_dir / f"{name}.bug.stdout"
            if not expected.is_file():
                passed(f"{base} (compiles; not executed — no {name}.bug.stdout)")
                continue
            ok, log = compile_plain(lang, src, binary, out)
            if not ok:
                fail(f"{base} has a {name}.bug.stdout but does not build with the strict flags off:",
                     head(log, 40))
                continue
            wrong = run_program(binary, out, expected, name)
            if wrong is None:
                passed(f"{base} (compiles; wrong output matches {name}.bug.stdout)")
            elif wrong[0] == "failed":
                fail(f"{base}: running it failed or timed out. A bug with no fixed output (undefined "
                     f"behavior, a hang, a crash) must not have a {name}.bug.stdout, and its question "
                     "must not quote one:", wrong[1])
            else:
                fail(f"{base}: stdout differs from {name}.bug.stdout:", wrong[1])

    if typ == "read" and sum(counts.values()) < 1:
        fail("READ needs at least one source file")
    if typ == "write" and counts["ok"] < 1:
        fail("WRITE needs at least one ok file (the reference)")
    if typ == "debug":
        if counts["ok"] < 1:
            fail("DEBUG needs at least one ok file (the fixed program)")
        if counts["bug"] < 1:
            fail("DEBUG needs a bug file (the broken program)")
        if counts["ng"]:
            fail("DEBUG code must compile: use a bug file, not an ng file")


def page_problems(lang, typ, date, src_dir):
    """What is wrong with one drill page, as a list of messages."""
    root = ROOT
    page = ROOT / page_file(lang, typ, date)
    archive = ROOT / lang / typ / "archive.html"
    exts = CODE_EXT
    # The only markup allowed inside <code>: script/highlight.py's spans (tokens,
    # lines, and the diff marks on answer listings).
    spans = re.compile(r'<span class="(?:kw|ty|fn|st|nu|cm|pp|mc|lt|op|chg|code-line(?: del| ins)?)">|</span>')
    problems = []

    s = page.read_text(encoding="utf-8")

    m_ld = re.search(r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>', s, re.S)
    try:
        json.loads(m_ld.group(1))
    except Exception as e:
        problems.append(f"JSON-LD does not parse: {e}")

    if "TODO" in s:
        problems.append("TODO markers remain")

    # --- the topic metadata (doc/basic-design.md §7.1, §7.4) -------------------
    # The page shows only a date, a filename and code; what it is *about* lives
    # here, and script/topics.py turns it into the archive lines and topics.html.
    m = re.search(r"<main\b[^>]*>", s)
    attrs = dict(re.findall(r'([a-z-]+)="([^"]*)"', m.group(0))) if m else {}
    topic = html.unescape(attrs.get("data-topic", "")).strip()
    tags = attrs.get("data-tags", "").split()
    concepts = [c.strip() for c in html.unescape(attrs.get("data-concepts", "")).split(",") if c.strip()]

    if not topic:
        problems.append("<main> has no data-topic")
    elif len(topic) > 15:
        problems.append(f"data-topic must be at most 15 characters, got {len(topic)}: {topic!r}")
    if not 2 <= len(tags) <= 8:
        problems.append(f"data-tags must hold 2-8 tags, got {len(tags)}")
    known = {}
    tags_file = pathlib.Path(root, "script", "tags.tsv")
    if tags_file.is_file():
        for line in tags_file.read_text(encoding="utf-8").splitlines():
            slug, _, name = line.partition("\t")
            if slug.strip():
                known[slug.strip()] = name.strip()
    for tag in tags:
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", tag):
            problems.append(f"tag {tag!r} is not lowercase kebab-case ASCII (§7.4)")
        elif tag not in known:
            problems.append(f"tag {tag!r} has no Japanese name in script/tags.tsv (§7.4)")
    if len(set(tags)) != len(tags):
        problems.append("data-tags repeats a tag")
    if len(concepts) < 2:
        problems.append("data-concepts needs at least two wordings (Japanese and English)")

    # The difficulty the day's draw gave this drill (script/level.py). style.css
    # turns it into the animal next to the date, and script/topics.py puts the
    # same animal on the archive and tag lines.
    if attrs.get("data-level") not in ("hedgehog", "peacock", "bison", "whale"):
        problems.append(f"data-level must be hedgehog, peacock, bison or whale, got {attrs.get('data-level')!r}")

    # The whole <title> is the topic: 15 characters is what a browser tab and a
    # search result show without truncating (doc/basic-design.md §7.1).
    m = re.search(r"<title>(.*?)</title>", s, re.S)
    title = html.unescape(m.group(1)).strip() if m else ""
    if title != topic:
        problems.append(f"<title> must be exactly the data-topic {topic!r}, got {title!r}")

    m = re.search(r'<meta name="description" content="([^"]*)"', s)
    desc = html.unescape(m.group(1)).strip() if m else ""
    if not 30 <= len(desc) <= 160:
        problems.append(f"meta description must be 30-160 characters, got {len(desc)}")

    # JSON-LD repeats these three for search engines; drift would publish two
    # different claims about the same drill, so they have to match exactly.
    try:
        ld = json.loads(m_ld.group(1))["@graph"][1]
    except Exception:
        ld = {}
    if ld.get("about", {}).get("name", "") != topic:
        problems.append("JSON-LD about.name does not match data-topic")
    if ld.get("keywords", "") != ", ".join(tags):
        problems.append("JSON-LD keywords must be data-tags, comma separated")
    if ld.get("description", "") != desc:
        problems.append("JSON-LD description does not match the meta description")

    def nav(cls):
        n = re.search(rf'<nav class="{cls}".*?</nav>', s, re.S)
        return n.group(0) if n else ""
    lang_nav, type_nav = nav("lang-nav"), nav("type-nav")
    for l in exts:
        if f'href="/{l}/{typ}/{date}"' not in lang_nav:
            problems.append(f"lang-nav lacks /{l}/{typ}/{date}")
    for t in ("read", "write", "debug"):
        if f'href="/{lang}/{t}/{date}"' not in type_nav:
            problems.append(f"type-nav lacks /{lang}/{t}/{date}")
    active = f'href="/{lang}/{typ}/{date}" class="active" aria-current="page"'
    if active not in lang_nav or active not in type_nav:
        problems.append("current page is not marked active in both navs")

    if not archive.is_file():
        problems.append(f"{archive.relative_to(root)} does not exist; it has to be on main before the first drill")
    elif f'href="/{lang}/{typ}/{date}"' not in archive.read_text(encoding="utf-8"):
        problems.append(f"{archive.relative_to(root)} has no line for {date}")

    for code in re.findall(r"<(?:code|samp)>(.*?)</(?:code|samp)>", s, re.S):
        if re.search(r"<|&(?!lt;|gt;|amp;|quot;|#39;)", spans.sub("", code)):
            problems.append(f"unescaped < or & inside <code>: {code[:60]!r}")

    ext = exts[lang]
    kinds = ("ok", "ng", "bug")
    # Each verified line (stripped) -> the indentations it has in the sources.
    verified = {}
    def indent(line):
        return len(line) - len(line.lstrip())
    for f in pathlib.Path(src_dir).glob(f"*.{ext}"):
        if any(f.name.endswith(f".{k}.{ext}") for k in kinds):
            for line in f.read_text(encoding="utf-8").splitlines():
                verified.setdefault(line.strip(), set()).add(indent(line))
    comment = re.compile({"haskell": r"^(--( |$)|\{-)", "zig": r"^//"}.get(lang, r"^(//|/\*|\*/|\*( |$))"))
    for block in re.findall(r'<pre class="code"><code>(.*?)</code></pre>', s, re.S):
        # The sources are formatted (script/format.py), so the page has to keep
        # their layout: an excerpt may move left as a whole, by one shift that
        # fits every line of the block, but no line may move on its own.
        shifts = None
        for line in html.unescape(spans.sub("", block)).splitlines():
            t = line.strip()
            if not t or comment.match(t):
                continue
            if t not in verified:
                problems.append(f"published code line is in no ok/ng/bug file: {t!r}")
                continue
            fits = {i - indent(line) for i in verified[t] if i >= indent(line)}
            shifts = fits if shifts is None else shifts & fits
        if shifts is not None and not shifts:
            first = html.unescape(spans.sub("", block)).strip().splitlines()[0]
            problems.append(f"code block starting {first!r} is not indented as in its verification source: "
                            "copy the lines from the formatted source (shifting the whole block left is fine)")

    # READ/DEBUG code is read in full before answering, so it must stay small
    # (doc/requirements.md §12). Over the limit is a badly chosen problem: pick
    # another angle, don't squeeze lines. <details> (the answer) doesn't count.
    MAX_LINES = 18
    if typ in ("read", "debug"):
        question = re.sub(r"<details.*?</details>", "", s, flags=re.S)
        n = sum(len(html.unescape(spans.sub("", b)).splitlines())
                for b in re.findall(r'<pre class="code"><code>(.*?)</code></pre>', question, re.S))
        if n > MAX_LINES:
            problems.append(f"question code is {n} lines; {typ.upper()} must fit in {MAX_LINES}"
                            " (a problem-design error: choose a smaller angle, see ponytail.md)")

    # The shape each type's template gives (script/template-{type}.html).
    if typ == "write" and '<div class="examples">' not in s:
        problems.append('WRITE needs its input/output examples in <div class="examples">')
    if "drill" in attrs.get("class", "").split() and typ == "read":
        if not re.search(r'<div class="code-frame answer-output"[^>]*>\s*'
                         r'<p class="code-filename">Output</p>\s*'
                         r'<pre class="output"><samp>.+?</samp></pre>\s*</div>',
                         s[s.find('<details class="answer">'):], re.S):
            problems.append('READ needs its result in the Output terminal (<pre class="output"><samp>)')
    if typ == "debug":
        answer = s[s.find('<details class="answer">'):]
        if not re.search(r'<h3 class="wrong">Wrong</h3>\s*<pre class="code">.*?'
                         r'<h3 class="right">Right</h3>\s*<pre class="code">', answer, re.S):
            problems.append('DEBUG answer must be <h3 class="wrong">Wrong</h3> + listing, '
                            'then <h3 class="right">Right</h3> + listing')

    # --- the Japanese prose (/humanizer-ja-tech, .claude/skills/humanizer-ja-tech) --
    # Most of the revision pass is judgment, but part of what it removes can be
    # found by pattern: AI stock phrases (§5), dashes, full-width alphanumerics
    # and emoji (§4), and a だ・である sentence on a です・ます page (§8). A hit
    # means the page skipped the revision pass. Code is left out: <pre> blocks
    # entirely, inline <code> as a stand-in letter.
    main_html = s[s.find("<main"):s.find("</main>")]
    def prose(fragment):
        fragment = re.sub(r"<pre\b.*?</pre>", " ", fragment, flags=re.S)
        fragment = re.sub(r"<code>.*?</code>", "X", fragment, flags=re.S)
        return html.unescape(re.sub(r"<[^>]+>", "", fragment))
    text = prose(main_html) + "\n" + prose(html.escape(desc, quote=False))
    prose_rules = [
        (r"重要なのは|(?<![ァ-ヴー])ポイントは|(?<![一-龯々])実は|一見すると|興味深いことに", "§5.1 stage-setting phrase"),
        (r"ましょう", "§5.1/§5.6 exhortation"),
        (r"単なる[^。]*?ではなく", "§5.2 false contrast"),
        (r"非常に|極めて", "§5.3 overstatement"),
        (r"以上から|以上のように", "§5.4 summary"),
        (r"[ですま]すよね|安心してください|初心者でも", "§5.6 talking down"),
        (r"[—–]", "§4 em/en dash"),
        (r"[Ａ-Ｚａ-ｚ０-９]", "§4 full-width alphanumeric"),
        (r"[\U0001F300-\U0001FAFF☀-➿]", "§4 emoji"),
        (r"(?:だ|である|だった|であった|ではない|だろう)。", "§8 だ・である sentence on a です・ます page"),
    ]
    for pattern, why in prose_rules:
        for hit in re.finditer(pattern, text):
            context = text[max(hit.start() - 12, 0):hit.end() + 8].replace("\n", " ").strip()
            problems.append(f"prose ({why}, /humanizer-ja-tech): …{context}…")

    # Footnotes (doc/basic-design.md §7.1): only in the answer, and with no
    # links to tie them, numbered 1..n by first reference, one note per number.
    details_at = main_html.find("<details")
    if '<sup class="fn-ref">' in main_html[:details_at]:
        problems.append("footnote reference in the question; footnotes belong to the answer")
    refs = list(dict.fromkeys(int(r) for r in re.findall(r'<sup class="fn-ref">(\d+)</sup>', main_html)))
    m = re.search(r'<ol class="footnotes">(.*?)</ol>', main_html, re.S)
    notes = len(re.findall(r"<li\b", m.group(1))) if m else 0
    if refs != list(range(1, notes + 1)):
        problems.append(f"footnotes: the text refers to {refs or 'none'} but the list has {notes} note(s); "
                        "number references 1..n in order, one <li> each, and drop an unused <ol>")

    return problems


def verify_page(lang, typ, date, src_dir):
    page = page_file(lang, typ, date)
    problems = page_problems(lang, typ, date, src_dir)
    if problems:
        fail(f"{page} page checks:", problems)
    else:
        passed(f"{page} (page checks)")
    try:
        stale = highlight.is_stale(ROOT / page)
    except SystemExit as e:
        stale, why = True, [str(e.code)]
    else:
        why = [f"not highlighted (run script/highlight.py {page}): {page}"]
    if stale:
        fail(f"{page} is not highlighted as script/highlight.py writes it:", why)
    else:
        passed(f"{page} (highlighting)")


def main(args):
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    date, verify_dir = args[0], pathlib.Path(args[1])
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        die(f"not a YYYY-MM-DD date: {date}", 2)
    if not verify_dir.is_dir():
        die(f"no such directory: {args[1]}", 2)
    verify_dir = verify_dir.resolve()
    combos = parse_combos(args[2:], status=2)

    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        for lang, typ in combos:
            print(f"== {lang}/{typ}/{date}")
            if not (ROOT / page_file(lang, typ, date)).is_file():
                fail(f"{page_file(lang, typ, date)} does not exist")
                continue
            src_dir = verify_dir / lang / typ
            if not src_dir.is_dir():
                fail(f"no verification sources in {src_dir}")
                continue
            verify_page(lang, typ, date, src_dir)
            verify_sources(lang, typ, src_dir, work)

    print()
    if failures:
        print(f"{failures} check(s) failed.")
        sys.exit(1)
    print(f"All checks passed for {len(combos)} combo(s).")


if __name__ == "__main__":
    main(sys.argv[1:])
