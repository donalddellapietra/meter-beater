#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

scripts/build-app.sh release

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Resources/Info.plist")"
app_path="$repo_root/dist/Meter Beater.app"
architecture_label="universal"
if [[ "${UNIVERSAL_BUILD:-1}" == "0" ]]; then
  architecture_label="$(uname -m)"
fi
archive_name="Meter-Beater-${version}-macOS-${architecture_label}.zip"
archive_path="$repo_root/dist/$archive_name"
checksum_path="$repo_root/dist/SHA256SUMS"
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
unzip -tq "$archive_path"
(
  cd "$repo_root/dist"
  LC_ALL=C shasum -a 256 "$archive_name"
) > "$checksum_path"
echo "$archive_path"
echo "$checksum_path"
