#!/bin/sh
# Signs build/Hexer-VERSION.dmg for Hexer's updater: writes build/Hexer-VERSION.dmg.sig with the
# Ed25519 private key in $HEXER_UPDATE_KEY (the repository secret of the same name), then checks the
# signature against the public key in build/Hexer.app's Info.plist. A key that doesn't match the app
# fails here, before the release goes out, instead of every update failing later.
#
#   HEXER_UPDATE_KEY=… Scripts/sign_update.sh 0.3.0     (after Scripts/make_dmg.sh)
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: $0 VERSION}
DMG="build/Hexer-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: no $DMG; run Scripts/make_dmg.sh first" >&2; exit 1; }
if [ -z "${HEXER_UPDATE_KEY:-}" ]; then
    echo "error: HEXER_UPDATE_KEY is empty; add the update signing key as a repository secret (HANDOFF.md, \"Khoá ký bản cập nhật\")" >&2
    exit 1
fi

# The same configuration as make_dmg.sh's build, so only hexer-cli itself is compiled.
swift build -c release --arch arm64 --arch x86_64 --product hexer-cli >/dev/null
CLI="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/hexer-cli"
"$CLI" update sign "$DMG" "$VERSION" >"$DMG.sig"
if ! "$CLI" update verify --app build/Hexer.app "$DMG" "$VERSION" "$DMG.sig" >/dev/null; then
    echo "error: HEXER_UPDATE_KEY doesn't match HexerUpdatePublicKey in Resources/Info.plist" >&2
    exit 1
fi
echo "Signed $DMG"
