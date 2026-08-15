#!/bin/zsh
# One-command marketing pipeline:
#   captures (debug app harness) -> React/JSX shot components -> static HTML
#   -> WebKit-rendered PNGs at exact pixel sizes, in English and Chinese.
# Requires: node + npm, ImageMagick (`magick`) for capture trimming.
set -euo pipefail

repo_root="${0:A:h:h}"
captures="$repo_root/marketing/captures"

cd "$repo_root"
timeout 540 swift build --product AIUsageTracker
bin="$(swift build --show-bin-path)/AIUsageTracker"
mkdir -p "$captures"

capture() { # lang appearance range achievement outfile
  local lang="$1" appearance="$2" range="$3" achievement="$4" out="$5"
  local -a run_env
  run_env=(
    AI_USAGE_TRACKER_DISABLE_REFRESH=1
    "AI_USAGE_TRACKER_LANGUAGE=$lang"
    "AI_USAGE_TRACKER_CAPTURE_PATH=$captures/$out"
  )
  [[ -n "$appearance" ]] && run_env+=("AI_USAGE_TRACKER_CAPTURE_APPEARANCE=$appearance")
  [[ -n "$range" ]] && run_env+=("AI_USAGE_TRACKER_DATE_RANGE=$range")
  [[ "$achievement" == "1" ]] && run_env+=(AI_USAGE_TRACKER_CAPTURE_ACHIEVEMENT=1)
  env "${run_env[@]}" timeout 45 "$bin" >/dev/null 2>&1 || true
  [[ -f "$captures/$out" ]] || { echo "capture failed: $out" >&2; exit 1; }
}

capture english "" "" "" en-light.png
capture english dark "" "" en-dark.png
capture english "" last30 "" en-30d.png
capture english "" "" 1 en-toast.png
capture simplifiedChinese "" "" "" zh-light.png
capture simplifiedChinese dark "" "" zh-dark.png
capture simplifiedChinese "" last30 "" zh-30d.png
capture simplifiedChinese "" "" 1 zh-toast.png
cp "$repo_root/Resources/AppIcon.png" "$captures/icon.png"

# Trim the capture window's chrome strip.
for f in "$captures"/en-*.png "$captures"/zh-*.png; do
  timeout 30 magick "$f" -fuzz 2% -trim +repage "$f"
done

cd "$repo_root/marketing"
[[ -d node_modules ]] || timeout 300 npm install --no-fund --no-audit
timeout 120 node build.mjs
mkdir -p out/captures
cp "$captures"/*.png out/captures/

while IFS=$'\t' read -r html png w h; do
  timeout 60 swift render-html.swift "$html" "$png" "$w" "$h"
  echo "rendered marketing/$png"
done < out/render-list.tsv
