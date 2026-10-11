# OffSight — Apple Developer Account Setup (one-time)

This runbook sets up the identifiers, certificates, profiles and keys OffSight needs for signing. It is done once by the Apple Developer **Account Holder** or an **Admin**. See [Architecture §13](02-architecture-and-implementation.md#13-build-signing--distribution-nfr-17-nfr-17a).

> **Never commit, email or paste into chat** any `.p12`, `.p8`, `.cer`, `.provisionprofile` file or password. Store them in a password manager, then in GitHub encrypted secrets (step 7). The Team ID, bundle IDs and app group are **not** secret.

Portal labels can change slightly between Apple redesigns. The steps below follow developer.apple.com → **Account** → **Program resources**.

## 0. Note the Team ID
**Account → Membership details → Team ID**. OffSight's Team ID is **`83QJANVRBL`**.

## 1. App group: nothing to register
OffSight uses the macOS team-prefixed app group `83QJANVRBL.com.storiinnovations.offsight`. On macOS this is tied to the code signature, so it needs **no** registration and **no** App Groups capability on the App IDs.

## 2. Identifiers (Certificates, IDs & Profiles → Identifiers)
Create two App IDs. For each: **+** → **App IDs** → **Continue** → type **App** → **Continue**, then:

| Description | Bundle ID (Explicit) | Platform | Capabilities to tick |
|-------------|----------------------|----------|----------------------|
| OffSight | `com.storiinnovations.offsight` | macOS | **System Extension** |
| OffSight Camera Extension | `com.storiinnovations.offsight.camera-extension` | macOS | *(none)* |

**Continue** → **Register**.

## 3. Certificate signing request (on a Mac)
**Keychain Access → Keychain Access menu → Certificate Assistant → Request a Certificate From a Certificate Authority…**
Enter your email and the name "OffSight Signing", choose **Saved to disk**, and save the `.certSigningRequest` file. You can reuse it for each certificate below.

## 4. Certificates (Certificates → +)

| Certificate type | Used for | Note |
|------------------|----------|------|
| **Developer ID Application** (G2 Sub-CA) | Homebrew build | **Only the Account Holder** can create it. The number allowed per team is limited, so don't create spares. |
| **Apple Distribution** | App Store build (the app itself) | |
| **Mac Installer Distribution** | Signing the `.pkg` uploaded to the App Store | |
| Apple Development | Local builds | Optional: Xcode creates this automatically when you sign in. |

For each one: upload the CSR → **Download** the `.cer` → double-click it to install into your login keychain.

Then export each certificate **with its private key** for CI: **Keychain Access → My Certificates** → right-click the certificate → **Export…** → `.p12` → set a strong password. Store the `.p12` and its password in your password manager.

## 5. Profiles (Profiles → +)
Create four distribution profiles. For each: pick the type, choose the App ID, choose the matching certificate, name it, then **Generate** → **Download**.

| Profile type | App ID | Certificate | Name |
|--------------|--------|-------------|------|
| Distribution → **Developer ID** | `com.storiinnovations.offsight` | Developer ID Application | OffSight DevID App |
| Distribution → **Developer ID** | `…offsight.camera-extension` | Developer ID Application | OffSight DevID Extension |
| Distribution → **Mac App Store Connect** | `com.storiinnovations.offsight` | Apple Distribution | OffSight MAS App |
| Distribution → **Mac App Store Connect** | `…offsight.camera-extension` | Apple Distribution | OffSight MAS Extension |

Development profiles: let Xcode manage them (Signing & Capabilities → *Automatically manage signing*). Xcode registers your Mac under **Devices** automatically.

## 6. App Store Connect setup
1. **API key** (for notarization and uploads from CI): App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys** → **+**. Name it "OffSight CI" and give it the **App Manager** role. **Download the `.p8` straight away; it can only be downloaded once.** Note the **Key ID** and **Issuer ID**. If this is the first key, the Account Holder must request API access first.
2. **App record** (needed for the S1 TestFlight spike): **Apps → + → New App** → Platform **macOS**, Name **OffSight** (have a backup name ready in case it's taken), Bundle ID `com.storiinnovations.offsight`, SKU `offsight-mac`.
3. **Business → Agreements:** make sure the free-apps agreement is active.

## 7. GitHub secrets (repository → Settings → Environments)
1. **New environment** `release` → turn on **Required reviewers** (you) → restrict it to tags matching `v*`.
2. Add these **environment secrets**. Base64-encode files on a Mac with `base64 -i <file> | pbcopy`.

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERT_P12_BASE64` / `DEVELOPER_ID_CERT_P12_PASSWORD` | Developer ID Application `.p12` + password |
| `APPLE_DISTRIBUTION_CERT_P12_BASE64` / `APPLE_DISTRIBUTION_CERT_P12_PASSWORD` | Apple Distribution `.p12` + password |
| `MAC_INSTALLER_CERT_P12_BASE64` / `MAC_INSTALLER_CERT_P12_PASSWORD` | Mac Installer Distribution `.p12` + password |
| `PROFILE_DEVID_APP_BASE64`, `PROFILE_DEVID_EXT_BASE64`, `PROFILE_MAS_APP_BASE64`, `PROFILE_MAS_EXT_BASE64` | The four profiles from step 5 |
| `ASC_API_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | API key from step 6 |

3. Delete the exported files from Downloads and Desktop once they're in the password manager and GitHub.

## 8. Tell the project the Team ID
Done: `Config/Signing.xcconfig` contains `TEAM_ID = 83QJANVRBL`. This is the only value from this runbook that goes into the repository.
