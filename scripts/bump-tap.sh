#!/bin/sh
# Points the Homebrew tap at a published release: updates the version and checksum in
# yask123/homebrew-tap's tracer cask, then pushes.
#
#   scripts/bump-tap.sh 0.9.2
#
# Run it after `gh release create v<version> dist/Tracer.dmg`, so the file it hashes exists.
set -eu
VERSION=${1:?usage: scripts/bump-tap.sh <version>}
TAP=$(brew --repository yask123/tap)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL -o "$TMP/Tracer.dmg" "https://github.com/yask123/fathom/releases/download/v$VERSION/Tracer.dmg"
SHA=$(shasum -a 256 "$TMP/Tracer.dmg" | cut -c1-64)

cd "$TAP"
git pull -q --ff-only
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/tracer.rb
brew style Casks/tracer.rb
git add Casks/tracer.rb
git commit -q -m "tracer $VERSION"
git push -q origin main
echo "Tap updated to Tracer $VERSION. brew upgrade --cask tracer picks it up."
