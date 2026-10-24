#!/bin/sh
# Tests the current build on a macOS virtual machine in UTM (for example macOS 15), over SSH.
#
#   Scripts/vm_test.sh start                           start the VM in UTM and wait for SSH
#   Scripts/vm_test.sh deploy                          copy build/Hexer.app, hexer-cli, samples and vm_agent
#   Scripts/vm_test.sh selftest                        run hexer-cli selftest in the VM
#   Scripts/vm_test.sh shot NAME [SECONDS] -- ARGS...  launch Hexer in the VM with ARGS, wait, and capture
#                                                      its window to build/vm/shots/NAME.png
#   Scripts/vm_test.sh capture NAME [WINDOW]           capture Hexer's frontmost window (or WINDOW, by title) now
#   Scripts/vm_test.sh burst NAME FRAMES KEY...        press KEYs and capture FRAMES frames as they animate,
#                                                      to NAME-01.png…
#   Scripts/vm_test.sh keys KEY...                     press keys in Hexer: left, return, escape, cmd+o…
#   Scripts/vm_test.sh press TITLE                     press a button by its title or accessibility label
#   Scripts/vm_test.sh menu MENU ITEM                  choose a menu item, e.g. menu Help "Welcome to Hexer"
#   Scripts/vm_test.sh close TITLE                     click the close button of the window with this title
#   Scripts/vm_test.sh ax windows|tree [TITLE]|frame [TITLE]
#                                                      list Hexer's windows, print an accessibility tree
#   Scripts/vm_test.sh ssh [COMMAND]                   run a command in the VM
#
# In ARGS, $P is the samples folder in the VM: Hexer (the app binary), Hexer-b (3 bytes changed at
# 0x1000) and firmware.hex (Intel Hex with gaps). Example:
#   Scripts/vm_test.sh shot find 4 -- '$P/Hexer -HexerAppearance dark -HexerFind Hexer -HexerFindType text'
#
# Screenshots are taken of UTM's window on this Mac (window capture only), so the VM needs no
# Screen Recording permission, then cropped to Hexer's window; Hexer's -Hexer… flags work as on this
# Mac. Keys, buttons and menus go through Scripts/vm_agent.swift in the VM, without this Mac's
# keyboard or mouse; it needs the Accessibility permission there (see that file).
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
AGENT="$REMOTE/payload/vm_agent"
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl

vm() {
    ssh -i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VMDIR/known_hosts" "$VM_USER@$VM_HOST" "$@"
}

# The arguments, quoted for the VM's shell.
quote() {
    for a in "$@"; do
        a=$(printf '%s' "$a" | sed "s/'/'\\\\''/g")
        printf "'%s' " "$a"
    done
}

agent() {
    vm "$AGENT $(quote "$@")"
}

# The window number of UTM's window for the VM.
utm_window() {
    [ -x "$VMDIR/utm_window" ] && [ "$VMDIR/utm_window" -nt "$0" ] || {
        cat >"$VMDIR/utm_window.swift" <<'EOF'
import CoreGraphics
let name = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerName as String] as? String) == "UTM" && (w[kCGWindowName as String] as? String) == name {
    print(w[kCGWindowNumber as String]!)
    break
}
EOF
        swiftc -O -o "$VMDIR/utm_window" "$VMDIR/utm_window.swift" 2>/dev/null
    }
    id=$("$VMDIR/utm_window" "$VM_NAME")
    [ -n "$id" ] || { echo "UTM's window \"$VM_NAME\" is not on screen" >&2; exit 1; }
    echo "$id"
}

# The crop of Hexer's window (or of the window titled $1) in a capture of UTM's window, for sips:
# "height width offsetY offsetX". UTM shows the VM's display under its toolbar, filling the width of
# its window at whatever size that window has. Empty when Hexer shows no window.
crop_of() {
    frame=$(agent frame ${1:+"$1"} 2>/dev/null) || return 0
    echo "$(agent screen) $frame"
}

# Writes the capture $1 of UTM's window to $2, cropped by `crop_of` output $3 (or whole without it).
crop() {
    [ -s "$1" ] || { echo "no capture of UTM's window (does Terminal have Screen Recording permission?)" >&2; exit 1; }
    if [ -z "$3" ]; then mv "$1" "$2"; return; fi
    cw=$(sips -g pixelWidth "$1" | awk '/pixelWidth/ {print $2}')
    ch=$(sips -g pixelHeight "$1" | awk '/pixelHeight/ {print $2}')
    set -- "$1" "$2" $(echo "$3" | awk -v cw="$cw" -v ch="$ch" '{ s = cw / $1; top = ch - $2 * s;
        printf "%d %d %d %d", $6 * s, $5 * s, top + $4 * s, $3 * s }')
    sips -c "$3" "$4" --cropOffset "$5" "$6" "$1" --out "$2" >/dev/null
    rm -f "$1"
}

capture() {
    name=$1
    region=$(crop_of ${2:+"$2"})
    screencapture -x -o -l "$(utm_window)" "$VMDIR/utm-$name.png"
    crop "$VMDIR/utm-$name.png" "$VMDIR/shots/$name.png" "$region"
    echo "captured $VMDIR/shots/$name.png${region:+, cropped to the Hexer window}"
}

case "${1:-}" in
start)
    [ "$("$UTMCTL" status "$VM_NAME")" = started ] || "$UTMCTL" start "$VM_NAME"
    for _ in $(seq 60); do
        vm true 2>/dev/null && { vm sw_vers -productVersion; exit 0; }
        sleep 2
    done
    echo "no SSH at $VM_USER@$VM_HOST after 2 minutes"
    exit 1
    ;;
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
    swiftc -O -target arm64-apple-macos15 -o "$P/vm_agent" Scripts/vm_agent.swift 2>&1 | grep -E "error:" || true
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
    capture "$name"
    ;;
capture)
    [ $# -ge 2 ] || { echo "usage: $0 capture NAME [WINDOW]"; exit 1; }
    capture "$2" ${3:+"$3"}
    ;;
burst)
    [ $# -ge 4 ] || { echo "usage: $0 burst NAME FRAMES KEY..."; exit 1; }
    name=$2 frames=$3
    shift 3
    # Measured first: the window stays put while its contents animate.
    region=$(crop_of)
    id=$(utm_window)
    agent keys "$@" &
    i=1
    while [ "$i" -le "$frames" ]; do
        screencapture -x -o -l "$id" "$VMDIR/utm-$name-$i.png"
        i=$((i + 1))
    done
    wait
    i=1
    while [ "$i" -le "$frames" ]; do
        crop "$VMDIR/utm-$name-$i.png" "$VMDIR/shots/$name-$(printf %02d "$i").png" "$region"
        i=$((i + 1))
    done
    echo "captured $frames frames to $VMDIR/shots/$name-NN.png"
    ;;
keys | press | menu | close)
    agent "$@"
    ;;
ax)
    shift
    agent "$@"
    ;;
ssh)
    shift
    vm "$@"
    ;;
*)
    sed -n '2,35p' "$0"
    exit 1
    ;;
esac
