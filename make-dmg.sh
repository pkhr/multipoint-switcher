#!/bin/bash
# Builds Multipoint.app and wraps it in a disk image for handing to other people: build/Multipoint-<version>.dmg.
#
# For others to open it without a Gatekeeper warning it has to be signed with a Developer ID and notarized by Apple.
# Both the app and the image are notarized and get their tickets stapled, so they also open offline. Store notary
# credentials once (it asks for an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials multipoint --apple-id <you@example.com> --team-id <TEAMID>
# or point NOTARY_PROFILE at a profile you already have.
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh
APP=build/Multipoint.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Multipoint-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)}"
PROFILE="${NOTARY_PROFILE:-multipoint}"
NOTARIZE=0
if [[ -n "$IDENTITY" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  NOTARIZE=1
fi

# Submits a file to Apple and waits; on rejection prints Apple's log and stops.
notarize() {
  local result id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json) || true
  if [[ "$(printf '%s' "$result" | plutil -extract status raw - 2>/dev/null)" != "Accepted" ]]; then
    echo "Apple didn't accept $(basename "$1"):" >&2
    id=$(printf '%s' "$result" | plutil -extract id raw - 2>/dev/null) || true
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
if [[ $NOTARIZE == 1 ]]; then
  ditto -c -k --keepParent "$APP" "$STAGE/Multipoint.zip"
  notarize "$STAGE/Multipoint.zip"
  rm "$STAGE/Multipoint.zip"
  xcrun stapler staple -q "$APP"
fi

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Multipoint" -srcfolder "$STAGE" -format UDZO "$DMG"

if [[ -z "$IDENTITY" ]]; then
  echo "Built $DMG (unsigned: no Developer ID certificate, so other Macs will refuse to open it)"
elif [[ $NOTARIZE == 1 ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
  echo "Built $DMG (signed and notarized)"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "Built $DMG (signed, NOT notarized: other Macs will warn until it is; see the top of this script)"
fi
