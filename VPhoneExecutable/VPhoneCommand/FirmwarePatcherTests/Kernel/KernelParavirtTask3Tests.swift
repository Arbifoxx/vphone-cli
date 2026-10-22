@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Paravirtual GPU Task3")
struct KernelParavirtTask3Tests {
    // The raw vphone600 research kernel is operator supplied, never redistributed.
    static var fixture: String? { ProcessInfo.processInfo.environment["VPHONE_TASK3_KERNEL"] }

    private func prepared(_ data: Data) -> KernelCustomFirmwarePatcher {
        let patcher = KernelCustomFirmwarePatcher(data: data)
        patcher.parseMachO()
        patcher.buildADRPIndex()
        return patcher
    }

    @Test(.enabled(if: fixture != nil))
    func `discovers the complete patch in the supplied kernel`() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        let patcher = prepared(data)
        #expect(patcher.patchParavirtTask3Version())
        #expect(patcher.patches.count == 5)
        let ids = Set(patcher.patches.map(\.patchID))
        let prefix = FirmwarePatchSetCatalog.paravirtTask3Patch
        #expect(ids == Set(["request", "features", "features_code", "identity_hook", "identity_code"].map { prefix + "." + $0 }))

        let code = try #require(patcher.patches.first { $0.patchID == prefix + ".identity_code" })
        let hook = try #require(patcher.patches.first { $0.patchID == prefix + ".identity_hook" })
        for availability in [(true, true), (false, true), (true, false)] {
            try executeTrampoline(code, hook: hook, procAvailable: availability.0, hashAvailable: availability.1)
        }

        // Hosts grant 252 (macOS 27), their own maximum (245 on 26.4, 233 on
        // 26.0, 209 on 15.6.1) or a refusal. Only a version above the kext's
        // own becomes the kext's own.
        let features = try #require(patcher.patches.first { $0.patchID == prefix + ".features" })
        let clamp = try #require(patcher.patches.first { $0.patchID == prefix + ".features_code" })
        for (granted, expected): (UInt64, UInt64) in [(252, 245), (246, 245), (245, 245), (233, 233), (209, 209), (0x8000_00F5, 0x8000_00F5)] {
            #expect(try executeFeatureClamp(clamp, branch: features, granted: granted) == expected)
        }

        let second = prepared(patcher.patchedData)
        #expect(!second.patchParavirtTask3Version())
        #expect(second.patches.isEmpty)
    }

    /// Run the feature-version clamp from the branch that replaced the
    /// `mov x0, xV` and return `x0` where it rejoins the kext, one past that site.
    private func executeFeatureClamp(_ code: PatchRecord, branch: PatchRecord, granted: UInt64) throws -> UInt64 {
        let decoder = ARM64Disassembler()
        let jump = try #require(decoder.disassemble(branch.patchedBytes, at: UInt64(branch.fileOffset)).first)
        let displaced = try #require(decoder.disassemble(branch.originalBytes, at: UInt64(branch.fileOffset)).first)
        let grantedRegister = try #require(displaced.detail?.operands.last?.reg)
        #expect(jump.mnemonic == "b" && jump.detail?.operands.first?.imm == Int64(code.fileOffset))
        let instructions = decoder.disassemble(code.patchedBytes, at: UInt64(code.fileOffset))
        // tbnz names the W register for bits below 32; keep one X slot per register.
        func wide(_ r: ARM64Register) -> ARM64Register {
            (0 ... 30).first { ARM64Register.w($0) == r }.map { .x($0) } ?? r
        }
        var registers: [ARM64Register: UInt64] = [wide(grantedRegister): granted, .x(0): 0x1234]
        var pc = code.fileOffset
        for _ in 0 ..< 10 {
            if pc == branch.fileOffset + 4 { break }
            let i = try #require(instructions.first { $0.address == UInt64(pc) })
            let p = try #require(i.detail?.operands)
            var next = pc + 4
            switch i.mnemonic {
            case "sub": registers[wide(p[0].reg)] = registers[wide(p[1].reg), default: 0] &- UInt64(p[2].imm)
            case "tbnz": if registers[wide(p[0].reg), default: 0] >> UInt64(p[1].imm) & 1 == 1 { next = Int(p[2].imm) }
            case "mov" where p[1].type == .immediate: registers[wide(p[0].reg)] = UInt64(p[1].imm)
            case "mov": registers[wide(p[0].reg)] = registers[wide(p[1].reg), default: 0]
            case "b": next = Int(p[0].imm)
            default: Issue.record("Unexpected clamp instruction: \(i)")
            }
            pc = next
        }
        #expect(pc == branch.fileOffset + 4)
        #expect(registers[wide(grantedRegister)] == granted)
        return registers[.x(0), default: 0]
    }

    /// Execute the emitted instructions with hostile caller-saved register
    /// clobbers at the two helper calls. This catches stack/LR/root-pointer
    /// mistakes and over-copying that a disassembly snapshot would miss.
    private func executeTrampoline(_ code: PatchRecord, hook: PatchRecord, procAvailable: Bool, hashAvailable: Bool) throws {
        let decoder = ARM64Disassembler()
        let instructions = decoder.disassemble(code.patchedBytes, at: UInt64(code.fileOffset))
        let original = try #require(decoder.disassemble(hook.originalBytes, at: UInt64(hook.fileOffset)).first)
        let displaced = try #require(original.detail?.operands)
        let selfReg = displaced[1].mem.base
        let rootReg = try #require(instructions.first?.detail?.operands.last?.mem.base)
        let taskLoad = try #require(instructions.first {
            $0.mnemonic == "ldr" && $0.detail?.operands.last?.mem.base == selfReg
        })
        let ownerOffset = try #require(taskLoad.detail?.operands.last?.mem.disp)
        var registers = Dictionary(uniqueKeysWithValues: (0 ... 30).map { (ARM64Register.x($0), UInt64(0x100 + $0)) })
        registers[selfReg] = 0x300000
        registers[rootReg] = 0x200000
        let saved = registers
        var sp: UInt64 = 0x100000
        var memory: [UInt64: UInt8] = [:]
        func readRegister(_ r: ARM64Register) -> UInt64 {
            if r == .sp { return sp }
            if let n = (0 ... 30).first(where: { ARM64Register.w($0) == r }) {
                return registers[.x(n), default: 0] & 0xffff_ffff
            }
            return registers[r, default: 0]
        }
        func writeRegister(_ r: ARM64Register, _ value: UInt64) {
            if r == .sp { sp = value }
            else if let n = (0 ... 30).first(where: { ARM64Register.w($0) == r }) { registers[.x(n)] = value & 0xffff_ffff }
            else if r != .xzr && r != .wzr { registers[r] = value }
        }
        func store(_ address: UInt64, _ value: UInt64, _ count: Int) {
            for byte in 0 ..< count { memory[address + UInt64(byte)] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        func load(_ address: UInt64, _ count: Int) -> UInt64 {
            (0 ..< count).reduce(0) { $0 | UInt64(memory[address + UInt64($1), default: 0]) << ($1 * 8) }
        }
        func address(_ operand: ARM64Operand) -> UInt64 { readRegister(operand.mem.base) &+ UInt64(bitPattern: Int64(operand.mem.disp)) }
        store(0x300000 + UInt64(ownerOffset), 0x400000, 8)
        store(0x300000 + UInt64(displaced[1].mem.disp), 0xdeadbeef, 8)
        for byte in 0 ..< 80 { memory[0x200000 + UInt64(byte)] = 0xcc }
        let hash = (0 ..< 20).map { UInt8($0 + 1) }
        for byte in 0 ..< 20 { memory[0x600000 + UInt64(byte)] = hash[byte] }
        var pc = code.fileOffset
        var calls = 0
        for _ in 0 ..< 150 {
            if pc == hook.fileOffset + 4 { break }
            let i = try #require(instructions.first { $0.address == UInt64(pc) })
            let p = try #require(i.detail?.operands)
            var next = pc + 4
            switch i.mnemonic {
            case "sub", "add":
                let left = readRegister(p[1].reg), right = UInt64(p[2].imm)
                writeRegister(p[0].reg, i.mnemonic == "add" ? left &+ right : left &- right)
            case "stp":
                store(address(p[2]), readRegister(p[0].reg), 8)
                store(address(p[2]) + 8, readRegister(p[1].reg), 8)
            case "ldr", "str":
                let width = (0 ... 30).contains { ARM64Register.w($0) == p[0].reg } || p[0].reg == .wzr ? 4 : 8
                if i.mnemonic == "ldr" { writeRegister(p[0].reg, load(address(p[1]), width)) }
                else { store(address(p[1]), readRegister(p[0].reg), width) }
            case "bl":
                #expect(readRegister(.x(0)) == (calls == 0 ? 0x400000 : 0x500000))
                for reg in 0 ... 17 { registers[.x(reg)] = UInt64(0x700000 + reg) }
                registers[.x(30)] = UInt64(pc + 4)
                registers[.x(0)] = calls == 0 ? (procAvailable ? 0x500000 : 0) : (hashAvailable ? 0x600000 : 0)
                calls += 1
            case "cbz":
                if readRegister(p[0].reg) == 0 { next = Int(p[1].imm) }
            case "b": next = Int(p[0].imm)
            default: Issue.record("Unexpected trampoline instruction: \(i)")
            }
            pc = next
        }
        #expect(pc == hook.fileOffset + 4)
        #expect(sp == 0x100000)
        #expect(calls == (procAvailable ? 2 : 1))
        for reg in 1 ... 30 { #expect(registers[.x(reg)] == saved[.x(reg)]) }
        #expect(registers[.x(0)] == 0xdeadbeef)
        let key = (0 ..< 20).map { memory[0x200028 + UInt64($0), default: 0] }
        #expect(key == (procAvailable && hashAvailable ? hash : Array(repeating: 0, count: 20)))
        #expect((0 ..< 40).allSatisfy { memory[0x200000 + UInt64($0)] == 0xcc })
        #expect((60 ..< 80).allSatisfy { memory[0x200000 + UInt64($0)] == 0xcc })
    }

    @Test(.enabled(if: fixture != nil), arguments: [
        "%s: Failed to create Page Table Lock\n",
        "(%u): failed to get the cdhash\n",
    ])
    func `missing identity anchor leaves every Task3 site unchanged`(text: String) throws {
        var data = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        let anchor = Data(text.utf8)
        let range = try #require(data.range(of: anchor))
        data[range.lowerBound] = 0
        let patcher = prepared(data)
        #expect(!patcher.patchParavirtTask3Version())
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == data)
    }
}
