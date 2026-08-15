# Release process

Meter Beater is distributed outside the Mac App Store as a universal ZIP.
Apple requires outside-the-store software to use a Developer ID Application
signature, hardened runtime, a secure timestamp, and notarization. The local and
CI package remains ad-hoc signed so contributors do not need release credentials.

## 1. Set the version

Update `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist`. The package filename is derived from the short version.

## 2. Verify the source tree

From a clean checkout:

```sh
swift test -Xswiftc -warnings-as-errors
git diff --check
scripts/package-app.sh
file "dist/Meter Beater.app/Contents/MacOS/AIUsageTracker"
codesign --verify --deep --strict --verbose=2 "dist/Meter Beater.app"
unzip -tq dist/Meter-Beater-*-macOS-universal.zip
LC_ALL=C shasum -a 256 -c dist/SHA256SUMS
```

The executable must report both `arm64` and `x86_64` architectures.

## 3. Configure notarization once

Notary credentials live in the login keychain under the profile name
**`meter-beater-notary`**. It already exists on the release machine, created
from an App Store Connect API key (the `.p8` stays outside this repo):

```sh
xcrun notarytool store-credentials meter-beater-notary \
  --key <path to AuthKey_XXXXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
```

Verify it at any time with
`xcrun notarytool history --keychain-profile meter-beater-notary`.

## 4. Build the distribution artifact

The signing identity for this app is
`Developer ID Application: Eudaimonic Inc (C2RN7J79X9)`.

```sh
export SIGNING_IDENTITY="Developer ID Application: Eudaimonic Inc (C2RN7J79X9)"
export NOTARY_KEYCHAIN_PROFILE="meter-beater-notary"
scripts/notarize-app.sh
```

The script builds a universal binary, enables hardened runtime, applies a secure
timestamp, submits the ZIP with `notarytool`, staples and validates the ticket,
runs Gatekeeper assessment, then recreates the ZIP and checksum from the stapled
app.

## 5. Publish intentionally

Create an annotated `v<version>` tag only after the notarized artifact passes the
checks above. Attach the versioned ZIP and `SHA256SUMS` to the GitHub release and
use `RELEASE_NOTES.md` as the release body. Tagging and GitHub Release publication
are deliberately not automatic.

Apple references:

- <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- <https://developer.apple.com/help/account/certificates/create-developer-id-certificates/>
