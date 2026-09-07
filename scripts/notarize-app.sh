#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  echo "SIGNING_IDENTITY must name a Developer ID Application certificate" >&2
  exit 2
fi
if [[ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  echo "NOTARY_KEYCHAIN_PROFILE must name a notarytool keychain profile" >&2
  exit 2
fi

UNIVERSAL_BUILD=1 scripts/package-app.sh

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Resources/Info.plist")"
app_path="$repo_root/dist/Meter Beater.app"
archive_name="Meter-Beater-${version}-macOS-universal.zip"
archive_path="$repo_root/dist/$archive_name"
checksum_path="$repo_root/dist/SHA256SUMS"

notarytool_arguments=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then
  notarytool_arguments+=(--keychain "$NOTARY_KEYCHAIN_PATH")
fi
xcrun notarytool submit "$archive_path" "${notarytool_arguments[@]}" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

# Stapling changes the app bundle, so archive and hash the final bundle again.
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
unzip -tq "$archive_path"
(
  cd "$repo_root/dist"
  LC_ALL=C shasum -a 256 "$archive_name"
) > "$checksum_path"

echo "$archive_path"
echo "$checksum_path"
