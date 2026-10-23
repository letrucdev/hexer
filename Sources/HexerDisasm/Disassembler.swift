internal import CCapstone
import Synchronization

/// Decodes machine code with the bundled Capstone engine.
///
/// A Capstone handle must not be used from two threads at once, so calls are serialized by a lock;
/// create one disassembler per thread for parallel decoding.
public final class Disassembler: Sendable {
    /// Assembly syntax. Only x86 has alternatives; ARM64 always prints its standard syntax.
    public enum Syntax: String, CaseIterable, Sendable {
        case intel, att
    }

    public struct Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        /// Capstone's `cs_err` value.
        public let code: Int
        public let message: String

        public var description: String { "Capstone error \(code): \(message)" }

        init(_ err: cs_err) {
            code = Int(err.rawValue)
            message = String(cString: cs_strerror(err))
        }
    }

    /// Capstone's version, e.g. `"5.0.9"`.
    public static let version: String = {
        var major: Int32 = 0, minor: Int32 = 0
        cs_version(&major, &minor)
        return "\(major).\(minor).\(CS_VERSION_EXTRA)"
    }()

    public let architecture: DisassemblyArchitecture
    public let syntax: Syntax
    private let handle: Mutex<csh>

    public init(_ architecture: DisassemblyArchitecture, syntax: Syntax = .intel) throws {
        let (arch, mode): (cs_arch, cs_mode) = switch architecture {
        case .x86_16: (CS_ARCH_X86, CS_MODE_16)
        case .x86_32: (CS_ARCH_X86, CS_MODE_32)
        case .x86_64: (CS_ARCH_X86, CS_MODE_64)
        case .arm64: (CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        }
        var h: csh = 0
        let err = cs_open(arch, mode, &h)
        guard err == CS_ERR_OK else { throw Error(err) }
        if arch == CS_ARCH_X86 {
            let value = syntax == .att ? CS_OPT_SYNTAX_ATT : CS_OPT_SYNTAX_INTEL
            let err = cs_option(h, CS_OPT_SYNTAX, Int(value.rawValue))
            guard err == CS_ERR_OK else {
                cs_close(&h)
                throw Error(err)
            }
        }
        self.architecture = architecture
        self.syntax = syntax
        handle = Mutex(h)
    }

    deinit {
        handle.withLock { h in _ = cs_close(&h) }
    }

    /// Decodes consecutive instructions from the start of `bytes`, the first one located at `address`.
    /// Stops at the first undecodable sequence, at the end of `bytes`, or after `maxCount`
    /// instructions (0 means no limit).
    public func disassemble(_ bytes: [UInt8], address: UInt64 = 0, maxCount: Int = 0) -> [Instruction] {
        bytes.withUnsafeBufferPointer { buffer in
            handle.withLock { h in
                guard let base = buffer.baseAddress, let insn = cs_malloc(h) else { return [] }
                defer { cs_free(insn, 1) }
                var code: UnsafePointer<UInt8>? = base
                var remaining = buffer.count
                var next = address
                var result: [Instruction] = []
                while maxCount <= 0 || result.count < maxCount {
                    let offset = buffer.count - remaining
                    guard cs_disasm_iter(h, &code, &remaining, &next, insn) else { break }
                    let decoded = insn.pointee
                    result.append(Instruction(
                        address: decoded.address,
                        mnemonic: Self.string(decoded.mnemonic),
                        operands: Self.string(decoded.op_str),
                        bytes: Array(buffer[offset..<(offset + Int(decoded.size))])
                    ))
                }
                return result
            }
        }
    }

    /// Decodes the instruction at the start of `bytes`, or returns nil if they don't begin with one.
    public func first(_ bytes: [UInt8], address: UInt64 = 0) -> Instruction? {
        disassemble(bytes, address: address, maxCount: 1).first
    }

    /// Reads a NUL-terminated fixed-size C character array imported as a tuple.
    private static func string<T>(_ chars: T) -> String {
        withUnsafeBytes(of: chars) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
