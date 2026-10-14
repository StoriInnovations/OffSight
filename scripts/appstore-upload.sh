#!/bin/bash
# Archive the Mac App Store build and upload it to App Store Connect (it appears in TestFlight).
#
# Signing is automatic: Xcode creates or downloads the Apple Distribution certificate and the
# Mac App Store profiles for the app and the camera extension. It needs either
#  - Xcode signed in to an account with the App Manager (or Admin) role, or
#  - an App Store Connect API key: ASC_KEY_PATH (the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID.
# No credential is ever stored in the repository (NFR-17a).
#
# Usage: scripts/appstore-upload.sh            # version from Config/Base.xcconfig
#        VERSION=1.0.0 scripts/appstore-upload.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }

VERSION=${VERSION:-$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)}
# App Store build numbers must increase for each upload of a version; the extension uses the same.
BUILD=${BUILD:-$(date +%s)}
ARCHIVE=build/OffSight-AppStore.xcarchive
EXPORT=build/AppStoreExport

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "Archiving OffSight $VERSION ($BUILD) for the Mac App Store…"
xcodegen generate
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration AppStore \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" EXTENSION_BUILD_VERSION="$BUILD" \
  archive

echo "Checking the archive…"
APP="$ARCHIVE/Products/Applications/OffSight.app"
test -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
test -d "$APP/Contents/Library/SystemExtensions/com.storiinnovations.offsight.camera-extension.systemextension"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist packaging/ExportOptions-AppStore.plist -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo
echo "Uploaded OffSight $VERSION ($BUILD). It appears in App Store Connect › TestFlight after processing"
echo "(usually 10–30 minutes). See docs/05-app-review-notes.md for what to tell App Review."
