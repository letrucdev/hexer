#!/bin/sh
# Builds Hexer with SwiftPM and wraps it into a signed .app bundle (no Xcode required).
#
#   Scripts/bundle.sh            release build into build/Hexer.app
#   CONFIG=debug Scripts/bundle.sh
#   UNIVERSAL=1 Scripts/bundle.sh  arm64 + x86_64
#   Scripts/bundle.sh --run [args…]  build, then run in the foreground (logs in the terminal)
#
# SIGN_IDENTITY selects a signing identity; the default is ad-hoc ("-"), suitable for this Mac.
set -e
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
ARCHS=""
[ -n "$UNIVERSAL" ] && ARCHS="--arch arm64 --arch x86_64"

swift build -c "$CONFIG" $ARCHS --product Hexer
BIN_DIR=$(swift build -c "$CONFIG" $ARCHS --show-bin-path)

APP=build/Hexer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/Hexer"
cp "$BIN_DIR/Hexer" "$BIN"

# SwiftPM records the deployment target as the SDK version, so macOS would run the app in
# compatibility mode without Liquid Glass. Record the SDK that was actually used.
MINOS=$(vtool -show-build "$BIN" | awk '/minos/ { print $2; exit }')
vtool -set-build-version macos "$MINOS" "$(xcrun --show-sdk-version)" -replace -output "$BIN.tmp" "$BIN"
mv "$BIN.tmp" "$BIN"

cp Resources/Info.plist "$APP/Contents/Info.plist"
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Every user-facing string must have a Vietnamese translation.
swift Scripts/l10n_audit.swift

for lproj in Resources/Localization/*.lproj; do
    for f in "$lproj"/*; do plutil -lint -s "$f"; done
    cp -R "$lproj" "$APP/Contents/Resources/"
done
[ -d Resources/Licenses ] && cp -R Resources/Licenses "$APP/Contents/Resources/"

# App icon: rendered by make_icon.swift into an iconset, compiled with iconutil.
if [ ! -d Resources/Icon/AppIcon.iconset ]; then
    swift Scripts/make_icon.swift Resources/Icon/AppIcon.iconset
fi
iconutil -c icns Resources/Icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

SIGN_IDENTITY=${SIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --entitlements Resources/Hexer.entitlements "$APP"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/Hexer.entitlements "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$1" = "--run" ]; then
    shift
    exec "$APP/Contents/MacOS/Hexer" "$@"
fi
