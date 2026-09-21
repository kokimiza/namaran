#!/usr/bin/env bash
# Namaran sitemap generator.
#
# An authoring aid like script/content.sh: it runs locally or in GitHub
# Actions and never on Cloudflare Pages. It writes sitemap.xml at the
# repository root as a plain static file, so the deployed site gains no
# request-time code for it (doc/basic-design.md §9.3 explains why this is
# not done in the middleware).
#
# Usage:
#   script/sitemap.sh           rewrite sitemap.xml
#   script/sitemap.sh --check   exit 1 if sitemap.xml is not up to date
#
# Listed URLs are the canonical ones only:
#   /                          the root page
#   /{lang}/{type}/archive     each archive page; lastmod = its newest date
#   /{lang}/{type}/{date}      each dated page listed in that archive.html
#                              whose file exists; lastmod = the date, since a
#                              published page is never edited (§7.1)
# The bare /{lang}/{type} aliases are left out: they serve a dated page's
# bytes, and that page's <link rel="canonical"> points at the dated URL.
#
# archive.html is the source of truth for "published" (§7.1a), the same one
# the middleware reads. Dates after today in Asia/Tokyo are left out, because
# the middleware answers those with 404 (§5.1).
#
# Nothing read from a file is copied into the XML as text: languages and
# types come from the fixed lists below, and a date is only used after it
# matches YYYY-MM-DD and names an existing file. Whatever an archive.html
# contains, the output can only be these URL shapes. The output is sorted and
# depends only on the repository and today's date, so regenerating it with
# nothing new published is a no-op diff.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT_DIR/sitemap.xml"

SITE_ORIGIN="https://namaran.jocarium.productions"
ALL_LANGS=(c cpp rust haskell)
ALL_TYPES=(read write debug)

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Published dates for one combo, newest first.
published_dates() {
  local lang="$1" type="$2" today="$3" archive date
  archive="$ROOT_DIR/$lang/$type/archive.html"
  [ -f "$archive" ] || return 0

  { grep -oE "href=\"/$lang/$type/[0-9]{4}-[0-9]{2}-[0-9]{2}\"" "$archive" || true; } |
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' |
    sort -ru |
    while IFS= read -r date; do
      [[ "$date" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || continue
      [[ "$date" > "$today" ]] && continue
      [ -f "$ROOT_DIR/$lang/$type/$date.html" ] || continue
      echo "$date"
    done
}

render() {
  local today lang type dates newest date
  today="$(TZ=Asia/Tokyo date +%Y-%m-%d)"

  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
  printf '  <url><loc>%s/</loc></url>\n' "$SITE_ORIGIN"

  for lang in "${ALL_LANGS[@]}"; do
    for type in "${ALL_TYPES[@]}"; do
      dates="$(published_dates "$lang" "$type" "$today")"
      [ -n "$dates" ] || continue

      newest="${dates%%$'\n'*}"
      printf '  <url><loc>%s/%s/%s/archive</loc><lastmod>%s</lastmod></url>\n' \
        "$SITE_ORIGIN" "$lang" "$type" "$newest"
      while IFS= read -r date; do
        printf '  <url><loc>%s/%s/%s/%s</loc><lastmod>%s</lastmod></url>\n' \
          "$SITE_ORIGIN" "$lang" "$type" "$date" "$date"
      done <<< "$dates"
    done
  done

  echo '</urlset>'
}

main() {
  case "${1:-}" in
    "")
      render > "$OUT.tmp"
      mv "$OUT.tmp" "$OUT"
      echo "wrote sitemap.xml ($(grep -c '<url>' "$OUT") URLs)"
      ;;
    --check)
      if [ -f "$OUT" ] && render | cmp -s - "$OUT"; then
        echo "sitemap.xml is up to date"
      else
        echo "sitemap.xml is out of date; run script/sitemap.sh" >&2
        exit 1
      fi
      ;;
    -h|--help|help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
}

main "$@"
