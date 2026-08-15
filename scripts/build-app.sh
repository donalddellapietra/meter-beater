#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo "usage: scripts/build-app.sh [release|debug]" >&2
  exit 2
fi

build_arguments=(-c "$configuration" --product AIUsageTracker)
if [[ "$configuration" == "release" && "${UNIVERSAL_BUILD:-1}" != "0" ]]; then
  build_arguments+=(--arch arm64 --arch x86_64)
fi

swift build "${build_arguments[@]}"
bin_path="$(swift build "${build_arguments[@]}" --show-bin-path)"
if [[ "$configuration" == "debug" ]]; then
  app_path="$repo_root/dist/Meter Beater Debug.app"
else
  app_path="$repo_root/dist/Meter Beater.app"
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/AIUsageTracker" "$app_path/Contents/MacOS/AIUsageTracker"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
for localization in "$repo_root"/Resources/*.lproj; do
  cp -R "$localization" "$app_path/Contents/Resources/"
done

signing_identity="${SIGNING_IDENTITY:--}"
codesign_arguments=(
  --force
  --sign "$signing_identity"
  --options runtime
  --entitlements "$repo_root/Resources/AIUsageTracker.entitlements"
)
if [[ "$signing_identity" != "-" ]]; then
  codesign_arguments+=(--timestamp)
fi
codesign "${codesign_arguments[@]}" "$app_path" >/dev/null
codesign --verify --deep --strict "$app_path"
echo "$app_path"
