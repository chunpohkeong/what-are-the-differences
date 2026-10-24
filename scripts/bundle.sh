#!/bin/bash
# Build release binaries and assemble Delta.app (ad-hoc signed).
# The bundle lives in the build cache because iCloud-synced folders add Finder info that codesign rejects;
# build/Delta.app is a symlink to it.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="$HOME/Library/Caches/DeltaBuild"
swift build -c release --scratch-path "$SCRATCH"
BIN=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)
APP="$SCRATCH/Delta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/DeltaApp" "$BIN/delta" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Finder extension: SwiftPM cannot build app extensions, so compile it directly.
APPEX="$APP/Contents/PlugIns/DeltaFinder.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp Extensions/DeltaFinder/Info.plist "$APPEX/Contents/Info.plist"
xcrun swiftc -O -target "$(uname -m)-apple-macos15.0" -module-name DeltaFinder -parse-as-library -application-extension \
  Extensions/DeltaFinder/FinderSync.swift Sources/DiffCore/OpenRequest.swift Sources/DiffCore/Snapshot.swift \
  -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain -o "$APPEX/Contents/MacOS/DeltaFinder"

# Ad-hoc ("Sign to Run Locally"): inner code first, then the app.
codesign --force -s - --entitlements Extensions/DeltaFinder/DeltaFinder.entitlements "$APPEX"
codesign --force -s - "$APP/Contents/MacOS/delta"
codesign --force -s - "$APP"
# Register the delta:// URL scheme so the CLI can reach the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$APPEX"
mkdir -p build
ln -sfn "$APP" build/Delta.app
echo "Built $APP (linked at $PWD/build/Delta.app)"
