#!/bin/bash
# Build the Homebrew (Developer ID) release of OffSight: archive, sign, notarize, staple,
# package as .zip and .dmg, and write the Homebrew cask.
#
# Signing:
#  - automatic (default): Xcode's account must be able to use a Developer ID Application
#    certificate (Account Holder or Admin), or
#  - manual (CI): set OFFSIGHT_APP_PROFILE and OFFSIGHT_EXT_PROFILE to the names of the Developer ID
#    provisioning profiles, with the certificate and profiles installed (scripts/ci/import-signing.sh).
# Notarization: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (App Store Connect API key), or
# NOTARY_PROFILE (a `notarytool store-credentials` keychain profile).
# Nothing secret is stored in the repository (NFR-17a).
#
# Usage: VERSION=1.0.0 scripts/release-homebrew.sh   → build/release/
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION, for example VERSION=1.0.0}"
BUILD=${BUILD:-$(date +%s)}
OUT=build/release
ARCHIVE=build/OffSight-DeveloperID.xcarchive
EXPORT=build/DeveloperIDExport
TEAM_ID=$(sed -n 's/^TEAM_ID *= *//p' Config/Signing.xcconfig)

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

SIGNING=()
EXPORT_OPTIONS=build/ExportOptions-DeveloperID.plist
mkdir -p build
if [[ -n "${OFFSIGHT_APP_PROFILE:-}" && -n "${OFFSIGHT_EXT_PROFILE:-}" ]]; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application"
           "OFFSIGHT_APP_PROFILE=$OFFSIGHT_APP_PROFILE" "OFFSIGHT_EXT_PROFILE=$OFFSIGHT_EXT_PROFILE")
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
    <key>com.storiinnovations.offsight</key><string>$OFFSIGHT_APP_PROFILE</string>
    <key>com.storiinnovations.offsight.camera-extension</key><string>$OFFSIGHT_EXT_PROFILE</string>
  </dict>
</dict></plist>
PLIST
else
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
fi

echo "Archiving OffSight $VERSION ($BUILD), Developer ID…"
xcodegen generate
rm -rf "$ARCHIVE" "$EXPORT" "$OUT"
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} ${SIGNING[@]+"${SIGNING[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" EXTENSION_BUILD_VERSION="$BUILD" \
  archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

APP="$EXPORT/OffSight.app"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || { echo "Not Developer ID signed" >&2; exit 1; }

echo "Notarizing…"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
if [[ ${#AUTH[@]} -gt 0 ]]; then
  xcrun notarytool submit "$OUT/notarize.zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
else
  : "${NOTARY_PROFILE:?Set ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID or NOTARY_PROFILE for notarization}"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
fi
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

echo "Packaging…"
ZIP="$OUT/OffSight-$VERSION.zip"
DMG="$OUT/OffSight-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "OffSight $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
xcrun stapler staple "$DMG" || true

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/offsight.rb.template > "$OUT/offsight.rb"
(cd "$OUT" && shasum -a 256 "OffSight-$VERSION.zip" "OffSight-$VERSION.dmg" > SHA256SUMS)

echo
echo "Release files in $OUT:"
ls -l "$OUT"
