#!/bin/sh
# Vendors the Capstone disassembly engine into Sources/CCapstone, keeping only what the
# X86 and AArch64 back ends need. The result is committed, so building Hexer never needs the
# network; this script exists to reproduce (or update) that tree.
#
#   Scripts/fetch_capstone.sh                       pinned release 5.0.9, sha256 verified
#   CAPSTONE_VERSION=5.0.x CAPSTONE_SHA256=<hex> Scripts/fetch_capstone.sh
#
# The downloaded archive is treated as data: it is extracted into a fresh temporary directory and
# only C sources and headers are copied out. Nothing inside it is executed.
set -eu
cd "$(dirname "$0")/.."

VERSION=${CAPSTONE_VERSION:-5.0.9}
PINNED_VERSION=5.0.9
PINNED_SHA256=0619da31af08152600af95c481527ef6d756c0a8404fca7544a4fdf6dfc2c0f9
if [ "$VERSION" = "$PINNED_VERSION" ]; then
    EXPECTED=${CAPSTONE_SHA256:-$PINNED_SHA256}
else
    EXPECTED=${CAPSTONE_SHA256:-}
fi
URL="https://github.com/capstone-engine/capstone/archive/refs/tags/$VERSION.tar.gz"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/capstone.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
ARCHIVE="$WORK/capstone-$VERSION.tar.gz"

echo "Downloading $URL"
curl -fsSL --proto '=https' --tlsv1.2 -o "$ARCHIVE" "$URL"
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')
echo "sha256 $ACTUAL  capstone-$VERSION.tar.gz"
if [ -n "$EXPECTED" ]; then
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "error: sha256 mismatch, expected $EXPECTED" >&2
        exit 1
    fi
    echo "sha256 verified"
else
    echo "warning: no pinned sha256 for $VERSION; pass CAPSTONE_SHA256 to verify it" >&2
fi

mkdir "$WORK/src"
tar -xzf "$ARCHIVE" -C "$WORK/src"
SRC="$WORK/src/capstone-$VERSION"
if [ ! -f "$SRC/cs.c" ] || [ ! -d "$SRC/arch/X86" ] || [ ! -d "$SRC/arch/AArch64" ]; then
    echo "error: unexpected archive layout" >&2
    exit 1
fi
# cp follows symlinks, so refuse any in the parts that get copied.
LINKS=$(find "$SRC" -maxdepth 1 -type l; find "$SRC/include" "$SRC/arch" -type l)
if [ -n "$LINKS" ]; then
    echo "error: archive contains symbolic links:" >&2
    echo "$LINKS" >&2
    exit 1
fi

DEST=Sources/CCapstone
rm -rf "$DEST"
mkdir -p "$DEST/include/capstone" "$DEST/arch"

# Engine core: cs.c, Mapping.c, MCInst.c, MCInstrDesc.c, MCRegisterInfo.c, SStream.c, utils.c
# and their private headers.
cp "$SRC"/*.c "$SRC"/*.h "$DEST/"
# Public headers. capstone.h includes every architecture's header, so all of them are kept.
cp "$SRC"/include/capstone/*.h "$DEST/include/capstone/"
# The two back ends Hexer uses, including their TableGen-generated .inc tables.
for arch in X86 AArch64; do
    mkdir "$DEST/arch/$arch"
    cp "$SRC/arch/$arch"/*.c "$SRC/arch/$arch"/*.h "$SRC/arch/$arch"/*.inc "$DEST/arch/$arch/"
done
# cs.c includes every architecture's <Arch>Module.h unconditionally; only the declarations are
# needed, the code behind them is compiled out by the CAPSTONE_HAS_<ARCH> defines.
for header in "$SRC"/arch/*/*Module.h; do
    dir=$(basename "$(dirname "$header")")
    mkdir -p "$DEST/arch/$dir"
    cp "$header" "$DEST/arch/$dir/"
done

# Expose only the public API to Swift.
cat > "$DEST/include/module.modulemap" <<'EOF'
module CCapstone {
    header "capstone/capstone.h"
    export *
}
EOF

mkdir -p Resources/Licenses
cp "$SRC/LICENSE.TXT" Resources/Licenses/Capstone-LICENSE.TXT
cp "$SRC/LICENSE_LLVM.TXT" Resources/Licenses/Capstone-LICENSE_LLVM.TXT

echo "Vendored Capstone $VERSION into $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files)"
