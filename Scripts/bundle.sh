#!/bin/sh
# Builds Hexer with SwiftPM and wraps it into a signed .app bundle (no Xcode required).
#
#   Scripts/bundle.sh            release build into build/Hexer.app
#   CONFIG=debug Scripts/bundle.sh
#   UNIVERSAL=1 Scripts/bundle.sh  arm64 + x86_64
#   Scripts/bundle.sh --run [args…]  build, then run in the foreground (logs in the terminal)
#
# SIGN_IDENTITY selects a signing identity. Unset, the build uses the self-signed "Hexer Development"
# certificate when the keychain has one (Scripts/dev_identity.sh creates it), so the app keeps its
# identity, and its permissions, from build to build; without one it is signed ad hoc ("-").
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
# The version: $VERSION when set (the release workflow sets the tag's), else the newest version
# tag in the history, so a local build names the release it contains and the updater compares
# it with GitHub's correctly; Info.plist's placeholder only without tags (a shallow clone).
VERSION=${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')}
[ -n "$VERSION" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
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

DEV_IDENTITY="Hexer Development"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-certificate -c "$DEV_IDENTITY" >/dev/null 2>&1; then SIGN_IDENTITY=$DEV_IDENTITY; else SIGN_IDENTITY=-; fi
fi
case "$SIGN_IDENTITY" in
-|"$DEV_IDENTITY")
    # Ad hoc, or the local certificate: no hardened runtime or timestamp, as for a development build.
    codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/Hexer.entitlements "$APP"
    ;;
*)
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/Hexer.entitlements "$APP"
    ;;
esac
echo "Signed as ${SIGN_IDENTITY}"
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$1" = "--run" ]; then
    shift
    exec "$APP/Contents/MacOS/Hexer" "$@"
fi
