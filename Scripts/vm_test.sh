#!/bin/sh
# Tests the current build on a macOS virtual machine in UTM (for example macOS 15), over SSH.
#
#   Scripts/vm_test.sh deploy                          copy build/Hexer.app, hexer-cli and samples
#   Scripts/vm_test.sh selftest                        run hexer-cli selftest in the VM
#   Scripts/vm_test.sh shot NAME [SECONDS] -- ARGS...  launch Hexer in the VM with ARGS, wait, and
#                                                      capture UTM's window to build/vm/shots/NAME.png
#   Scripts/vm_test.sh ssh [COMMAND]                   run a command in the VM
#
# In ARGS, $P is the samples folder in the VM: Hexer (the app binary), Hexer-b (3 bytes changed at
# 0x1000) and firmware.hex (Intel Hex with gaps). Example:
#   Scripts/vm_test.sh shot find 4 -- '$P/Hexer -HexerAppearance dark -HexerFind Hexer -HexerFindType text'
#
# Screenshots are taken of UTM's window on this Mac (window capture only), so the VM needs no
# Screen Recording permission. Hexer's -Hexer… flags work as on this Mac.
#
# Settings come from the environment or build/vm/config (sh syntax):
#   VM_HOST   the VM's address (UTM shows it; `utmctl ip-address NAME` prints it)
#   VM_USER   the account in the VM
#   VM_KEY    SSH private key, default ~/.ssh/id_ed25519
#   VM_NAME   the VM's name in UTM, default macOS_15
# Once, in the VM: System Settings ▸ General ▸ Sharing ▸ Remote Login on, and the public key of
# VM_KEY appended to ~/.ssh/authorized_keys.
set -eu
cd "$(dirname "$0")/.."
VMDIR=build/vm
mkdir -p "$VMDIR/shots"
[ -f "$VMDIR/config" ] && . "$VMDIR/config"
VM_KEY=${VM_KEY:-$HOME/.ssh/id_ed25519}
VM_NAME=${VM_NAME:-macOS_15}
: "${VM_HOST:?set VM_HOST (and VM_USER) in the environment or build/vm/config}"
: "${VM_USER:?set VM_USER in the environment or build/vm/config}"
REMOTE='~/HexerTest'

vm() {
    ssh -i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VMDIR/known_hosts" "$VM_USER@$VM_HOST" "$@"
}

# The window number of UTM's window for the VM.
utm_window() {
    cat >"$VMDIR/utm_window.swift" <<'EOF'
import CoreGraphics
let name = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerName as String] as? String) == "UTM" && (w[kCGWindowName as String] as? String) == name {
    print(w[kCGWindowNumber as String]!)
    break
}
EOF
    swift "$VMDIR/utm_window.swift" "$VM_NAME" 2>/dev/null
}

case "${1:-}" in
deploy)
    [ -d build/Hexer.app ] || { echo "build the app first: Scripts/bundle.sh"; exit 1; }
    swift build -c release --product hexer-cli 2>&1 | grep -E "error:" || true
    CLI="$(swift build -c release --show-bin-path)/hexer-cli"
    P="$VMDIR/payload"
    rm -rf "$P" && mkdir -p "$P"
    cp "$CLI" "$P/hexer-cli"
    cp build/Hexer.app/Contents/MacOS/Hexer "$P/Hexer"
    cp "$P/Hexer" "$P/Hexer-b"
    printf '\252\273\314' | dd of="$P/Hexer-b" bs=1 seek=4096 conv=notrunc 2>/dev/null
    # Intel Hex of four parts of the binary, with undefined gaps between them.
    for range in 0+0xE4 0x805+0x80 0x4000+0x100 0x9000+0x40; do
        "$CLI" export --format ihex16 --range "$range" --lf "$P/Hexer" | grep -v '^:00000001FF'
    done >"$P/firmware.hex"
    echo ':00000001FF' >>"$P/firmware.hex"
    tar -C build -cf - Hexer.app -C vm payload |
        vm "rm -rf $REMOTE && mkdir -p $REMOTE && tar -C $REMOTE -xf - && sw_vers -productVersion"
    echo "deployed to $VM_USER@$VM_HOST:$REMOTE"
    ;;
selftest)
    vm "$REMOTE/payload/hexer-cli selftest"
    ;;
shot)
    [ $# -ge 2 ] || { echo "usage: $0 shot NAME [SECONDS] -- ARGS..."; exit 1; }
    name=$2
    shift 2
    wait=3
    if [ "${1:-}" != "--" ]; then wait=${1:-3}; shift; fi
    [ "${1:-}" = "--" ] && shift
    vm "pkill -x Hexer; sleep 0.5; P=$REMOTE/payload; cd \$P; open -n $REMOTE/Hexer.app --args -ApplePersistenceIgnoreState YES $*"
    sleep "$wait"
    id=$(utm_window)
    [ -n "$id" ] || { echo "UTM's window \"$VM_NAME\" is not on screen"; exit 1; }
    screencapture -x -o -l "$id" "$VMDIR/shots/$name.png"
    echo "captured $VMDIR/shots/$name.png"
    ;;
ssh)
    shift
    vm "$@"
    ;;
*)
    sed -n '2,32p' "$0"
    exit 1
    ;;
esac
