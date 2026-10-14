# offsight
Protect yourself from accidentally sharing your camera in virtual meetings on Zoom, Teams, Google meet etc. A default graphic will be your camera image till you explicitly provide an approval for access to the live cam. This will be per session. Offsight will act like a physical shutter that we unfortunately can't use with recent macs


## Status

Requirements, architecture, Apple account setup, the [backlog](docs/04-backlog.md), [App Store notes](docs/05-app-review-notes.md) and [releasing](docs/06-releasing.md) are in [`docs/`](docs/). The M0 working slice is done; the v1.0 must-haves are implemented and awaiting on-device verification.

For people using OffSight: the [User Guide](App/Help/index.html) (a single HTML page, bundled in the app and opened from **OffSight Help** in the menu) covers setup, choosing OffSight Camera in each meeting app, everyday use, settings and troubleshooting.

## Building (developers)

Requires macOS 13+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate            # creates OffSight.xcodeproj from project.yml
./scripts/dev-install.sh     # dev-signed build, installed to /Applications and launched
swift test --package-path Packages/OffSightCore   # core logic unit tests
./scripts/test-on-device.sh  # on-device checks against the installed Debug build (Tools/OffSightTest)
```

The on-device tool runs 17 automated checks (approval flow, timings, Photo Booth, QuickTime, UI, fail-closed) and guided checks for the main meeting apps, and writes a Markdown report; see [Tools/OffSightTest/README.md](Tools/OffSightTest/README.md).

Signing identifiers live in `Config/Signing.xcconfig`. **Never** commit certificates, keys, profiles or passwords.

Project site (GitHub Pages, published from [`site/`](site/) plus the help page): home, [privacy policy](site/privacy.html) and [support](site/support.html). Security reports: see [SECURITY.md](SECURITY.md). OffSight is provided as is, without warranty or guaranteed support.
