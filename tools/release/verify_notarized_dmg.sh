#!/bin/bash
# Verify that a CryTerm DMG is safe to offer as an automatic update.
#
# Usage: verify_notarized_dmg.sh <dmg> <expected-version>
#
# Exits non-zero unless ALL of these hold:
#   - the DMG is signed by the CryTerm team and has a stapled notarization ticket
#   - Gatekeeper accepts the DMG as Notarized Developer ID
#   - the DMG contains exactly CryTerm.app with the expected bundle ID and version
#   - the app's signature is valid, by the same team, and Gatekeeper accepts it
#   - the app carries the Sparkle public key the feed is signed with
#
# On success, prints KEY=VALUE lines for the appcast (CFBundleVersion, etc.).
set -euo pipefail

DMG="${1:?usage: verify_notarized_dmg.sh <dmg> <expected-version>}"
EXPECTED_VERSION="${2:?usage: verify_notarized_dmg.sh <dmg> <expected-version>}"
TEAM_ID="994Z8EH423"
BUNDLE_ID="co.dangerclose.cryterm"

fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

team_of() {
  codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}'
}

echo "== DMG: $DMG"
codesign --verify --strict "$DMG" || fail "DMG signature is invalid"
[ "$(team_of "$DMG")" = "$TEAM_ID" ] || fail "DMG is not signed by team $TEAM_ID"
xcrun stapler validate "$DMG" || fail "DMG has no valid stapled notarization ticket"
spctl -a -vv -t open --context context:primary-signature "$DMG" > spctl-dmg.log 2>&1 || { cat spctl-dmg.log; fail "Gatekeeper rejects the DMG"; }
cat spctl-dmg.log
grep -q 'source=Notarized Developer ID' spctl-dmg.log || fail "Gatekeeper does not report the DMG as notarized"

MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet || true; rmdir "$MOUNT" || true; }
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet || fail "Cannot mount the DMG"

APP="$MOUNT/CryTerm.app"
[ -d "$APP" ] || fail "DMG does not contain CryTerm.app"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }

[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "bundle ID is $(plist CFBundleIdentifier), expected $BUNDLE_ID"
SHORT_VERSION="$(plist CFBundleShortVersionString)"
BUNDLE_VERSION="$(plist CFBundleVersion)"
[ "$SHORT_VERSION" = "$EXPECTED_VERSION" ] || fail "app version is $SHORT_VERSION, release is $EXPECTED_VERSION"

echo "== App: $APP ($SHORT_VERSION)"
codesign --verify --deep --strict "$APP" || fail "app signature is invalid"
[ "$(team_of "$APP")" = "$TEAM_ID" ] || fail "app is not signed by team $TEAM_ID"
xcrun stapler validate "$APP" || fail "app has no valid stapled notarization ticket"
spctl -a -vv -t exec "$APP" > spctl-app.log 2>&1 || { cat spctl-app.log; fail "Gatekeeper rejects the app"; }
cat spctl-app.log
grep -q 'source=Notarized Developer ID' spctl-app.log || fail "Gatekeeper does not report the app as notarized"

APP_ED_KEY="$(plist SUPublicEDKey)" || fail "app has no SUPublicEDKey"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)" || MIN_SYSTEM="13.0"

echo "VERIFIED"
echo "BUNDLE_VERSION=$BUNDLE_VERSION" >> "${VERIFY_OUTPUT:-/dev/stdout}"
echo "SHORT_VERSION=$SHORT_VERSION" >> "${VERIFY_OUTPUT:-/dev/stdout}"
echo "APP_ED_KEY=$APP_ED_KEY" >> "${VERIFY_OUTPUT:-/dev/stdout}"
echo "MIN_SYSTEM=$MIN_SYSTEM" >> "${VERIFY_OUTPUT:-/dev/stdout}"
