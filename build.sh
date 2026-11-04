#!/bin/zsh
# Builds "CDJ-400 Sticks.app" from source and installs it in ~/Applications
# (or the folder given as the first argument).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="${1:-$HOME/Applications}/CDJ-400 Sticks.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CDJ400UI "$APP/Contents/MacOS/CDJ400UI"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The cdj400-* tools the app runs; it prefers this copy over ~/bin.
cp -Rp tools "$APP/Contents/Resources/tools"
# Ad-hoc signature so notifications and removable-volume access work locally.
codesign --force --sign - "$APP" >/dev/null

echo "built: $APP"
