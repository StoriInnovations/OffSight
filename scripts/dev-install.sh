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

# macOS only replaces an installed system extension when its build number changes,
# so every dev build gets a fresh one.
BUILD_NUMBER=$(date +%s)

xcodegen generate
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration Debug \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

APP="build/DerivedData/Build/Products/Debug/OffSight.app"
echo "Built $APP (build $BUILD_NUMBER)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" || true

pkill -x OffSight 2>/dev/null || true
rm -rf /Applications/OffSight.app
cp -R "$APP" /Applications/
echo "Installed to /Applications/OffSight.app — launching"
open /Applications/OffSight.app
