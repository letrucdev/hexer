import Foundation
import HexerCore

/// The parsed arguments of one subcommand: the options it declares, everything else positional.
///
/// `--name=value` works as well as `--name value`; `--` ends the options. An argument that looks
/// like a negative number (`-5`, `-0x10`, `-inf`) and is not a declared option is positional, so
/// integer and float patterns need no `--`.
struct Arguments {
    let command: String
    private(set) var flags: Set<String> = []
    private(set) var values: [String: [String]] = [:]
    private(set) var positional: [String] = []

    /// `flags` take no value, `options` take one.
    init(_ args: some Sequence<String>, command: String, flags: Set<String> = [], options: Set<String> = []) {
        self.command = command
        var it = args.makeIterator()
        var optionsEnded = false
        while let arg = it.next() {
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            var name = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            if flags.contains(name) && inline == nil {
                self.flags.insert(name)
            } else if options.contains(name) {
                guard let v = inline ?? it.next() else { fail("\(command): \(name) needs a value") }
                values[name, default: []].append(v)
            } else if Self.looksNumeric(arg) {
                positional.append(arg)
            } else {
                fail("\(command): unknown option \(arg) (see hexer-cli help)")
            }
        }
    }

    private static func looksNumeric(_ s: String) -> Bool {
        let rest = s.dropFirst()
        return rest.first?.isNumber == true || rest.first == "." || ["inf", "infinity", "nan"].contains(rest.lowercased())
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    /// The last value given for `name`.
    func value(_ name: String) -> String? { values[name]?.last }

    func allValues(_ name: String) -> [String] { values[name] ?? [] }

    func number(_ name: String) -> UInt64? { value(name).map { parseNumber($0, name) } }

    /// The positional arguments, failing with `usage` unless there are `count` of them.
    func expect(_ count: Int, usage: String) -> [String] {
        guard positional.count == count else { fail("usage: hexer-cli \(usage)") }
        return positional
    }
}

/// Decimal, or hex with a `0x` prefix.
func parseNumber(_ s: String, _ what: String) -> UInt64 {
    let v = s.lowercased().hasPrefix("0x") ? NumberBase.hexadecimal.parse(s) : NumberBase.decimal.parse(s)
    guard let v else { fail("invalid number for \(what): \(s)") }
    return v
}

/// `START-END` (END exclusive), `START-` (to the end) or `START+LENGTH`, clamped to `length`.
func parseRange(_ s: String?, length: UInt64) -> Range<UInt64> {
    guard let s else { return 0..<length }
    let lower: UInt64, upper: UInt64
    if let plus = s.firstIndex(of: "+") {
        lower = parseNumber(String(s[..<plus]), "--range")
        let (sum, overflow) = lower.addingReportingOverflow(parseNumber(String(s[s.index(after: plus)...]), "--range"))
        upper = overflow ? .max : sum
    } else if let dash = s.firstIndex(of: "-") {
        lower = parseNumber(String(s[..<dash]), "--range")
        let rest = s[s.index(after: dash)...]
        upper = rest.isEmpty ? length : parseNumber(String(rest), "--range")
    } else {
        fail("invalid --range \(s) (use START-END, START- or START+LENGTH)")
    }
    guard lower <= upper else { fail("invalid --range \(s): start after end") }
    return min(lower, length)..<min(upper, length)
}

/// Temporary files to remove if the process fails before renaming them into place.
nonisolated(unsafe) private var pendingTemporaryFiles: Set<String> = []

func fail(_ message: String) -> Never {
    for path in pendingTemporaryFiles { unlink(path) }
    FileHandle.standardError.write(Data(("hexer-cli: " + message + "\n").utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A readable message for errors of the core library and the file system.
func describe(_ error: any Error) -> String {
    switch error {
    case ByteSourceError.openFailed(let path, let code): "cannot open \(path): \(String(cString: strerror(code)))"
    case ByteSourceError.unreadable(let offset, let code): "read error at \(offset): \(String(cString: strerror(code)))"
    case FileWriter.WriteError.cannotCreate(let path, let code): "cannot create \(path): \(String(cString: strerror(code)))"
    case FileWriter.WriteError.writeFailed(let path, let code): "cannot write \(path): \(String(cString: strerror(code)))"
    case let e as LocalizedError where e.errorDescription != nil: e.errorDescription!
    default: "\(error)"
    }
}

/// Runs `body`, failing with the command name and the error's description.
func attempt<T>(_ command: String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        fail("\(command): \(describe(error))")
    }
}

func openBuffer(_ path: String) -> EditableBuffer {
    do {
        return EditableBuffer(source: try FileByteSource(url: URL(fileURLWithPath: path)))
    } catch {
        fail(describe(error))
    }
}

func openSnapshot(_ path: String) -> ByteSnapshot { openBuffer(path).snapshot() }

/// Whether `path` exists and is not a regular file (e.g. `/dev/null` or a FIFO); such outputs are
/// written directly.
func isSpecialFile(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && st.st_mode & S_IFMT != S_IFREG
}

/// Lets `body` create the file at a temporary path next to `path`, then renames it into place, so
/// an output may replace one of the inputs. Special files are written directly.
func writeReplacing(_ path: String, _ body: (String) throws -> Void) rethrows {
    if isSpecialFile(path) { return try body(path) }
    let temp = path + ".hexer-\(getpid()).tmp"
    pendingTemporaryFiles.insert(temp)
    do {
        try body(temp)
    } catch {
        unlink(temp)
        pendingTemporaryFiles.remove(temp)
        throw error
    }
    guard rename(temp, path) == 0 else { fail("cannot create \(path): \(String(cString: strerror(errno)))") }
    pendingTemporaryFiles.remove(temp)
}

/// Writes `snapshot` (or `range` of it) to `path` with `FileWriter`.
func writeSnapshot(_ snapshot: ByteSnapshot, range: Range<UInt64>? = nil, to path: String, command: String) {
    attempt(command) {
        try writeReplacing(path) { temp in
            try FileWriter.write(snapshot, range: range, to: URL(fileURLWithPath: temp))
        }
    }
}

/// Buffered output to standard output, or to a new file that replaces `path` when closed.
final class Output {
    private let fd: Int32
    private let path: String?
    private let temp: String?
    private var buffer: [UInt8] = []

    /// Standard output.
    init() {
        fd = 1
        path = nil
        temp = nil
        buffer.reserveCapacity(1 << 17)
    }

    init(path: String) {
        let temp = isSpecialFile(path) ? nil : path + ".hexer-\(getpid()).tmp"
        let fd = open(temp ?? path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { fail("cannot create \(path): \(String(cString: strerror(errno)))") }
        if let temp { pendingTemporaryFiles.insert(temp) }
        self.fd = fd
        self.path = path
        self.temp = temp
        buffer.reserveCapacity(1 << 17)
    }

    /// `path` as a file, or standard output when nil or `-`.
    static func to(_ path: String?) -> Output { path.flatMap { $0 == "-" ? nil : Output(path: $0) } ?? Output() }

    func write(_ s: String) {
        buffer.append(contentsOf: s.utf8)
        if buffer.count >= 1 << 16 { flush() }
    }

    func write(bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
        if buffer.count >= 1 << 16 { flush() }
    }

    func flush() {
        var done = 0
        while done < buffer.count {
            let n = buffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + done, $0.count - done) }
            if n < 0 {
                if errno == EINTR { continue }
                fail("write error on \(path ?? "standard output"): \(String(cString: strerror(errno)))")
            }
            done += n
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flushes and, for a file, moves it into place.
    func close() {
        flush()
        guard let path else { return }
        Darwin.close(fd)
        guard let temp else { return }
        guard rename(temp, path) == 0 else { fail("cannot create \(path): \(String(cString: strerror(errno)))") }
        pendingTemporaryFiles.remove(temp)
    }
}

/// `bytes` as uppercase hex pairs separated by spaces.
func hexBytes(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { NumberBase.hexadecimal.format(UInt64($0), minDigits: 2) }.joined(separator: " ")
}
