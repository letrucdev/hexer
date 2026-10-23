import Foundation
import HexerCore

/// Command-line access to Hexer's core, used to verify features against system tools.
let usage = """
    hexer-cli — Hexer core tools (see Scripts/crosscheck.sh)

    Numbers are decimal or 0x hex. RANGE is START-END (END exclusive), START- or START+LENGTH.
    Errors go to stderr with exit status 1.

      dump [-s OFFSET] [-l LENGTH] [--xxd] FILE
          Hex dump, HxD-style; --xxd prints exactly like xxd.
      find [TYPE] [--backward] [--from N] [--limit N] PATTERN FILE
          Non-overlapping matches, one per line as OFFSET:MATCH (decimal offset; text matches as the
          raw bytes, i.e. LC_ALL=C grep -obUa output; other types as hex bytes). Forward from --from
          (default 0); --backward lists matches before --from (default EOF), last first.
      replace [TYPE] [--range RANGE] PATTERN REPLACEMENT FILE -o OUT
          Replace all (non-overlapping, like find); writes OUT, which may be FILE. Count on stderr.
      checksum [-a ALG[,ALG...]] [--all] [--crc SPEC] [--sum SPEC] [--range RANGE] FILE
          NAME  HEX per algorithm; default CRC-32, MD5, SHA-1, SHA-256; --all for every one of
          Checksum-8/16/32/64, CRC-16, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, MD2, MD4, MD5, SHA-1,
          SHA-256, SHA-384, SHA-512 (names ignore case and punctuation: sha256, crc32c).
          --crc width=W,poly=P[,init=I][,xorout=X][,refin][,refout][,ref]   custom CRC
          --sum result=R[,addend=8|16|32|64][,be]                            custom checksum
      stats [--range RANGE] FILE
          XX COUNT for each byte value, then total N and entropy E (bits per byte).
      diff [--cmp | --backward] [--limit N] A B
          Runs of differing bytes: OFFSET(hex)  LENGTH  A-bytes | B-bytes (--backward: last
          first). --cmp prints exactly like cmp -l (1-based decimal offset, octal bytes;
          "cmp: EOF on X" on stderr). Exit status 0 either way.
      export --format FMT [--range RANGE] [--per-line N] [--lf] FILE [-o OUT]
          FMT: ihex16 ihex20 ihex32 s19 s28 s37 | c pascal csharp java vbnet purebasic |
          editor html rtf tex | hex text. HxD's defaults (CRLF); stdout without -o.
      import [--format ihex|srec|etl] [--fill-gaps BYTE] IN -o OUT
          Record file to binary from address 0; gaps filled with BYTE (default 0).
      disasm --arch x86-16|x86-32|x86-64|arm64 [--offset N] [--length N] [--count N]
             [--base ADDR] [--att] FILE
          ADDRESS  BYTES  TEXT per instruction (Capstone; Intel syntax unless --att).
      edit FILE -o OUT OP...
          Applies OPs in order through the editor's buffer and saves like the app (OUT may be FILE):
          overwrite:OFFSET:HEX (appends past the end), insert:OFFSET:HEX, delete:RANGE,
          fill:RANGE:HEX (pattern repeated), undo, redo. HEX is digit pairs without spaces.
      split (--size N | --preset floppy1200|floppy1440|zip100|zip200|cd650|cd700) [--base PATH] FILE
          Parts of N bytes (K, M, G suffixes) as BASE.001, BASE.002, …; BASE defaults to FILE.
          Prints the part paths.
      concat -o OUT FILE...
          The files one after another; OUT may be one of them.
      disks [list]
          NAME SIZE BLOCK whole|part FLAGS DESCRIPTION per disk and partition; FLAGS from
          internal/external, removable, writable, image, boot, mounted.
      disks read NAME|IMAGE [--range RANGE] [--sector-size N] [-o OUT]
          Raw bytes of a disk (disk4, disk4s1) read in whole sectors, or of a disk image file
          (sector size N, default 512). No administrator prompt: use sudo for protected disks.
      bench [--runs N] FILE
          Best-of-N timings: sequential read, CRC-32, SHA-256, find of DE AD BE EF.
      selftest
          Known-answer and differential checks of this binary's core (e.g. a universal build's
          x86_64 slice under Rosetta: arch -x86_64 hexer-cli selftest).
      help
          This text.

    TYPE (find, replace):
      --text [--case] [--utf16 | --encoding windows-1252|cp437|macintosh|ebcdic-500]
          Default. Case-insensitive unless --case (as in HxD).
      --hex                      PATTERN like "4D 5A 90" or 4D5A90
      --int [--width 8|16|24|32|64] [--be] [--signed|--unsigned]
          Default: every width the value fits, longest match wins; little endian.
      --float [--type single|double|real48|extended] [--be]

    """

let argv = Array(CommandLine.arguments.dropFirst())
let rest = Array(argv.dropFirst())
switch argv.first ?? "help" {
case "dump": dump(rest)
case "find": find(rest)
case "replace": replace(rest)
case "checksum": checksum(rest)
case "stats": stats(rest)
case "diff": diff(rest)
case "export": export(rest)
case "import": importRecords(rest)
case "disasm": disasm(rest)
case "edit": edit(rest)
case "split": splitFile(rest)
case "concat": concatFiles(rest)
case "disks": disks(rest)
case "bench": bench(rest)
case "selftest": selftest(rest)
case "help", "-h", "--help": print(usage, terminator: "")
case let other:
    FileHandle.standardError.write(Data(usage.utf8))
    fail("unknown command \(other)")
}
