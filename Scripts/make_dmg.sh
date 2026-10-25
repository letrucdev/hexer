#!/bin/sh
# Packages Hexer for other people: build/Hexer-VERSION.dmg with Hexer.app, a link to
# /Applications and the installation guides (Distribution/install-*.html, as RTF for TextEdit).
#
#   Scripts/make_dmg.sh              universal release build (arm64 + x86_64), then the disk image
#   Scripts/make_dmg.sh --no-build   package the existing build/Hexer.app
#
# The app is signed ad hoc unless SIGN_IDENTITY is set (never with the local "Hexer Development"
# certificate bundle.sh picks by itself, which means nothing on other Macs); with a Developer ID
# the disk image is signed too. Without notarization, macOS blocks the first launch; the guides
# say how to allow it.
set -eu
cd "$(dirname "$0")/.."

[ "${1:-}" = "--no-build" ] || SIGN_IDENTITY=${SIGN_IDENTITY:--} UNIVERSAL=1 Scripts/bundle.sh
APP=build/Hexer.app
[ -d "$APP" ] || { echo "no $APP; run without --no-build"; exit 1; }
codesign --verify --strict "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Hexer.app"
ln -s /Applications "$STAGE/Applications"
guide() {
    sed "s/@VERSION@/$VERSION/g" "Distribution/install-$1.html" >"$STAGE/guide.html"
    textutil -convert rtf -output "$STAGE/$2" "$STAGE/guide.html"
    rm "$STAGE/guide.html"
}
guide en "Install Hexer.rtf"
guide vi "Hướng dẫn cài đặt Hexer.rtf"

# The app icon on the mounted volume: .VolumeIcon.icns at its root, and the root's custom-icon
# flag, which `hdiutil create -srcfolder` doesn't copy from the folder. So the image is made
# writable first, the flag set on the mounted volume, then the image compressed.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

DMG="build/Hexer-$VERSION.dmg"
RW="build/Hexer-$VERSION-rw.dmg"
hdiutil create -volname "Hexer $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT=$(mktemp -d)
hdiutil attach "$RW" -readwrite -nobrowse -noautoopen -noverify -mountpoint "$MOUNT" >/dev/null
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW"
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify -quiet "$DMG"
# Launch Services recorded the staged copy of the app; forget it, or Hexer's bundle identifier can
# resolve to this deleted folder and show a blank icon (see LaunchServicesRecords in HexerPlatform).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$STAGE/Hexer.app" 2>/dev/null
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), $(lipo -archs "$APP/Contents/MacOS/Hexer"))"
shasum -a 256 "$DMG"
