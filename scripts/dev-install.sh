#!/bin/bash
# Build a development-signed OffSight and install it into /Applications.
# System extensions can only be activated from an app in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "XcodeGen is required:  brew install xcodegen" >&2
  exit 1
fi

# xcodebuild needs the full Xcode, not just the Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is not using a full Xcode installation." >&2
  echo "Point it at Xcode (adjust the path if Xcode lives elsewhere), then re-run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "  sudo xcodebuild -license accept" >&2
  echo "  xcodebuild -runFirstLaunch" >&2
  exit 1
fi

# The app gets a fresh build number every time. The camera extension keeps its build number
# unless its code changed: macOS replaces an installed system extension only when that number
# changes, and a replaced camera extension may not start again until the Mac restarts.
BUILD_NUMBER=$(date +%s)
mkdir -p build
EXT_HASH=$(find CameraExtension Packages/OffSightCore/Sources Config -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1)
EXT_STATE=build/.extension-build
if [[ -f "$EXT_STATE" ]] && [[ "$(cut -d' ' -f1 "$EXT_STATE")" == "$EXT_HASH" ]]; then
  EXTENSION_BUILD=$(cut -d' ' -f2 "$EXT_STATE")
  EXTENSION_CHANGED=no
else
  EXTENSION_BUILD=$BUILD_NUMBER
  EXTENSION_CHANGED=yes
fi

xcodegen generate
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration Debug \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" EXTENSION_BUILD_VERSION="$EXTENSION_BUILD" build
echo "$EXT_HASH $EXTENSION_BUILD" > "$EXT_STATE"

APP="build/DerivedData/Build/Products/Debug/OffSight.app"
echo "Built $APP (app build $BUILD_NUMBER, camera extension build $EXTENSION_BUILD)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" || true

pkill -x OffSight 2>/dev/null || true
rm -rf /Applications/OffSight.app
cp -R "$APP" /Applications/
echo "Installed to /Applications/OffSight.app — launching"
open /Applications/OffSight.app
if [[ "$EXTENSION_CHANGED" == yes ]]; then
  echo
  echo "The camera extension changed, so macOS will replace it. If OffSight Camera does not"
  echo "appear within ~15 seconds (the OffSight menu says so too), restart the Mac once."
fi
