#!/bin/bash
# Builds Multipoint.app into ./build. Pass "install" to also copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Multipoint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Multipoint" "$APP/Contents/MacOS/Multipoint"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# macOS ties the Bluetooth permission to the signature. An ad-hoc signature changes with every build, so each
# rebuild asks again; a real identity (override with SIGN_IDENTITY, or SIGN_IDENTITY=- for ad-hoc) keeps it.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"' || true)}"
# A Developer ID build gets the hardened runtime (with the one entitlement it then needs, Bluetooth) and a secure
# timestamp, which is what Apple's notary service asks for before others can open the app without a warning.
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Multipoint.entitlements --sign "$IDENTITY" "$APP"
else
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built $PWD/$APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Multipoint 2>/dev/null || true
  rm -rf /Applications/Multipoint.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Multipoint.app"
fi
