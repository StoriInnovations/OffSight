# offsight
Protect yourself from accidentally sharing your camera in virtual meetings on Zoom, Teams, Google meet etc. A default graphic will be your camera image till you explicitly provide an approval for access to the live cam. This will be per session. Offsight will act like a physical shutter that we unfortunately can't use with recent macs


## Status

Requirements, architecture and the Apple account setup are in [`docs/`](docs/). Milestone **M0** (project skeleton + first working slice with the built-in camera) is in progress. See the [M0 runbook](docs/spikes/M0-spike-runbook.md).

## Building (developers)

Requires macOS 13+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate            # creates OffSight.xcodeproj from project.yml
./scripts/dev-install.sh     # dev-signed build, installed to /Applications and launched
swift test --package-path Packages/OffSightCore   # core logic unit tests
```

Signing identifiers live in `Config/Signing.xcconfig`. **Never** commit certificates, keys, profiles or passwords.
