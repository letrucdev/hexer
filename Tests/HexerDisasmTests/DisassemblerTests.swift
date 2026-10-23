import Testing
import HexerDisasm

@Suite struct DisassemblerTests {
    @Test func version() {
        #expect(Disassembler.version == "5.0.9")
    }

    @Test func x86_64Prologue() throws {
        let d = try Disassembler(.x86_64)
        let insns = d.disassemble([0x55, 0x48, 0x89, 0xE5, 0xC3], address: 0x4000)
        #expect(insns.map(\.text) == ["push rbp", "mov rbp, rsp", "ret"])
        #expect(insns.map(\.address) == [0x4000, 0x4001, 0x4004])
        #expect(insns.map(\.size) == [1, 3, 1])
        #expect(insns[1].bytes == [0x48, 0x89, 0xE5])
        #expect(insns[1].mnemonic == "mov")
        #expect(insns[1].operands == "rbp, rsp")
        #expect(insns[1].endAddress == 0x4004)
        #expect(insns[2].operands.isEmpty)
    }

    @Test func x86_32() throws {
        let d = try Disassembler(.x86_32)
        let insn = try #require(d.first([0xB8, 0x01, 0x00, 0x00, 0x00]))
        #expect(insn.text == "mov eax, 1")
        #expect(insn.size == 5)
    }

    @Test func x86_16() throws {
        let d = try Disassembler(.x86_16)
        #expect(d.first([0xCD, 0x21])?.text == "int 0x21")
    }

    @Test func attSyntax() throws {
        let d = try Disassembler(.x86_64, syntax: .att)
        #expect(d.syntax == .att)
        #expect(d.disassemble([0x48, 0x89, 0xE5, 0xCD, 0x21]).map(\.text) == ["movq %rsp, %rbp", "int $0x21"])
    }

    @Test func arm64() throws {
        let d = try Disassembler(.arm64)
        let insns = d.disassemble([0xFD, 0x7B, 0xBF, 0xA9, 0xC0, 0x03, 0x5F, 0xD6], address: 0x1_0000_0000)
        #expect(insns.map(\.text) == ["stp x29, x30, [sp, #-0x10]!", "ret"])
        #expect(insns.map(\.address) == [0x1_0000_0000, 0x1_0000_0004])
        #expect(insns[1].bytes == [0xC0, 0x03, 0x5F, 0xD6])
    }

    @Test func relativeBranchUsesAddress() throws {
        let d = try Disassembler(.x86_64)
        #expect(d.first([0xEB, 0xFE], address: 0x1000)?.text == "jmp 0x1000")
        #expect(d.first([0xE8, 0x00, 0x00, 0x00, 0x00], address: 0x2000)?.text == "call 0x2005")
        let arm = try Disassembler(.arm64)
        #expect(arm.first([0x00, 0x00, 0x00, 0x94], address: 0x8000)?.text == "bl #0x8000")
        #expect(arm.first([0xFF, 0xFF, 0xFF, 0x17], address: 0x8000)?.text == "b #0x7ffc")
    }

    @Test func invalidBytes() throws {
        let x86 = try Disassembler(.x86_64)
        #expect(x86.first([0xFF, 0xFF]) == nil, "FF /7 is undefined")
        #expect(x86.first([0x0F, 0x04]) == nil)
        #expect(x86.first([0x06]) == nil, "push es is invalid in 64-bit mode")
        #expect(x86.disassemble([]).isEmpty)
        #expect(x86.first([0x48, 0x89]) == nil, "truncated instruction")
        let arm = try Disassembler(.arm64)
        #expect(arm.first([0xFF, 0xFF, 0xFF, 0xFF]) == nil)
        #expect(arm.first([0x00, 0x00, 0x00, 0x00])?.text == "udf #0", "permanently undefined, but a real instruction")
        #expect(arm.first([0xC0, 0x03, 0x5F]) == nil, "fewer than four bytes")
    }

    @Test func stopsAtFirstInvalidInstruction() throws {
        let d = try Disassembler(.x86_64)
        #expect(d.disassemble([0x90, 0x90, 0xFF, 0xFF, 0x90]).map(\.text) == ["nop", "nop"])
    }

    @Test func maxCount() throws {
        let d = try Disassembler(.x86_32)
        let nops = [UInt8](repeating: 0x90, count: 100)
        #expect(d.disassemble(nops).count == 100)
        #expect(d.disassemble(nops, maxCount: 3).count == 3)
    }

    @Test func architectureMetadata() {
        #expect(DisassemblyArchitecture.allCases.count == 4)
        #expect(DisassemblyArchitecture.x86_64.maxInstructionLength == 15)
        #expect(DisassemblyArchitecture.arm64.instructionAlignment == 4)
    }

    @Test func concurrentUse() async throws {
        let d = try Disassembler(.x86_64)
        let code: [UInt8] = [0x55, 0x48, 0x89, 0xE5, 0xC3]
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<32 {
                group.addTask { d.disassemble(code).map(\.text) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 == ["push rbp", "mov rbp, rsp", "ret"] })
    }
}
