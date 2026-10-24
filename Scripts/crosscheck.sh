#!/bin/sh
# Cross-checks hexer-cli (and through it HexerCore and HexerDisasm) against standard macOS tools,
# on a copy of HxD64.exe and on random files of 0, 1, 4095, 65537 bytes and 5 MiB.
# Prints PASS/FAIL per check and exits non-zero if any check fails.
#
#   dump --xxd             vs xxd
#   find --text --case     vs LC_ALL=C grep -obUaF   (also -i, --hex offsets and --backward; the 5 MiB
#                          file has matches across the 4 MiB search chunk boundaries)
#   find --int/--float     vs values encoded by perl pack
#   replace                vs perl -0777 -pe 's/\Q…\E/…/g[i]'
#   checksum               vs md5 -q, shasum -a 1/256/384/512, cksum -o 3 (CRC-32), dd | md5 for
#                          --range; CRC catalogue check values and RFC 1319/1320 MD2/MD4 vectors
#   stats                  vs od | awk byte counts
#   diff --cmp             vs cmp -l (stdout and stderr), with patched bytes and length mismatches;
#   diff [--backward]      runs vs consecutive cmp -l offsets (also with thousands of scattered changes)
#   export hex / text / c  vs xxd -p / iconv -f WINDOWS-1252 / xxd -i values
#   export → import        round trips through every Intel Hex / S-Record variant the size allows,
#                          and a ranged export re-imported with --fill-gaps 0xFF
#   disasm                 known x86-64 (Intel and AT&T), x86-32, x86-16 and ARM64 bytes vs expected text;
#                          whole files decode every byte exactly once, across 64 KiB decoding chunks
#   split / concat         vs split -b (size and MD5 of every part) / cat, also with OUT among the inputs
#   edit                   vs the same operations applied by perl, including 300 random ones with undo/redo
#   disks                  names, sizes, sector sizes, whole/partition vs diskutil list/info
#   disks read             a raw image of random bytes attached with hdiutil (never mounted, never
#                          written) vs the image file and dd of /dev/rdiskN, aligned and unaligned
#   update sign / verify   Ed25519 update signatures vs OpenSSL's, both ways (skipped without an
#                          openssl that has Ed25519 and -rawin, such as Homebrew's)
#   selftest               passes
set -u
cd "$(dirname "$0")/.." || exit 1
HXD=/Users/nongdandev/Downloads/HxD/HxD64.exe
export LC_ALL=C

echo "Building hexer-cli (release)..."
if ! swift build -c release --product hexer-cli >/dev/null 2>&1; then
    swift build -c release --product hexer-cli
    exit 1
fi
CLI="$(swift build -c release --show-bin-path)/hexer-cli"

TMP=$(mktemp -d -t hexer-crosscheck) || exit 1
DEV=""
cleanup() {
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
OURS="$TMP/ours"
REF="$TMP/ref"
PASSED=0
FAILED=0

# check NAME COMMAND... — runs COMMAND, which writes $OURS and $REF; passes if it succeeds and they are equal.
check() {
    name=$1
    shift
    rm -f "$OURS" "$REF"
    if "$@" && cmp -s "$OURS" "$REF"; then
        PASSED=$((PASSED + 1))
        echo "PASS $name"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL $name"
        if [ -f "$OURS" ] && [ -f "$REF" ]; then
            cmp "$OURS" "$REF" 2>&1 | sed 's/^/    /'
            diff "$OURS" "$REF" 2>/dev/null | head -6 | sed 's/^/    /'
        fi
    fi
}

size() { wc -c <"$1" | tr -d ' '; }

# our_sum FILE NAME [OPTIONS...]: our value of checksum NAME (HxD's name).
our_sum() {
    file=$1 name=$2
    shift 2
    "$CLI" checksum -a "$name" "$@" "$file" | awk -v n="$name" '$1 == n { print $2 }'
}

dump_xxd() { "$CLI" dump --xxd "$1" >"$OURS" && xxd "$1" >"$REF"; }

# find_text FILE PATTERN [-i]: case-sensitive (or default case-insensitive) text search vs grep.
find_text() {
    if [ "${3:-}" = -i ]; then
        "$CLI" find --text "$2" "$1" >"$OURS" || return 1
        grep -obUaiF -e "$2" "$1" >"$REF"
    else
        "$CLI" find --text --case "$2" "$1" >"$OURS" || return 1
        grep -obUaF -e "$2" "$1" >"$REF"
    fi
    [ $? -le 1 ]
}

# find_hex FILE HEX TEXT: offsets of a hex search vs grep for the same bytes.
find_hex() {
    "$CLI" find --hex "$2" "$1" | cut -d: -f1 >"$OURS" || return 1
    grep -obUaF -e "$3" "$1" | cut -d: -f1 >"$REF"
}

# find_backward FILE PATTERN: backward listing (pattern must not overlap itself) vs grep reversed.
find_backward() {
    "$CLI" find --text --case --backward "$2" "$1" | cut -d: -f1 >"$OURS" || return 1
    grep -obUaF -e "$2" "$1" | cut -d: -f1 | sort -rn >"$REF"
}

# replace_perl FILE PATTERN REPLACEMENT [-i]
replace_perl() {
    if [ "${4:-}" = -i ]; then
        "$CLI" replace --text "$2" "$3" "$1" -o "$OURS" 2>/dev/null || return 1
        P="$2" R="$3" perl -0777 -pe 's/\Q$ENV{P}\E/$ENV{R}/gi' "$1" >"$REF"
    else
        "$CLI" replace --text --case "$2" "$3" "$1" -o "$OURS" 2>/dev/null || return 1
        P="$2" R="$3" perl -0777 -pe 's/\Q$ENV{P}\E/$ENV{R}/g' "$1" >"$REF"
    fi
}

sum_md5() { our_sum "$1" MD5 >"$OURS" && md5 -q "$1" | tr a-f A-F >"$REF"; }
sum_sha() { our_sum "$1" "SHA-$2" >"$OURS" && shasum -a "$2" "$1" | awk '{ print $1 }' | tr a-f A-F >"$REF"; }
sum_crc32() { our_sum "$1" CRC-32 >"$OURS" && printf '%08X\n' "$(cksum -o 3 "$1" | awk '{ print $1 }')" >"$REF"; }

sum_range() {
    our_sum "$1" MD5 --range 1000-3000 >"$OURS" &&
        dd if="$1" bs=1000 skip=1 count=2 2>/dev/null | md5 -q | tr a-f A-F >"$REF"
}

stats_od() {
    "$CLI" stats "$1" | awk '$1 ~ /^[0-9A-F][0-9A-F]$/ && $2 > 0' >"$OURS" || return 1
    od -An -v -tu1 "$1" | awk '{ for (i = 1; i <= NF; i++) c[$i]++ }
        END { for (k in c) printf "%02X %d\n", k, c[k] }' | sort >"$REF"
}

# cmp_l A B: stdout, then stderr, of `diff --cmp` vs `cmp -l`.
cmp_l() {
    "$CLI" diff --cmp "$1" "$2" >"$OURS" 2>"$OURS.err" || return 1
    cmp -l "$1" "$2" >"$REF" 2>"$REF.err"
    cat "$OURS.err" >>"$OURS"
    cat "$REF.err" >>"$REF"
}

# diff_runs A B: `diff` runs (offset, length) vs consecutive `cmp -l` offsets plus the longer file's tail.
diff_runs() {
    "$CLI" diff "$1" "$2" | awk '{ print $1, $2 }' >"$OURS" || return 1
    cmp -l "$1" "$2" 2>/dev/null | awk -v na="$(size "$1")" -v nb="$(size "$2")" '
        function emit() { if (len) printf "%08X %d\n", start, len }
        { o = $1 - 1; if (len && o == start + len) len++; else { emit(); start = o; len = 1 } }
        END {
            common = na < nb ? na : nb; total = na < nb ? nb : na
            if (total > common) { if (len && start + len == common) len += total - common; else { emit(); start = common; len = total - common } }
            emit()
        }' >"$REF"
}

# diff_backward A B: runs listed last first vs the forward listing.
diff_backward() {
    "$CLI" diff --backward "$1" "$2" | sort >"$OURS" || return 1
    "$CLI" diff "$1" "$2" >"$REF"
}

# export_hex FILE: hex values, 16 per line, vs xxd -p.
export_hex() {
    { "$CLI" export --format hex --per-line 16 --lf "$1" && echo; } >"$OURS" || return 1
    xxd -p -u -c 16 "$1" | sed 's/../& /g; s/ $//' >"$REF"
}

# export_text FILE: Windows-1252 decoded text (unassigned bytes as ".") vs iconv.
export_text() {
    "$CLI" export --format text "$1" >"$OURS" || return 1
    tr '\201\215\217\220\235' '.....' <"$1" | iconv -f WINDOWS-1252 -t UTF-8 >"$REF"
}

# export_c FILE: the array elements of the C export vs xxd -i.
export_c() {
    "$CLI" export --format c "$1" | grep -o '0x[0-9A-F][0-9A-F]' >"$OURS" || return 1
    xxd -i <"$1" | grep -o '0x[0-9a-f][0-9a-f]' | tr a-f A-F >"$REF"
}

# round_trip FILE FORMAT IMPORT-FORMAT
round_trip() {
    "$CLI" export --format "$2" "$1" -o "$TMP/records" &&
        "$CLI" import --format "$3" "$TMP/records" -o "$OURS" && cp "$1" "$REF"
}

# gap_fill FILE FORMAT IMPORT-FORMAT: export bytes 1000..<3000, import with 0xFF before them.
gap_fill() {
    "$CLI" export --format "$2" --range 1000-3000 "$1" -o "$TMP/records" &&
        "$CLI" import --format "$3" --fill-gaps 0xFF "$TMP/records" -o "$OURS" || return 1
    { dd if=/dev/zero bs=1000 count=1 | tr '\000' '\377'; dd if="$1" bs=1000 skip=1 count=2; } >"$REF" 2>/dev/null
}

# disasm_known ARCH HEX-BYTES EXPECTED [OPTIONS...]: disassembly of the bytes vs the expected lines.
disasm_known() {
    arch=$1 bytes=$2 expected=$3
    shift 3
    echo "$bytes" | xxd -r -p >"$TMP/code.bin"
    "$CLI" disasm --arch "$arch" "$@" "$TMP/code.bin" | sed 's/   */  /g' >"$OURS" &&
        printf '%s\n' "$expected" >"$REF"
}

# known_crcs: CRC and sum checksums of "123456789" vs the CRC catalogue's check values.
known_crcs() {
    printf '123456789' >"$TMP/check"
    "$CLI" checksum -a checksum8,checksum16,checksum32,checksum64,crc16,crc16ccittfalse,crc32,crc32c \
        --crc width=3,poly=3,xorout=7 --crc width=5,poly=5,init=0x1f,xorout=0x1f,ref --crc width=7,poly=9 \
        --crc width=8,poly=7 --crc width=16,poly=0x8005,init=0xffff,ref --crc width=16,poly=0x1021,init=0x1d0f \
        --crc width=24,poly=0x864cfb,init=0xb704ce --crc width=64,poly=0x42f0e1eba9ea3693 \
        --crc width=64,poly=0x42f0e1eba9ea3693,init=0xffffffffffffffff,xorout=0xffffffffffffffff,ref \
        --sum result=16,addend=16 --sum result=16,addend=16,be "$TMP/check" | sed 's/.*  //' >"$OURS" || return 1
    # Sums 0x1DD; CRC-16/ARC, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, CRC-3/GSM, CRC-5/USB, CRC-7/MMC,
    # CRC-8/SMBUS, CRC-16/MODBUS, CRC-16/SPI-FUJITSU, CRC-24/OPENPGP, CRC-64/ECMA-182, CRC-64/XZ;
    # 16-bit little and big endian addends.
    printf '%s\n' DD 01DD 000001DD 00000000000001DD BB3D 29B1 CBF43926 E3069283 4 19 75 F4 4B37 E5CC 21CF02 \
        6C40DF5F0B497347 995DC9BBDF1939FA D509 09D4 >"$REF"
}

# known_digests: MD2 and MD4 of "message digest" and 80 digits vs RFC 1319 and RFC 1320.
known_digests() {
    printf 'message digest' >"$TMP/md"
    printf '1234567890%.0s' 1 2 3 4 5 6 7 8 >"$TMP/digits"
    { "$CLI" checksum -a md2,md4 "$TMP/md" && "$CLI" checksum -a md2,md4 "$TMP/digits"; } >"$OURS" || return 1
    printf 'MD2  %s\nMD4  %s\n' AB4F496BFB2A530B219FF33031FE06B0 D9130A8164549FE818874806E1C7014B \
        D5976F79D83D3A0DC9806C3C66F3EFD8 E33B4DDC9C38F2199C3E7B164FCC0536 >"$REF"
}

# find_numbers: integer and float searches vs values written by perl pack, as "offset length".
find_numbers() {
    perl -e 'print "xx", pack("v", 258), "yy", pack("n", 258), "z", pack("l<", -2), pack("d<", 3.14),
        pack("f<", 3.14), pack("d>", -0.1), pack("q<", 1000), pack("V", 1000), "w", pack("s>", -300)' >"$TMP/nums"
    {
        "$CLI" find --int 258 --width 16 "$TMP/nums" &&
            "$CLI" find --int 258 --width 16 --be "$TMP/nums" &&
            "$CLI" find --int -2 --width 32 "$TMP/nums" &&
            "$CLI" find --float 3.14 --type double "$TMP/nums" &&
            "$CLI" find --float 3.14 "$TMP/nums" &&
            "$CLI" find --float -0.1 --type double --be "$TMP/nums" &&
            "$CLI" find --int 1000 "$TMP/nums" &&
            "$CLI" find --int -300 --be "$TMP/nums"
    } | awk -F: '{ print $1, (length($2) + 1) / 3 }' >"$OURS" || return 1
    printf '%s\n' "2 2" "6 2" "9 4" "13 8" "21 4" "25 8" "33 8" "41 4" "46 2" >"$REF"
}

# disasm_cover FILE ARCH: instructions (and "(bad)" bytes) are contiguous and end at the file's end.
disasm_cover() {
    "$CLI" disasm --arch "$2" "$1" | awk '
        function hex(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789ABCDEF", substr(s, i, 1)) - 1; return v }
        { a = hex($1); n = 0; for (i = 2; i <= NF && $i ~ /^[0-9A-F][0-9A-F]$/; i++) n++
          if (a != next_ || n == 0) { print "discontinuity at " $0; exit }
          next_ = a + n }
        END { print "end", next_ + 0 }' >"$OURS" || return 1
    echo "end $(size "$1")" >"$REF"
}

# split_parts FILE SIZE [REF-SIZE]: size and MD5 of our parts vs those of split -b (REF-SIZE, default SIZE).
split_parts() {
    d="$TMP/split"
    rm -rf "$d"
    mkdir -p "$d/ours" "$d/ref"
    "$CLI" split --size "$2" --base "$d/ours/part" "$1" >"$d/list" || return 1
    split -b "${3:-$2}" "$1" "$d/ref/part." || return 1
    while read -r part; do echo "$(size "$part") $(md5 -q "$part")"; done <"$d/list" >"$OURS"
    for part in "$d"/ref/part.*; do [ -f "$part" ] && echo "$(size "$part") $(md5 -q "$part")"; done >"$REF"
    # Parts are numbered .001, .002, … in the order listed.
    [ ! -s "$d/list" ] || [ "$(head -1 "$d/list")" = "$d/ours/part.001" ]
}

# concat_cat FILE: FILE, rand4095 and FILE again vs cat; then FILE extended in place.
concat_cat() {
    "$CLI" concat -o "$OURS" "$1" "$TMP/rand4095" "$1" || return 1
    cp "$OURS" "$TMP/inplace"
    "$CLI" concat -o "$TMP/inplace" "$TMP/inplace" "$TMP/rand1" || return 1
    cat "$1" "$TMP/rand4095" "$1" >"$REF"
    cat "$REF" "$TMP/rand1" | cmp -s - "$TMP/inplace"
}

# The edit operations of hexer-cli, applied by perl to a string (undo and redo as state stacks).
EDIT_PL='
my $file = shift;
open my $h, "<:raw", $file or die "$file: $!";
my $d = do { local $/; <$h> } // "";
my (@undo, @redo);
sub num { my $s = shift; $s =~ /^0x/i ? hex($s) : $s }
sub span {
    my $s = shift;
    return (num($1), num($1) + num($2)) if $s =~ /^(.+)\+(.+)$/;
    $s =~ /^(.+)-(.*)$/ or die "range $s";
    return (num($1), $2 eq "" ? length($d) : num($2));
}
for my $op (@ARGV) {
    my @p = split /:/, $op, -1;
    if ($p[0] eq "undo") { push @redo, $d; $d = pop @undo; next }
    if ($p[0] eq "redo") { push @undo, $d; $d = pop @redo; next }
    push @undo, $d;
    @redo = ();
    if ($p[0] eq "overwrite") { my $pat = pack("H*", $p[2]); substr($d, num($p[1]), length $pat) = $pat }
    elsif ($p[0] eq "insert") { substr($d, num($p[1]), 0) = pack("H*", $p[2]) }
    elsif ($p[0] eq "delete") { my ($s, $e) = span($p[1]); substr($d, $s, $e - $s) = "" }
    elsif ($p[0] eq "fill") {
        my ($s, $e) = span($p[1]);
        my $pat = pack("H*", $p[2]);
        substr($d, $s, $e - $s) = substr($pat x ($e - $s), 0, $e - $s);
    }
}
binmode STDOUT;
print $d;
'

# edit_perl FILE OP...: edit vs perl applying the same operations.
edit_perl() {
    file=$1
    shift
    "$CLI" edit "$file" -o "$OURS" "$@" || return 1
    perl -e "$EDIT_PL" "$file" "$@" >"$REF"
}

# random_ops SEED COUNT LIMIT: edit operations at offsets below LIMIT, with valid undos and redos.
random_ops() {
    awk -v seed="$1" -v count="$2" -v limit="$3" 'BEGIN {
        srand(seed); u = 0; r = 0
        for (i = 0; i < count; i++) {
            k = int(rand() * 10); o = int(rand() * limit); n = 1 + int(rand() * 16)
            hex = ""; for (j = 0; j < n; j++) hex = hex sprintf("%02X", int(rand() * 256))
            if (k == 0 && u > 0) { print "undo"; u--; r++; continue }
            if (k == 1 && r > 0) { print "redo"; r--; u++; continue }
            if (k < 4) print "overwrite:" o ":" hex
            else if (k < 6) print "insert:" o ":" hex
            else if (k < 8) printf "delete:%d+%d\n", o, n
            else printf "fill:0x%X+%d:%s\n", o, n * 3, substr(hex, 1, 4)
            u++; r = 0
        }
    }'
}

# disks_diskutil: name, size, sector size and whole/partition of every disk vs diskutil.
disks_diskutil() {
    "$CLI" disks >"$TMP/disks.txt" || return 1
    awk '{ print $1, $2, $3, $4 }' "$TMP/disks.txt" | sort >"$OURS"
    diskutil list -plist >"$TMP/disks.plist" || return 1
    for d in $(plutil -extract AllDisks json -o - "$TMP/disks.plist" | tr -d '[]"' | tr ',' ' '); do
        diskutil info -plist "$d" >"$TMP/disk.plist" || return 1
        whole=part
        [ "$(plutil -extract WholeDisk raw "$TMP/disk.plist")" = true ] && whole=whole
        echo "$d $(plutil -extract Size raw "$TMP/disk.plist") $(plutil -extract DeviceBlockSize raw "$TMP/disk.plist") $whole"
    done | sort >"$REF"
}

# disk_listed NAME: size and "image" flag of the attached 1 MiB image in the list.
disk_listed() {
    "$CLI" disks | awk -v d="$1" '$1 == d { print $2, ($5 ~ /image/) }' >"$OURS"
    echo "1048576 1" >"$REF"
}

# selftest_passes: the last line of selftest (its failures are shown).
selftest_passes() {
    "$CLI" selftest >"$TMP/selftest.txt" || { grep FAIL "$TMP/selftest.txt"; return 1; }
    tail -1 "$TMP/selftest.txt" >"$OURS"
    echo "selftest: all checks passed" >"$REF"
}

# disk_read NAME [OPTIONS...] -- REFERENCE-COMMAND...: disks read vs the command's output.
disk_read() {
    disk=$1
    shift
    opts=""
    while [ "$1" != -- ]; do opts="$opts $1"; shift; done
    shift
    # shellcheck disable=SC2086
    "$CLI" disks read "$disk" $opts -o "$OURS" || return 1
    "$@" >"$REF" 2>/dev/null
}

# update_message FILE VERSION: what an update signature signs (UpdateSignature in HexerCore).
update_message() {
    printf 'hexer-update-v1\n%s\n%s\n' "$2" "$(shasum -a 256 "$1" | cut -d' ' -f1)"
}

# update_openssl_signs FILE VERSION: OpenSSL's signature verifies with hexer-cli; as another version it doesn't.
update_openssl_signs() {
    update_message "$1" "$2" >"$TMP/msg" &&
        "$OPENSSL" pkeyutl -sign -inkey "$TMP/ed.pem" -rawin -in "$TMP/msg" -out "$TMP/sig.bin" &&
        base64 -i "$TMP/sig.bin" >"$TMP/sig" &&
        pub=$("$OPENSSL" pkey -in "$TMP/ed.pem" -pubout -outform DER | tail -c 32 | base64) || return 1
    {
        "$CLI" update verify --public-key "$pub" "$1" "$2" "$TMP/sig"
        "$CLI" update verify --public-key "$pub" "$1" "$2.1" "$TMP/sig" 2>/dev/null || echo rejected
    } >"$OURS"
    printf 'valid\nrejected\n' >"$REF"
}

# update_cli_signs FILE VERSION: hexer-cli's key and signature work with OpenSSL; as another version they don't.
update_cli_signs() {
    rm -f "$TMP/update.key"
    pub=$("$CLI" update keygen "$TMP/update.key") &&
        "$CLI" update sign --key-file "$TMP/update.key" "$1" "$2" | base64 -d >"$TMP/sig.bin" &&
        { printf '302e020100300506032b657004220420' | xxd -r -p; base64 -d <"$TMP/update.key"; } >"$TMP/key.der" &&
        "$OPENSSL" pkey -inform DER -in "$TMP/key.der" -pubout -out "$TMP/pub.pem" || return 1
    {
        "$OPENSSL" pkey -pubin -in "$TMP/pub.pem" -outform DER | tail -c 32 | base64
        update_message "$1" "$2" >"$TMP/msg"
        "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/msg" -sigfile "$TMP/sig.bin" >/dev/null && echo valid
        update_message "$1" "$2.1" >"$TMP/msg"
        "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/msg" -sigfile "$TMP/sig.bin" >/dev/null 2>&1 ||
            echo rejected
    } >"$OURS"
    printf '%s\nvalid\nrejected\n' "$pub" >"$REF"
}

# Inputs: a copy of HxD64.exe and random files.
FILES=""
if [ -f "$HXD" ]; then
    cp "$HXD" "$TMP/HxD64.exe" && FILES="$TMP/HxD64.exe"
else
    echo "note: $HXD not found, skipping it"
fi
for n in 0 1 4095 65537 5242880; do
    if [ "$n" -gt 0 ]; then head -c "$n" /dev/urandom >"$TMP/rand$n"; else : >"$TMP/rand$n"; fi
    FILES="$FILES $TMP/rand$n"
done
# Matches across the 4 MiB chunk boundary (forward) and at 1 MiB (the first backward window's start).
printf 'TForm' | dd of="$TMP/rand5242880" bs=1 seek=4194302 conv=notrunc 2>/dev/null
printf 'Hx' | dd of="$TMP/rand5242880" bs=1 seek=1048575 conv=notrunc 2>/dev/null

for f in $FILES; do
    label=$(basename "$f")
    n=$(size "$f")
    check "dump --xxd vs xxd [$label]" dump_xxd "$f"
    for p in e Hx HxD TForm 'a b'; do
        check "find --text --case '$p' vs grep -obUa [$label]" find_text "$f" "$p"
    done
    for p in E hX; do
        check "find --text '$p' vs grep -obUai [$label]" find_text "$f" "$p" -i
    done
    check "find --hex 48 78 vs grep offsets [$label]" find_hex "$f" "48 78" Hx
    check "find --backward 'Hx' vs grep reversed [$label]" find_backward "$f" Hx
    check "replace 'e' -> '<<>>' vs perl [$label]" replace_perl "$f" e '<<>>'
    check "replace 'Hx' -> '' vs perl [$label]" replace_perl "$f" Hx ''
    check "replace 'hx' -> '\$1' -i vs perl [$label]" replace_perl "$f" hx '$1' -i
    check "checksum MD5 vs md5 [$label]" sum_md5 "$f"
    for bits in 1 256 384 512; do
        check "checksum SHA-$bits vs shasum [$label]" sum_sha "$f" "$bits"
    done
    check "checksum CRC-32 vs cksum -o 3 [$label]" sum_crc32 "$f"
    if [ "$n" -ge 3000 ]; then check "checksum --range 1000-3000 vs dd | md5 [$label]" sum_range "$f"; fi
    check "stats vs od [$label]" stats_od "$f"
    if [ "$n" -gt 0 ]; then
        check "export hex vs xxd -p [$label]" export_hex "$f"
        check "export text vs iconv -f WINDOWS-1252 [$label]" export_text "$f"
        check "export c vs xxd -i values [$label]" export_c "$f"
    fi

    if [ "$n" -lt 1000000 ]; then check "split --size 1000 vs split -b [$label]" split_parts "$f" 1000; fi
    check "split --size 65536 vs split -b [$label]" split_parts "$f" 65536
    if [ "$n" -gt 1000000 ]; then check "split --size 1M vs split -b 1m [$label]" split_parts "$f" 1M 1m; fi
    check "concat vs cat [$label]" concat_cat "$f"
    if [ "$n" -ge 4095 ]; then
        check "edit overwrite/insert/delete/fill/undo/redo vs perl [$label]" edit_perl "$f" \
            overwrite:0:4D5A insert:2:FFFF delete:10+5 fill:100-200:DEAD undo redo insert:0x40:00 \
            overwrite:$((n - 2)):0102030405 delete:$((n - 100))- fill:0x20+7:A1B2C3 undo
        # shellcheck disable=SC2046
        check "edit 300 random operations vs perl [$label]" edit_perl "$f" $(random_ops "$n" 300 $((n - 2000)))
    fi

    # A copy with patched bytes (start, a 4-byte run at a third, middle, end) and a longer one.
    cp "$f" "$TMP/patched"
    for off in 0 $((n / 3)) $((n / 2)) $((n - 1)); do
        [ "$off" -ge 0 ] && [ "$off" -lt "$n" ] || continue
        printf '\252\125\000\377' | dd of="$TMP/patched" bs=1 seek="$off" count=$((n - off < 4 ? n - off : 4)) conv=notrunc 2>/dev/null
    done
    { cat "$f"; printf 'XYZ'; } >"$TMP/longer"
    # Thousands of random single-byte changes (some adjacent, some unchanged values).
    perl -0777 -pe 'srand(42); my $n = length; if ($n) { for my $i (1 .. 3000) { substr($_, int(rand($n)), 1) = chr(int(rand(256))) } }' \
        "$f" >"$TMP/scattered"
    check "diff --cmp vs cmp -l, identical [$label]" cmp_l "$f" "$f"
    check "diff --cmp vs cmp -l, patched [$label]" cmp_l "$f" "$TMP/patched"
    check "diff --cmp vs cmp -l, longer B [$label]" cmp_l "$f" "$TMP/longer"
    check "diff --cmp vs cmp -l, shorter B [$label]" cmp_l "$TMP/longer" "$TMP/patched"
    check "diff runs vs cmp -l, patched [$label]" diff_runs "$f" "$TMP/patched"
    check "diff runs vs cmp -l, longer B [$label]" diff_runs "$TMP/patched" "$TMP/longer"
    check "diff --cmp vs cmp -l, scattered [$label]" cmp_l "$f" "$TMP/scattered"
    check "diff runs vs cmp -l, scattered [$label]" diff_runs "$TMP/scattered" "$TMP/longer"
    check "diff --backward vs diff, scattered [$label]" diff_backward "$TMP/scattered" "$TMP/longer"
    check "diff --backward vs diff, longer A [$label]" diff_backward "$TMP/longer" "$TMP/patched"

    check "export ihex32 -> import round trip [$label]" round_trip "$f" ihex32 ihex
    check "export s37 -> import round trip [$label]" round_trip "$f" s37 srec
    if [ "$n" -le 16777216 ]; then check "export s28 -> import round trip [$label]" round_trip "$f" s28 srec; fi
    if [ "$n" -le 1048576 ]; then check "export ihex20 -> import round trip [$label]" round_trip "$f" ihex20 ihex; fi
    if [ "$n" -le 65536 ]; then
        check "export ihex16 -> import round trip [$label]" round_trip "$f" ihex16 ihex
        check "export s19 -> import round trip [$label]" round_trip "$f" s19 srec
    fi
    if [ "$n" -ge 3000 ]; then
        check "export ihex32 --range 1000-3000 -> import --fill-gaps 0xFF [$label]" gap_fill "$f" ihex32 ihex
        check "export s37 --range 1000-3000 -> import --fill-gaps 0xFF [$label]" gap_fill "$f" s37 srec
    fi
done

check "checksum of '123456789' vs CRC catalogue check values" known_crcs
check "checksum MD2/MD4 vs RFC 1319/1320 vectors" known_digests
check "find --int/--float vs perl pack" find_numbers

X64="55 48 89 E5 48 83 EC 20 48 8B 05 F9 0F 00 00 E8 00 00 00 00 31 C0 C9 C3"
check "disasm x86-64 known bytes" disasm_known x86-64 "$X64" "00000000  55  push rbp
00000001  48 89 E5  mov rbp, rsp
00000004  48 83 EC 20  sub rsp, 0x20
00000008  48 8B 05 F9 0F 00 00  mov rax, qword ptr [rip + 0xff9]
0000000F  E8 00 00 00 00  call 0x14
00000014  31 C0  xor eax, eax
00000016  C9  leave
00000017  C3  ret"
check "disasm x86-64 --att known bytes" disasm_known x86-64 "$X64" "00401000  55  pushq %rbp
00401001  48 89 E5  movq %rsp, %rbp
00401004  48 83 EC 20  subq \$0x20, %rsp
00401008  48 8B 05 F9 0F 00 00  movq 0xff9(%rip), %rax
0040100F  E8 00 00 00 00  callq 0x401014
00401014  31 C0  xorl %eax, %eax
00401016  C9  leave
00401017  C3  retq" --att --base 0x401000
check "disasm x86-32 known bytes" disasm_known x86-32 "8B 44 24 04 03 44 24 08 C3" "00000000  8B 44 24 04  mov eax, dword ptr [esp + 4]
00000004  03 44 24 08  add eax, dword ptr [esp + 8]
00000008  C3  ret"
check "disasm x86-16 known bytes" disasm_known x86-16 "B4 09 BA 34 12 CD 21" "00000100  B4 09  mov ah, 9
00000102  BA 34 12  mov dx, 0x1234
00000105  CD 21  int 0x21" --base 0x100
check "disasm arm64 known bytes" disasm_known arm64 "FD 7B BF A9 FD 03 00 91 00 00 80 52 FD 7B C1 A8 C0 03 5F D6" "00000000  FD 7B BF A9  stp x29, x30, [sp, #-0x10]!
00000004  FD 03 00 91  mov x29, sp
00000008  00 00 80 52  mov w0, #0
0000000C  FD 7B C1 A8  ldp x29, x30, [sp], #0x10
00000010  C0 03 5F D6  ret"
if [ -f "$TMP/HxD64.exe" ]; then check "disasm x86-64 covers HxD64.exe" disasm_cover "$TMP/HxD64.exe" x86-64; fi
check "disasm x86-16 covers rand5242880" disasm_cover "$TMP/rand5242880" x86-16
check "disasm arm64 covers rand65537" disasm_cover "$TMP/rand65537" arm64
check "disasm --offset/--count and undecodable bytes" disasm_known x86-64 "90 90 FF FF C3 90" "00000002  FF  (bad)
00000003  FF C3  inc ebx" --offset 2 --count 2

# Disks: the list against diskutil, then raw reads of an attached image of random bytes.
check "disks vs diskutil list/info" disks_diskutil
head -c 1048576 /dev/urandom >"$TMP/raw.img"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount -noverify -noautofsck "$TMP/raw.img" 2>/dev/null |
    awk 'NR == 1 { sub("/dev/", "", $1); print $1 }')
if [ -n "$DEV" ]; then
    check "disks lists the attached image [$DEV]" disk_listed "$DEV"
    check "disks read whole image vs the file [$DEV]" disk_read "$DEV" -- cat "$TMP/raw.img"
    check "disks read whole image vs dd of the device [$DEV]" disk_read "$DEV" -- dd if="/dev/r$DEV" bs=512
    check "disks read --range 1000+70000 (unaligned) vs dd [$DEV]" disk_read "$DEV" --range 1000+70000 -- \
        dd if="$TMP/raw.img" bs=1000 skip=1 count=70
    check "disks read --range 1048000- (last sectors) vs tail [$DEV]" disk_read "$DEV" --range 1048000- -- tail -c 576 "$TMP/raw.img"
    check "disks read of an image file --range 513+1000 vs dd" disk_read "$TMP/raw.img" --range 513+1000 -- \
        dd if="$TMP/raw.img" bs=1 skip=513 count=1000
else
    echo "note: hdiutil could not attach a raw image, skipping disks read"
fi

# Update signatures, with the first openssl that has Ed25519 and -rawin (macOS's LibreSSL 3.3 lacks them).
OPENSSL=""
for candidate in openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" genpkey -algorithm ed25519 -out "$TMP/ed.pem" >/dev/null 2>&1 &&
        printf x >"$TMP/msg" && "$candidate" pkeyutl -sign -inkey "$TMP/ed.pem" -rawin -in "$TMP/msg" >/dev/null 2>&1; then
        OPENSSL=$candidate
        break
    fi
done
if [ -n "$OPENSSL" ]; then
    for f in rand0 rand65537 rand5242880; do
        check "update verify of an OpenSSL Ed25519 signature [$f]" update_openssl_signs "$TMP/$f" 0.3.0-beta.1
        check "update keygen/sign vs OpenSSL Ed25519 [$f]" update_cli_signs "$TMP/$f" 1.0.0
    done
else
    echo "note: no openssl with Ed25519 and -rawin, skipping update signatures"
fi

check "selftest passes" selftest_passes

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
