#!/bin/bash
# Builds Multipoint.app and wraps it in a disk image for handing to other people: build/Multipoint-<version>.dmg.
#
# For others to open it without a Gatekeeper warning, the image has to be signed with a Developer ID and notarized.
# Store notary credentials once (it asks for an app-specific password from account.apple.com):
#   xcrun notarytool store-credentials multipoint --apple-id <you@example.com> --team-id <TEAMID>
# and this script will use them. Pick another profile name with NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Multipoint.app/Contents/Info.plist)
DMG="build/Multipoint-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Multipoint.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Multipoint" -srcfolder "$STAGE" -format UDZO "$DMG"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)}"
if [[ -z "$IDENTITY" ]]; then
  echo "Built $DMG (unsigned: no Developer ID certificate, so other Macs will refuse to open it)"
  exit 0
fi
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

PROFILE="${NOTARY_PROFILE:-multipoint}"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Built $DMG (signed and notarized)"
else
  echo "Built $DMG (signed, NOT notarized: other Macs will warn until it is; see the top of this script)"
fi
