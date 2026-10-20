// Cloudflare Pages Functions middleware.
//
// Three responsibilities need request-time logic that plain static files
// cannot express on their own:
//
//   1. 404 any dated URL whose date is in the future. A static file's mere
//      existence can't encode "not yet" — this is a data-integrity rule,
//      not a UI nicety, so it stays here (doc/basic-design.md §5.1).
//   2. Map a dated URL, /{lang}/{type}/YYYY-MM-DD, onto the file that holds
//      it, {lang}/{type}/YYYY/MM/YYYY-MM-DD.html (doc/basic-design.md §5).
//      The files are split by year and month so that no directory grows
//      without bound; the URLs were never changed, so no link, bookmark,
//      canonical or sitemap entry had to be. The file's own path is not a
//      URL of the site: it 404s, or it would be a second address for every
//      page and a way around rule 1.
//   3. Serve the latest *published* dated page's bytes at the bare
//      /{lang}/{type} URL (the "today" alias), without a redirect, so
//      publishing a new day means adding one new dated file and nothing
//      else (doc/basic-design.md §5.2). "Latest published" is read off the
//      matching archive.html (its top <li> is always the newest date, per
//      §7.1a) rather than computed from the clock — the clock rolling over
//      to a new day in Asia/Tokyo must never make the page someone is
//      mid-way through reading 404 out from under them just because that
//      day hasn't been published yet.
//
// A fourth rule below is a permanent redirect for link shapes this site
// used to have and no longer does: a period where every page lived under
// a /ja/ or /en/ locale prefix, and — earlier still — a period where the
// DEBUG exercise type was named "fix". Both were retired by folding
// everything back into one unprefixed, English-only tree; see
// doc/basic-design.md §1 and §2.5 for why the locale split isn't coming
// back. This redirect exists purely so old bookmarks and indexed search
// results keep working — it carries no site logic of its own.
//
// The root path "/" is not handled here. index.html is a real page and is
// served like any other static file; there is nothing dynamic to resolve.

const LANG = "c|cpp|rust|haskell";
const TYPE = "read|write|debug";

const datedPath = new RegExp(
  `^/(${LANG})/(${TYPE})/(\\d{4}-\\d{2}-\\d{2})(?:\\.html)?/?$`
);

const latestAliasPath = new RegExp(`^/(${LANG})/(${TYPE})(?:\\.html)?/?$`);

// {lang}/{type}/YYYY/... is where dated pages are stored, not a URL.
const storagePath = new RegExp(`^/(?:${LANG})/(?:${TYPE})/\\d{4}(?:/|$)`);

// Matches any old link into the retired /ja/ or /en/ trees, and/or the old
// "fix" type name, in any combination: /en/c/fix, /ja/rust/debug/2026-08-20,
// /c/fix, etc. Capture groups: locale (optional), lang, type (fix or
// current), rest of the path (date/archive segment, if any).
const legacyPath = new RegExp(
  `^/(?:(ja|en)/)?(${LANG})/(fix|${TYPE})((?:\\.html)?(?:/.*)?)$`
);

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const pathname = url.pathname;

  const legacyMatch = pathname.match(legacyPath);
  if (legacyMatch) {
    const [, locale, lang, type, rest] = legacyMatch;
    const normalizedType = type === "fix" ? "debug" : type;
    if (locale || type === "fix") {
      const newPathname = `/${lang}/${normalizedType}${rest ?? ""}`;
      return Response.redirect(`${url.origin}${newPathname}${url.search}`, 301);
    }
  }

  if (storagePath.test(pathname)) {
    return new Response("Not Found", { status: 404 });
  }

  const match = pathname.match(datedPath);
  if (match) {
    const [, lang, type, date] = match;

    if (date > todayInJapan()) {
      return new Response("Not Found", { status: 404 });
    }

    // One address per page: /c/read/2026-08-21.html and a trailing slash
    // used to be normalized by Pages' own .html handling, which never sees
    // these URLs now that no file sits at them.
    const canonicalPath = `/${lang}/${type}/${date}`;
    if (pathname !== canonicalPath) {
      return Response.redirect(`${url.origin}${canonicalPath}${url.search}`, 308);
    }

    return context.env.ASSETS.fetch(
      new Request(new URL(storedPage(lang, type, date), url.origin), context.request)
    );
  }

  const latestMatch = pathname.match(latestAliasPath);
  if (latestMatch) {
    const [, lang, type] = latestMatch;
    const latest = await latestPublishedDate(lang, type, context, url.origin);

    if (!latest) {
      return new Response("Not Found", { status: 404 });
    }

    const target = new URL(storedPage(lang, type, latest), url.origin);

    // Serves the dated page's bytes as-is at the bare category URL. Its own
    // <link rel="canonical"> already points at the dated URL, so this never
    // creates duplicate-content ambiguity — it's a transparent alias, not a
    // redirect (the address bar keeps showing the bare category URL).
    return context.env.ASSETS.fetch(new Request(target, context.request));
  }

  return context.next();
}

// Where the page for a dated URL is stored (extensionless, as Pages serves
// it): /c/read/2026-08-21 -> /c/read/2026/08/2026-08-21.
function storedPage(lang, type, date) {
  return `/${lang}/${type}/${date.slice(0, 4)}/${date.slice(5, 7)}/${date}`;
}

// Reads the newest date off {lang}/{type}/archive.html rather than trusting
// the clock: archive.html's top <li> is always the latest published date
// (§7.1a), and nothing else on that page matches this URL shape, so the
// first match is unambiguous. Returns null if the combo has never been
// published (empty archive) or the archive page itself is missing — both
// surface as a 404 at the call site, same as an unpublished "today" always
// has.
async function latestPublishedDate(lang, type, context, origin) {
  const archiveUrl = new URL(`/${lang}/${type}/archive`, origin);
  const res = await context.env.ASSETS.fetch(new Request(archiveUrl));
  if (!res.ok) {
    return null;
  }

  const html = await res.text();
  const match = html.match(
    new RegExp(`href="/${lang}/${type}/(\\d{4}-\\d{2}-\\d{2})"`)
  );
  if (!match) {
    return null;
  }

  // Guards against a hand-edited archive.html ever putting a future date on
  // top — the alias must obey the same "nothing from the future" rule as a
  // direct dated URL (§5.1).
  const latest = match[1];
  return latest <= todayInJapan() ? latest : null;
}

function todayInJapan() {
  const parts = new Intl.DateTimeFormat("en", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());

  const values = Object.fromEntries(
    parts.map(({ type, value }) => [type, value])
  );

  return `${values.year}-${values.month}-${values.day}`;
}
