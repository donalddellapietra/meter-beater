#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
  echo "usage: scripts/build-app.sh [release|debug]" >&2
  exit 2
fi

binary_paths=()
if [[ "$configuration" == "release" && "${UNIVERSAL_BUILD:-1}" != "0" ]]; then
  # SwiftPM's combined multi-architecture build requires XCBuild, which is not
  # included with the standalone Command Line Tools. Build each slice with the
  # native build system so a universal release does not require full Xcode.
  for architecture in arm64 x86_64; do
    build_arguments=(-c "$configuration" --product AIUsageTracker --arch "$architecture")
    swift build "${build_arguments[@]}"
    bin_path="$(swift build "${build_arguments[@]}" --show-bin-path)"
    binary_paths+=("$bin_path/AIUsageTracker")
  done
else
  build_arguments=(-c "$configuration" --product AIUsageTracker)
  swift build "${build_arguments[@]}"
  bin_path="$(swift build "${build_arguments[@]}" --show-bin-path)"
  binary_paths+=("$bin_path/AIUsageTracker")
fi
if [[ "$configuration" == "debug" ]]; then
  app_path="$repo_root/dist/Meter Beater Debug.app"
else
  app_path="$repo_root/dist/Meter Beater.app"
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if (( ${#binary_paths[@]} == 1 )); then
  cp "${binary_paths[1]}" "$app_path/Contents/MacOS/AIUsageTracker"
else
  lipo -create "${binary_paths[@]}" -output "$app_path/Contents/MacOS/AIUsageTracker"
fi
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
