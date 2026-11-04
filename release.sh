#!/bin/zsh
# Publishes a release:
#   1. builds a universal app and zips it,
#   2. updates the cask in packaging/ with the zip's checksum and commits that,
#   3. tags v<version>, uploads the zip to a GitHub release,
#   4. copies the cask into the Homebrew tap.
#
# Bump CFBundleShortVersionString (and CFBundleVersion) in Info.plist and commit,
# then run ./release.sh. ./release.sh --dry-run only builds the zip.
# Needs `gh`, logged in with push access to this repo and the tap.
set -euo pipefail
cd "$(dirname "$0")"

REPO=jgreen417/cdj400-ui
TAP=jgreen417/homebrew-tap
CASK=packaging/cdj400-sticks.rb
DRY_RUN=0
[[ "${1:-}" == --dry-run ]] && DRY_RUN=1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="dist/CDJ-400-Sticks-$VERSION.zip"

if (( ! DRY_RUN )); then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first."; exit 1; }
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists. Bump the version in Info.plist."; exit 1
  fi
fi

swift test
rm -rf dist && mkdir dist
UNIVERSAL=1 ./build.sh dist
ditto -c -k --keepParent "dist/CDJ-400 Sticks.app" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$ZIP  sha256 $SHA"
(( DRY_RUN )) && exit 0

sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
git commit -q -m "Release $VERSION" -- "$CASK" || true   # unchanged on a re-run
git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "CDJ-400 Sticks $VERSION" --generate-notes

tap_path="Casks/cdj400-sticks.rb"
existing=$(gh api "repos/$TAP/contents/$tap_path" --jq .sha 2>/dev/null || true)
update=()   # replacing a file needs its current blob sha; creating one doesn't
[[ -n "$existing" ]] && update=(-f sha="$existing")
gh api -X PUT "repos/$TAP/contents/$tap_path" \
  -f message="cdj400-sticks $VERSION" \
  -f content="$(base64 -i "$CASK")" \
  "${update[@]}" >/dev/null

echo "Released $TAG."
