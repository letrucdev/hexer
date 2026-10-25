#!/bin/sh
# Publishes a release to the update server, an S3-compatible bucket (Cloudflare R2): uploads
# build/Hexer-VERSION.dmg, then update.json with this release added to the manifest already on the
# server (downloaded first; none yet starts a new one). The image goes up before the manifest, so
# the manifest never names an image that isn't there. Run after Scripts/sign_update.sh.
#
# The app reads the manifest from the first of HexerUpdateFeedURLs in Resources/Info.plist, and
# the bucket is public at the same address, so the image's public URL is derived from it (set
# UPDATE_PUBLIC_URL to use another). The manifest also lists the GitHub release's copy of the
# image, which the release workflow publishes next, as a second place to download from.
#
#   UPDATE_S3_URL=https://ACCOUNT.r2.cloudflarestorage.com/BUCKET \
#   AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… Scripts/publish_update.sh 0.4.0 build/release-notes.md
set -eu
cd "$(dirname "$0")/.."
VERSION=${1:?usage: $0 VERSION NOTES_FILE}
NOTES=${2:?usage: $0 VERSION NOTES_FILE}
REPO=https://github.com/letrucdev/hexer
DMG="build/Hexer-$VERSION.dmg"
[ -f "$DMG" ] || { echo "error: no $DMG; run Scripts/make_dmg.sh first" >&2; exit 1; }
[ -f "$DMG.sig" ] || { echo "error: no $DMG.sig; run Scripts/sign_update.sh first" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "error: no $NOTES (Scripts/release_notes.sh writes it)" >&2; exit 1; }
for name in UPDATE_S3_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "$(eval "printf %s \"\${$name:-}\"")" ]; then
        echo "error: $name is empty; the update server's address and API token are repository secrets (HANDOFF.md, \"Máy chủ cập nhật\")" >&2
        exit 1
    fi
done
S3_URL=${UPDATE_S3_URL%/}

PUBLIC_URL=${UPDATE_PUBLIC_URL:-$(plutil -extract HexerUpdateFeedURLs.0 raw -o - Resources/Info.plist)}
PUBLIC_URL=${PUBLIC_URL%/update.json}
PUBLIC_URL=${PUBLIC_URL%/}
case "$PUBLIC_URL" in
    https://*) ;;
    *) echo "error: HexerUpdateFeedURLs in Resources/Info.plist must start with the update server's https address" >&2; exit 1 ;;
esac
case "$PUBLIC_URL" in
    *REPLACE*) echo "error: put the update server's public address in HexerUpdateFeedURLs (Resources/Info.plist) first" >&2; exit 1 ;;
esac

# The same configuration as make_dmg.sh's build, so only hexer-cli itself is compiled.
swift build -c release --arch arm64 --arch x86_64 --product hexer-cli >/dev/null
CLI="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/hexer-cli"

PREVIOUS=build/update-previous.json
rm -f "$PREVIOUS"
"$CLI" update download --if-missing-ok "$S3_URL/update.json" -o "$PREVIOUS"
PRERELEASE=""
case "$VERSION" in *-*) PRERELEASE="--prerelease" ;; esac
"$CLI" update manifest --version "$VERSION" --dmg "$DMG" --signature-file "$DMG.sig" \
    --page "$REPO/releases/tag/v$VERSION" --notes-file "$NOTES" \
    --url "$PUBLIC_URL/Hexer-$VERSION.dmg" --url "$REPO/releases/download/v$VERSION/Hexer-$VERSION.dmg" \
    --previous "$PREVIOUS" $PRERELEASE -o build/update.json

# Images never change once published; the manifest does, so it's cached for minutes at most.
"$CLI" update upload --cache-control "public, max-age=31536000, immutable" "$DMG" "$S3_URL/Hexer-$VERSION.dmg"
"$CLI" update upload --cache-control "public, max-age=300" build/update.json "$S3_URL/update.json"

# The bucket must be reachable where the app looks: a wrong public address would only show up as
# every update failing. The image was never served before, so no cache can answer for it.
if ! curl -fsSIL -o /dev/null "$PUBLIC_URL/Hexer-$VERSION.dmg"; then
    echo "error: $PUBLIC_URL/Hexer-$VERSION.dmg is not public; check the bucket's public access and HexerUpdateFeedURLs" >&2
    exit 1
fi
if ! curl -fsSL "$PUBLIC_URL/update.json" | grep -q "\"version\" : \"$VERSION\""; then
    echo "warning: $PUBLIC_URL/update.json doesn't list $VERSION yet (a cache may still hold the previous manifest)" >&2
fi
echo "Published $PUBLIC_URL/update.json ($VERSION)"
