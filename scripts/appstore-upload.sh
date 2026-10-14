#!/bin/bash
# Archive the Mac App Store build and upload it to App Store Connect (it appears in TestFlight).
#
# Signing is automatic by default: Xcode creates or downloads the Apple Distribution certificate
# and the Mac App Store profiles for the app and the camera extension. It needs either
#  - Xcode signed in to an account with the App Manager (or Admin) role, or
#  - an App Store Connect API key: ASC_KEY_PATH (the .p8 file), ASC_KEY_ID, ASC_ISSUER_ID.
# For manual signing (the release workflow), set OFFSIGHT_APP_PROFILE and OFFSIGHT_EXT_PROFILE
# to the Mac App Store profile names, with the certificates installed (scripts/ci/import-signing.sh).
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

SIGNING=()
EXPORT_OPTIONS=packaging/ExportOptions-AppStore.plist
if [[ -n "${OFFSIGHT_APP_PROFILE:-}" && -n "${OFFSIGHT_EXT_PROFILE:-}" ]]; then
  TEAM_ID=$(sed -n 's/^TEAM_ID *= *//p' Config/Signing.xcconfig)
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Distribution"
           "OFFSIGHT_APP_PROFILE=$OFFSIGHT_APP_PROFILE" "OFFSIGHT_EXT_PROFILE=$OFFSIGHT_EXT_PROFILE")
  mkdir -p build
  EXPORT_OPTIONS=build/ExportOptions-AppStore-manual.plist
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>Mac Installer Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>com.storiinnovations.offsight</key><string>$OFFSIGHT_APP_PROFILE</string>
    <key>com.storiinnovations.offsight.camera-extension</key><string>$OFFSIGHT_EXT_PROFILE</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
fi

echo "Archiving OffSight $VERSION ($BUILD) for the Mac App Store…"
xcodegen generate
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration AppStore \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} ${SIGNING[@]+"${SIGNING[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" EXTENSION_BUILD_VERSION="$BUILD" \
  archive

echo "Checking the archive…"
APP="$ARCHIVE/Products/Applications/OffSight.app"
test -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
test -d "$APP/Contents/Library/SystemExtensions/com.storiinnovations.offsight.camera-extension.systemextension"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo
echo "Uploaded OffSight $VERSION ($BUILD). It appears in App Store Connect › TestFlight after processing"
echo "(usually 10–30 minutes). See docs/05-app-review-notes.md for what to tell App Review."
