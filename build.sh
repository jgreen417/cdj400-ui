#!/bin/zsh
# Builds "CDJ-400 Sticks.app" from source and installs it in ~/Applications
# (or the folder given as the first argument). UNIVERSAL=1 builds for both
# Apple Silicon and Intel, as release.sh does.
set -euo pipefail
cd "$(dirname "$0")"

flags=(-c release)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then flags+=(--arch arm64 --arch x86_64); fi
swift build "${flags[@]}"
BIN="$(swift build "${flags[@]}" --show-bin-path)/CDJ400UI"

APP="${1:-$HOME/Applications}/CDJ-400 Sticks.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CDJ400UI"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The cdj400-* tools the app runs; it prefers this copy over ~/bin.
cp -Rp tools "$APP/Contents/Resources/tools"
# Ad-hoc signature so notifications and removable-volume access work locally.
codesign --force --sign - "$APP" >/dev/null

echo "built: $APP"
