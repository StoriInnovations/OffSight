#!/bin/bash
# CI only: put signing material from environment secrets into a temporary keychain and the
# provisioning-profile folders, and write the App Store Connect API key to a temporary file.
# Every value comes from GitHub environment secrets; nothing is stored in the repository.
#
# Certificates: CERT_<n>_P12_BASE64 and CERT_<n>_P12_PASSWORD for n = 1, 2, …
# Profiles:     PROFILE_<n>_BASE64 for n = 1, 2, …
# API key:      ASC_API_KEY_P8_BASE64 (+ ASC_KEY_ID, ASC_ISSUER_ID used by the release scripts)
set -euo pipefail

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD=$(uuidgen)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

n=1
while true; do
  var="CERT_${n}_P12_BASE64"; pass="CERT_${n}_P12_PASSWORD"
  [[ -n "${!var:-}" ]] || break
  echo "${!var}" | base64 --decode > "$RUNNER_TEMP/cert$n.p12"
  security import "$RUNNER_TEMP/cert$n.p12" -k "$KEYCHAIN" -P "${!pass}" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/xcodebuild
  rm "$RUNNER_TEMP/cert$n.p12"
  n=$((n + 1))
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
echo "Imported $((n - 1)) certificate(s)"

for dir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$dir"
done
n=1
while true; do
  var="PROFILE_${n}_BASE64"
  [[ -n "${!var:-}" ]] || break
  file="$RUNNER_TEMP/profile$n.provisionprofile"
  echo "${!var}" | base64 --decode > "$file"
  uuid=$(security cms -D -i "$file" | plutil -extract UUID raw -)
  cp "$file" "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.provisionprofile"
  cp "$file" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.provisionprofile"
  rm "$file"
  n=$((n + 1))
done
echo "Installed $((n - 1)) profile(s)"

if [[ -n "${ASC_API_KEY_P8_BASE64:-}" ]]; then
  echo "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$RUNNER_TEMP/asc.p8"
  echo "ASC_KEY_PATH=$RUNNER_TEMP/asc.p8" >> "$GITHUB_ENV"
fi
