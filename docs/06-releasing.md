# OffSight — Releasing

Two builds come from one source tree (NFR-17):

| Build | Configuration | Signing | Where it goes |
|---|---|---|---|
| Homebrew | `Release` | Developer ID, notarized | GitHub Release (`.zip`, `.dmg`) and the Homebrew cask |
| Mac App Store | `AppStore` | Apple Distribution | App Store Connect (TestFlight, then review) |

The Homebrew build also shows the website for browser meetings (UR-34a); the App Store build shows the browser name only. Everything else is identical.

## One-time setup

1. **Certificates and profiles:** `docs/03-apple-developer-setup.md` steps 4–5: Developer ID Application, Apple Distribution and Mac Installer Distribution certificates; four distribution profiles named exactly **OffSight DevID App**, **OffSight DevID Extension**, **OffSight MAS App** and **OffSight MAS Extension** (the workflow refers to them by name).
2. **App Store Connect API key** (step 6) with the App Manager role.
3. **GitHub environment `release`** (step 7), with required reviewers, holding these secrets:

| Secret | Used by |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_P12_PASSWORD` | Homebrew build |
| `PROFILE_DEVID_APP_BASE64`, `PROFILE_DEVID_EXT_BASE64` | Homebrew build |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64`, `APPLE_DISTRIBUTION_CERT_P12_PASSWORD` | App Store build |
| `MAC_INSTALLER_CERT_P12_BASE64`, `MAC_INSTALLER_CERT_P12_PASSWORD` | App Store build |
| `PROFILE_MAS_APP_BASE64`, `PROFILE_MAS_EXT_BASE64` | App Store build |
| `ASC_API_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | Notarization and App Store upload |
| `HOMEBREW_TAP_TOKEN` (optional) | Pushing the cask to the tap |

4. **Homebrew tap:** create the public repository `astatine-/homebrew-offsight` with an empty `Casks/` folder. Users then install with `brew install --cask astatine-/offsight/offsight`. For the workflow to update it automatically, add `HOMEBREW_TAP_TOKEN`: a fine-grained token with *Contents: read and write* on that repository only. Without it, the cask file is attached to the GitHub Release for you to commit by hand.

No certificate, key, profile or password is ever committed (NFR-17a); gitleaks runs on every push.

## Releasing a version

1. Set `MARKETING_VERSION` in `Config/Base.xcconfig` (for example `1.0.0`), update the help page and site if anything user-visible changed, and merge to `main`.
2. Tag and push: `git tag v1.0.0 && git push origin v1.0.0`.
3. Approve the `release` environment when GitHub asks. Two jobs run:
   - **Homebrew build:** archive → sign with Developer ID → notarize → staple → `.zip` and `.dmg` → GitHub Release with `SHA256SUMS` and `offsight.rb` → push the cask to the tap (if the token is set).
   - **Mac App Store upload:** archive → sign → upload. The build appears in App Store Connect › TestFlight after processing.
4. In App Store Connect, attach the build to the version and submit it for review (see `docs/05-app-review-notes.md`).

A manual run (Actions › Release › Run workflow, with a version) builds, notarizes and uploads, but does not create a tag or GitHub Release; the files are kept as a workflow artifact.

## Releasing from a Mac without the workflow

```
VERSION=1.0.0 NOTARY_PROFILE=offsight scripts/release-homebrew.sh   # Developer ID build in build/release
VERSION=1.0.0 scripts/appstore-upload.sh                           # App Store upload
```

Both use automatic signing with your Xcode account unless `OFFSIGHT_APP_PROFILE` and `OFFSIGHT_EXT_PROFILE` name the profiles to use. For notarization, create the keychain profile once with `xcrun notarytool store-credentials offsight`, or set the `ASC_*` variables.

## Build numbers and the camera extension

Each release uses the Unix time as the build number for both the app and the camera extension, so macOS always installs the new extension. Updating a camera extension can need a restart before it runs again; OffSight tells the user if so.
