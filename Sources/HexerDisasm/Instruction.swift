/// The processor (and mode) whose machine code is decoded.
public enum DisassemblyArchitecture: String, CaseIterable, Sendable {
    case x86_16, x86_32, x86_64, arm64

    public var displayName: String {
        switch self {
        case .x86_16: "x86 (16-bit)"
        case .x86_32: "x86 (32-bit)"
        case .x86_64: "x86-64"
        case .arm64: "ARM64"
        }
    }

    /// The longest encoding an instruction can have, in bytes.
    public var maxInstructionLength: Int {
        switch self {
        case .x86_16, .x86_32, .x86_64: 15
        case .arm64: 4
        }
    }

    /// Instructions start at multiples of this many bytes.
    public var instructionAlignment: Int {
        switch self {
        case .x86_16, .x86_32, .x86_64: 1
        case .arm64: 4
        }
    }
}

/// One decoded machine instruction.
public struct Instruction: Sendable, Hashable {
    /// The address the instruction was decoded at.
    public let address: UInt64
    /// Lowercase mnemonic, including any prefix (`"rep stosb"`, `"lock add"`).
    public let mnemonic: String
    /// Operands as printed in the chosen syntax, empty when there are none.
    public let operands: String
    /// The encoding.
    public let bytes: [UInt8]

    public init(address: UInt64, mnemonic: String, operands: String, bytes: [UInt8]) {
        self.address = address
        self.mnemonic = mnemonic
        self.operands = operands
        self.bytes = bytes
    }

    /// Length of the encoding in bytes.
    public var size: Int { bytes.count }

    /// The address just past the instruction.
    public var endAddress: UInt64 { address &+ UInt64(bytes.count) }

    /// Mnemonic and operands, e.g. `"mov rbp, rsp"`.
    public var text: String { operands.isEmpty ? mnemonic : "\(mnemonic) \(operands)" }
}

extension Instruction: CustomStringConvertible {
    public var description: String { text }
}
