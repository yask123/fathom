#!/bin/zsh
# Release: universal build → Developer ID signature (hardened runtime) → notarize + staple → styled DMG → notarize + staple.
#   FATHOM_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   FATHOM_NOTARY_PROFILE=your-notarytool-profile \
#   scripts/release.sh 0.1.0 1
# The notary profile is one you saved with: xcrun notarytool store-credentials <profile> --apple-id … --team-id …
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:?usage: scripts/release.sh <version> <build>}
BUILD=${2:?usage: scripts/release.sh <version> <build>}
ID=${FATHOM_SIGN_ID:?set FATHOM_SIGN_ID to a "Developer ID Application" identity}
PROFILE=${FATHOM_NOTARY_PROFILE:?set FATHOM_NOTARY_PROFILE to a notarytool keychain profile}
D=dist
rm -rf $D && mkdir -p $D/tmp

echo "→ building $VERSION ($BUILD), arm64 + x86_64"
FATHOM_VERSION=$VERSION FATHOM_BUILD=$BUILD FATHOM_ARCHS="arm64 x86_64" ./build.sh
ditto build/Fathom.app $D/Fathom.app
codesign --force --options runtime --timestamp --sign "$ID" $D/Fathom.app
codesign --verify --strict --deep $D/Fathom.app

echo "→ notarizing the app"
ditto -c -k --keepParent $D/Fathom.app $D/tmp/Fathom.zip
xcrun notarytool submit $D/tmp/Fathom.zip --keychain-profile $PROFILE --wait
xcrun stapler staple $D/Fathom.app

echo "→ building the DMG"
swiftc -O dmg/render.swift -o $D/tmp/render-bg
# A plain 1x PNG: Finder draws a hi-dpi TIFF's 2x rep at pixel size, doubling the art.
$D/tmp/render-bg $D/tmp/bg.png
STAGE=$D/tmp/stage && mkdir -p $STAGE/.background
ditto $D/Fathom.app $STAGE/Fathom.app
ln -s /Applications $STAGE/Applications
cp $D/tmp/bg.png $STAGE/.background/bg.png
hdiutil create -volname Fathom -srcfolder $STAGE -fs HFS+ -format UDRW -ov $D/tmp/rw.dmg >/dev/null
MNT=$(hdiutil attach -readwrite -noverify -noautoopen $D/tmp/rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
sleep 1
osascript <<OSA || echo "  (Finder couldn't lay out the window; the DMG works, just unstyled)"
tell application "Finder"
  tell disk "Fathom"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.png"
    set position of item "Fathom.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
cp $D/Fathom.app/Contents/Resources/Fathom.icns "$MNT/.VolumeIcon.icns" && SetFile -a C "$MNT" 2>/dev/null || true
sync; hdiutil detach "$MNT" >/dev/null
hdiutil convert $D/tmp/rw.dmg -format ULFO -o $D/Fathom-$VERSION.dmg >/dev/null
codesign --force --timestamp --sign "$ID" $D/Fathom-$VERSION.dmg

echo "→ notarizing the DMG"
xcrun notarytool submit $D/Fathom-$VERSION.dmg --keychain-profile $PROFILE --wait
xcrun stapler staple $D/Fathom-$VERSION.dmg
spctl -a -t open --context context:primary-signature -v $D/Fathom-$VERSION.dmg
spctl -a -t exec -v $D/Fathom.app
shasum -a 256 $D/Fathom-$VERSION.dmg
ls -lh $D/Fathom-$VERSION.dmg
