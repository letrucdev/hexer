#!/bin/bash
# Takes window screenshots of Hexer in the four variants the project checks for a UI change: light,
# dark, Vietnamese and a narrow window (1024 pt wide). Each variant is a separate launch of
# build/Hexer.app with the flags given, plus -HexerSnapshot (the app captures its own window, never a
# screen region) and -HexerQuit 1.
#
#   Scripts/snapshot.sh NAME [--only light,dark,vi,narrow] [--build] [--] [FILE] [-Hexer… flags…]
#
#   Scripts/snapshot.sh smoke                                    a 4 KB random sample file, four variants
#   Scripts/snapshot.sh find ~/x.bin -HexerFind Hexer -HexerFindType text
#   Scripts/snapshot.sh panel --only dark,vi -HexerHideInspector 1
#
# Writes build/snapshots/NAME-light.png, NAME-dark.png, NAME-vi.png and NAME-narrow.png, and prints
# each path with the HexerWindowMinSize line the app prints. A run still going after
# $SNAPSHOT_TIMEOUT seconds (default 30) is killed. A failed variant does not stop the others; the
# script exits 1 if any failed. --build runs Scripts/bundle.sh first.
#
# Every -Hexer… flag needs a value (e.g. 1): AppKit reads a word without one as a file name. FILE is
# the first argument after the options that does not start with "-"; without it a 4 KB sample is
# made in a temp folder. The variants set their own -HexerAppearance (and vi its own
# -AppleLanguages), so those given here are replaced. narrow replaces a -HexerWindowSize given here
# (the other variants keep it) and hides the inspector: with it shown the window can't be narrower
# than about 1166 pt.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Hexer.app/Contents/MacOS/Hexer"
OUT_DIR="$ROOT/build/snapshots"
LIMIT=${SNAPSHOT_TIMEOUT:-30}

usage() {
    echo "usage: Scripts/snapshot.sh NAME [--only light,dark,vi,narrow] [--build] [--] [FILE] [-Hexer… flags…]" >&2
    echo "Every -Hexer… flag needs a value (e.g. 1). See the top of Scripts/snapshot.sh." >&2
    exit 2
}
fail() {
    echo "error: $*" >&2
    exit 2
}

[ $# -ge 1 ] || usage
NAME=$1
shift
case $NAME in
    ""|-*|*/*) fail "NAME must be a plain name, e.g. smoke" ;;
esac

ONLY="light,dark,vi,narrow"
BUILD=0
while [ $# -gt 0 ]; do
    case $1 in
        --only) [ $# -ge 2 ] || usage; ONLY=$2; shift 2 ;;
        --build) BUILD=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

VARIANTS=""
for w in $(echo "$ONLY" | tr , ' '); do
    case $w in
        light|dark|vi|narrow) ;;
        *) fail "unknown variant '$w' (light, dark, vi, narrow)" ;;
    esac
done
for v in light dark vi narrow; do
    case ",$ONLY," in *",$v,"*) VARIANTS="$VARIANTS $v" ;; esac
done
[ -n "${VARIANTS# }" ] || fail "--only selects no variant"

FILE=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    FILE=$1
    shift
fi
FLAGS=("$@")
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    case ${FLAGS[$i]} in
        -Hexer*)
            if [ $((i + 1)) -ge "$n" ] || [ "${FLAGS[$((i + 1))]#-}" != "${FLAGS[$((i + 1))]}" ]; then
                fail "${FLAGS[$i]} needs a value, e.g. ${FLAGS[$i]} 1"
            fi
            i=$((i + 2)) ;;
        *) i=$((i + 1)) ;;
    esac
done

if [ "$BUILD" = 1 ]; then "$ROOT/Scripts/bundle.sh"; fi
[ -x "$APP" ] || fail "$APP is missing; run Scripts/bundle.sh (or pass --build)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hexer-snapshot.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
if [ -n "$FILE" ]; then
    [ -f "$FILE" ] || fail "no such file: $FILE"
    FILE_ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
else
    FILE_ABS="$TMP/sample.bin"
    head -c 4096 /dev/urandom >"$FILE_ABS"
fi

mkdir -p "$OUT_DIR"

run_variant() {
    local variant=$1
    local out="$OUT_DIR/$NAME-$variant.png"
    local log="$TMP/$variant.log"
    local own=()
    # Flags the variant sets itself are dropped from the caller's list, so the variant's value wins.
    local drop="-HexerSnapshot -HexerQuit -HexerAppearance"
    case $variant in
        light) own=(-HexerAppearance light) ;;
        dark) own=(-HexerAppearance dark) ;;
        vi)
            own=(-HexerAppearance light -AppleLanguages "(vi)")
            drop="$drop -AppleLanguages" ;;
        narrow)
            own=(-HexerAppearance light -HexerWindowSize 1024x700 -HexerHideInspector 1)
            drop="$drop -HexerWindowSize -HexerHideInspector" ;;
    esac

    rm -f "$out"
    local argv=("$APP" "$FILE_ABS" "${own[@]}")
    local i=0
    while [ "$i" -lt "$n" ]; do
        case " $drop " in
            *" ${FLAGS[$i]} "*) i=$((i + 2)) ;;
            *) argv+=("${FLAGS[$i]}"); i=$((i + 1)) ;;
        esac
    done
    argv+=(-HexerSnapshot "$out" -HexerQuit 1)

    "${argv[@]}" >"$log" 2>&1 &
    local pid=$! waited=0 status=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$LIMIT" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        status=124
    else
        wait "$pid" || status=$?
    fi

    local min
    min=$(grep -m1 '^HexerWindowMinSize' "$log" || true)
    if [ "$status" -eq 0 ] && [ -s "$out" ]; then
        printf '%-7s ok      %s\n' "$variant" "$out"
        [ -n "$min" ] && printf '        %s\n' "$min"
        return 0
    fi
    if [ "$status" -eq 124 ]; then
        printf '%-7s FAILED  timed out after %s s\n' "$variant" "$LIMIT"
    elif [ "$status" -eq 0 ]; then
        printf '%-7s FAILED  exited without a screenshot\n' "$variant"
    else
        printf '%-7s FAILED  exit status %s\n' "$variant" "$status"
    fi
    [ -n "$min" ] && printf '        %s\n' "$min"
    tail -n 5 "$log" | sed 's/^/        | /'
    return 1
}

FAILED=0
for v in $VARIANTS; do
    run_variant "$v" || FAILED=$((FAILED + 1))
done

if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED variant(s) failed for $NAME" >&2
    exit 1
fi
echo "all variants ok for $NAME"
