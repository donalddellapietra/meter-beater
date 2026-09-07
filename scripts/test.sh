#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"
test_arguments=(-Xswiftc -warnings-as-errors)

# Standalone Command Line Tools bundle Swift Testing outside the default
# module/runtime search paths. Full Xcode already supplies those paths.
developer_directory="$(xcode-select -p)"
testing_runtime="$developer_directory/Library/Developer"
if [[ -d "$testing_runtime/Frameworks/Testing.framework" ]]; then
  test_arguments+=(
    -Xswiftc -F -Xswiftc "$testing_runtime/Frameworks"
    -Xlinker -rpath -Xlinker "$testing_runtime/Frameworks"
    -Xlinker -rpath -Xlinker "$testing_runtime/usr/lib"
  )
fi

exec xcrun swift test "${test_arguments[@]}" "$@"
