#!/bin/bash
# Build a development-signed OffSight and install it into /Applications.
# System extensions can only be activated from an app in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "XcodeGen is required:  brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
xcodebuild -project OffSight.xcodeproj -scheme OffSight -configuration Debug \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build

APP="build/DerivedData/Build/Products/Debug/OffSight.app"
echo "Built $APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" || true

pkill -x OffSight 2>/dev/null || true
rm -rf /Applications/OffSight.app
cp -R "$APP" /Applications/
echo "Installed to /Applications/OffSight.app — launching"
open /Applications/OffSight.app
