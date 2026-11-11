#!/bin/bash
# Archives the iPhone app and uploads it to App Store Connect for TestFlight.
# The app record (bundle ID dev.pkhri.Multipoint.iOS) must already exist there. Each archive's build number is the
# date and time it was made, so builds sort by age in TestFlight whatever their version.
#
# Signs in with the Apple Account in Xcode › Settings › Accounts. That session expires now and then; to avoid it,
# create an App Store Connect API key (Users and Access › Integrations) and set
#   ASC_KEY_PATH=/path/AuthKey_XXXX.p8  ASC_KEY_ID=XXXX  ASC_ISSUER_ID=xxxxxxxx-xxxx-…
# "upload" as the first argument skips the archive step and uploads the existing one.
set -euo pipefail
cd "$(dirname "$0")"

ARCHIVE=../build/ios/Multipoint.xcarchive
AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

if [[ "${1:-}" != "upload" ]]; then
  xcodebuild -project Multipoint.xcodeproj -scheme Multipoint -configuration Release \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d.%H%M)" \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive | tail -1
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath ../build/ios/export -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | tail -5
