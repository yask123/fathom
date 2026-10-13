#!/bin/zsh
# Build Fathom.app.
#   ./build.sh            build into build/
#   ./build.sh --run      build, then open build/Fathom.app
#   ./build.sh --install  build, install to /Applications and (re)launch
#
# Optional:
#   FATHOM_SIGN_ID   codesign identity (default: ad-hoc, which is fine on your own Mac)
#   FATHOM_ARCHS     "arm64" (default) or "arm64 x86_64" for a universal app
#   FATHOM_VERSION / FATHOM_BUILD   version strings (scripts/release.sh sets these)
set -euo pipefail
cd "${0:A:h}"

VERSION=${FATHOM_VERSION:-0.1.0}
BUILD=${FATHOM_BUILD:-1}
ARCHS=(${=FATHOM_ARCHS:-arm64})
SIGN_ID=${FATHOM_SIGN_ID:--}
MIN_MACOS=26.0

APP=build/Fathom.app
rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources} build/tmp

slices=()
for arch in $ARCHS; do
  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos$MIN_MACOS Sources/*.swift -o build/tmp/Fathom-$arch
  slices+=build/tmp/Fathom-$arch
done
lipo -create $slices -output $APP/Contents/MacOS/Fathom

if [[ ! -f build/icon/Fathom.icns || icon/render.swift -nt build/icon/Fathom.icns ]]; then
  mkdir -p build/icon/Fathom.iconset
  swiftc -O icon/render.swift -o build/tmp/render-icon
  build/tmp/render-icon build/icon/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon/icon.png --out build/icon/Fathom.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon/icon.png --out build/icon/Fathom.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon/Fathom.iconset -o build/icon/Fathom.icns
fi
cp build/icon/Fathom.icns $APP/Contents/Resources/

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.yask.fathom</string>
  <key>CFBundleName</key><string>Fathom</string>
  <key>CFBundleDisplayName</key><string>Fathom</string>
  <key>CFBundleExecutable</key><string>Fathom</string>
  <key>CFBundleIconFile</key><string>Fathom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Yask Srivastava. MIT License.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Fathom pull request link</string>
    <key>CFBundleURLSchemes</key><array><string>fathom</string></array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --sign "$SIGN_ID" --identifier com.yask.fathom $APP

case "${1:-}" in
  --run)
    pkill -x Fathom 2>/dev/null && sleep 0.5 || true
    open $APP
    ;;
  --install)
    pkill -x Fathom 2>/dev/null && sleep 0.5 || true
    rm -rf /Applications/Fathom.app && cp -R $APP /Applications/Fathom.app
    open /Applications/Fathom.app
    echo "Fathom installed and running."
    ;;
esac
