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
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" EXTENSION_BUILD_VERSION="${EXTENSION_BUILD}" build
echo "$EXT_HASH ${EXTENSION_BUILD}" > "$EXT_STATE"

APP="build/DerivedData/Build/Products/Debug/OffSight.app"
echo "Built $APP (app build $BUILD_NUMBER, camera extension build ${EXTENSION_BUILD})"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" || true

# Quit the running copy and wait for it to exit: replacing or opening the app while the old
# process is still shutting down makes Launch Services fail with error -600.
pkill -x OffSight 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -x OffSight >/dev/null || break; sleep 0.1; done
rm -rf /Applications/OffSight.app
cp -R "$APP" /Applications/
echo "Installed to /Applications/OffSight.app — launching"
launched=no
for attempt in 1 2 3; do
  if open /Applications/OffSight.app 2>/dev/null; then launched=yes; break; fi
  sleep "$attempt"
done
if [[ "$launched" == no ]]; then
  echo "Could not launch OffSight automatically. Open it from Applications." >&2
fi
# OffSight asks macOS to install its camera extension when it launches. Wait for macOS to list
# this build, then say what it needs. "[activated enabled]" with this build is the one that runs
# (perhaps only after a restart); an older build "waiting to uninstall on reboot" goes at the next
# restart. OffSight › About shows the build actually running.
echo
echo "Waiting for macOS to pick up camera extension build ${EXTENSION_BUILD}..."
LIST=""
for _ in $(seq 1 30); do
  LIST=$(systemextensionsctl list 2>/dev/null | grep -i "offsight" || true)
  if grep -q "/${EXTENSION_BUILD})" <<<"$LIST"; then break; fi
  sleep 1
done
echo "Camera extension builds known to macOS:"
echo "${LIST:-  none}"
MINE=$(grep "/${EXTENSION_BUILD})" <<<"$LIST" || true)
echo
if [[ -z "$MINE" ]]; then
  echo "macOS hasn't installed build ${EXTENSION_BUILD}. Open OffSight › Settings › Advanced (or About) for"
  echo "the reason; Copy Diagnostics includes the install error."
elif grep -q "waiting for user" <<<"$MINE"; then
  echo "Allow it: System Settings › General › Login Items & Extensions › Camera Extensions › OffSight."
elif grep -q "activated enabled" <<<"$MINE" && grep -q "waiting to uninstall\|terminated" <<<"$LIST"; then
  echo "Build ${EXTENSION_BUILD} is installed. Restart the Mac to start it (macOS stops the old one but"
  echo "often won't start a replaced camera extension until then)."
elif grep -q "activated enabled" <<<"$MINE"; then
  if [[ "${EXTENSION_CHANGED}" == yes ]]; then
    echo "Build ${EXTENSION_BUILD} is installed. If OffSight › About doesn't say \"up to date\" within ~15 s,"
    echo "restart the Mac once."
  else
    echo "Camera extension unchanged (build ${EXTENSION_BUILD}); no restart needed."
  fi
else
  echo "Build ${EXTENSION_BUILD}: $MINE"
fi
