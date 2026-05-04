#!/usr/bin/env bash
# Sign a built DMG with the Sparkle EdDSA private key (from Keychain) and
# print an appcast <item> snippet ready to paste into appcast.xml.
#
# Usage: bash scripts/sign-appcast.sh <DMG path> <version>
# Example: bash scripts/sign-appcast.sh Dropshit.dmg 1.5.0

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-Dropshit.dmg}"
VERSION="${2:-}"

if [ -z "${VERSION}" ]; then
  echo "Usage: $0 <DMG path> <version>"
  exit 1
fi

if [ ! -f "${DMG}" ]; then
  echo "ERROR: DMG not found at ${DMG}"
  exit 1
fi

SIGN_TOOL="$(find .build -type f -name sign_update | head -1)"
if [ -z "${SIGN_TOOL}" ]; then
  echo "ERROR: sign_update not found — run 'swift package resolve' first."
  exit 1
fi

# sign_update prints `sparkle:edSignature="..." length="..."` to stdout.
SIG_LINE="$("${SIGN_TOOL}" "${DMG}")"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
DMG_NAME="$(basename "${DMG}")"

cat <<XML
        <item>
            <title>Dropshit ${VERSION}</title>
            <link>https://github.com/iamsumanp/Dropshit/releases/tag/v${VERSION}</link>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <pubDate>${PUBDATE}</pubDate>
            <description><![CDATA[See release notes at https://github.com/iamsumanp/Dropshit/releases/tag/v${VERSION}]]></description>
            <enclosure
                url="https://github.com/iamsumanp/Dropshit/releases/download/v${VERSION}/${DMG_NAME}"
                ${SIG_LINE}
                type="application/octet-stream" />
        </item>
XML
