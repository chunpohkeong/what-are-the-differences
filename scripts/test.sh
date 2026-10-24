#!/bin/bash
# Run DiffCore tests.
# - Build output goes outside ~/Documents: iCloud adds xattrs there that make codesign fail.
# - With only Command Line Tools, Swift Testing's macro plugin sits in a subfolder the compiler does not search.
set -euo pipefail
cd "$(dirname "$0")/.."
EXTRA=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing)
fi
swift test --scratch-path "$HOME/Library/Caches/DeltaBuild" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
