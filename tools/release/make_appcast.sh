#!/bin/bash
# Write a one-item Sparkle appcast for a verified CryTerm DMG.
#
# Usage: make_appcast.sh <dmg> <download-url> <release-notes-url> <out.xml>
# Environment:
#   SPARKLE_ED_PRIVATE_KEY  base64 Ed25519 seed (secret)
#   BUNDLE_VERSION, SHORT_VERSION, APP_ED_KEY, MIN_SYSTEM  from verify_notarized_dmg.sh
#
# Refuses to write the appcast unless the signature it makes verifies against the
# public key embedded in the app being shipped, so a wrong or rotated secret can
# never publish an update that installed copies would reject.
set -euo pipefail

DMG="$1"; URL="$2"; NOTES_URL="$3"; OUT="$4"
: "${SPARKLE_ED_PRIVATE_KEY:?}" "${BUNDLE_VERSION:?}" "${SHORT_VERSION:?}" "${APP_ED_KEY:?}" "${MIN_SYSTEM:?}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ED="$HERE/sparkle/ed25519.swift"

KEY_PUB="$(swift "$ED" public)"
[ "$KEY_PUB" = "$APP_ED_KEY" ] || { echo "Signing key does not match the app's SUPublicEDKey" >&2; exit 1; }

SIG="$(swift "$ED" sign "$DMG")"
swift "$ED" verify "$DMG" "$SIG" "$APP_ED_KEY"
LENGTH="$(stat -f %z "$DMG")"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
URL_X="$(printf '%s' "$URL" | xml_escape)"
NOTES_X="$(printf '%s' "$NOTES_URL" | xml_escape)"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>CryTerm</title>
    <link>https://github.com/mikemackintosh/CryTerm</link>
    <description>CryTerm updates</description>
    <language>en</language>
    <item>
      <title>CryTerm $SHORT_VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:releaseNotesLink>$NOTES_X</sparkle:releaseNotesLink>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <enclosure url="$URL_X"
                 sparkle:version="$BUNDLE_VERSION"
                 sparkle:shortVersionString="$SHORT_VERSION"
                 sparkle:edSignature="$SIG"
                 length="$LENGTH"
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT"
echo "Wrote $OUT for CryTerm $SHORT_VERSION"
