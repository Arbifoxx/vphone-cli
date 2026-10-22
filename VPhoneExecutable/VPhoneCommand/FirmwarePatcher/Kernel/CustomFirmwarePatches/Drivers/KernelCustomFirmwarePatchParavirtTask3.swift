// KernelCustomFirmwarePatchParavirtTask3.swift — CFW kernel patch: ask the host
// for paravirtual GPU binary version 252 while the guest keeps the features of
// the version it was built for, and fill each task's Task3 executable identity
// before the host registers it. Both parts share one patch declaration.
//
// Background: the guest GPU kext (AppleParavirtGPUIOGPUFamily) negotiates a
// binary version with ParavirtualizedGraphics at start-up, and the host derives
// its APVFeatures from it (`getAPVFeaturesForVersion`), a ladder where newer
// versions add flags. The cloudOS 26.4 kext asks for 245. 250 adds
// supportsDisplayBrightnessCaps, 251 supportsHDRContentHeadroom and 252
// supportsTask3, which makes `-[PGRemoteTask calculateCachePathAndExtension:
// taskRoot:]` name a task's host shader cache after 20 guest bytes (task root
// page, offset 0x28) when they are not all zero, instead of 10 random bytes.
// Host-side, the 250 flag is read only by a brightness test hook and the 251
// flag by nothing. See Research/Guest/gpu_acceleration.md.
//
// The kext's `setupVersion` path:
//
//     mov  wR, #<version>          ; the version this kext was built for
//     str  wR, [xSelf, #ivar]
//     ldr  xRegs, [xSelf, #regs]
//     str  wR, [xRegs, #reg]       ; request
//     ...
//     ldr  wV, [xRegs, #reg]       ; what the host granted
//     ...
//     mov  x0, xV                  ; guest-side features for that version
//     bl   <guest getAPVFeaturesForVersion>
//
// The guest's own table stops at the version it was built for, so a granted 252
// would come back invalid and the kext would step down again. The patch asks for
// 252 and computes the guest's features from the lower of the granted version
// and the original immediate, so the guest keeps its behaviour while the host
// runs its Task3 path.
//
// A host that does not know the requested version grants its own maximum
// instead, without the refusal bit: 245 on macOS 26.4, 233 on 26.0, 209 on
// 15.6.1 (`-[_PGDevice setBinaryVersion:]`). Features computed from the kext's
// own 245 there would claim flags the host never enabled, so a granted version
// below the kext's own, or a refusal, still reaches the call unchanged.
//
// Anchor (no offsets): the `setupVersion` cstring, whose references all sit in
// that one function; inside it, the request store and the readback of the same
// register displacement, and the granted version passed to the next call.

import Foundation
import VPhonePatchKit

extension KernelCustomFirmwarePatcher {
    /// The binary version whose host features include supportsTask3.
    private static let paravirtTask3Version: UInt16 = 252

    @discardableResult
    func patchParavirtTask3Version() -> Bool {
        log("\n[CFW]AppleParavirtGPU binary version: request \(Self.paravirtTask3Version), keep the guest's own features")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }
        guard let nameOff = buffer.findString("setupVersion") else {
            log("  [-] setupVersion cstring not found")
            return false
        }
        let refs = findStringRefs(nameOff, in: (ks, ke))
        let starts = Set(refs.compactMap { findFunctionStart($0.adrpOff) })
        guard starts.count == 1, let funcStart = starts.first,
              let lastRef = refs.map(\.adrpOff).max()
        else {
            log("  [-] setupVersion not resolved to one function (found \(starts.count))")
            return false
        }

        var hits: [(request: Int, rd: UInt32, version: UInt16, granted: UInt32, featureArg: Int)] = []
        var off = funcStart
        while off < lastRef {
            defer { off += 4 }
            guard let (rd, version) = plainMoveW(at: off),
                  version >= 200, version < Self.paravirtTask3Version,
                  let regDisp = requestStore(of: rd, after: off),
                  let granted = readback(disp: regDisp, after: off),
                  let grantedNumber = (0 ... 30).first(where: { ARM64Register.w($0) == granted.register }),
                  let featureArg = versionArgument(granted.register, after: granted.offset)
            else { continue }
            hits.append((off, rd, version, UInt32(grantedNumber), featureArg))
        }

        guard hits.count == 1, let hit = hits.first else {
            log("  [-] version request not found uniquely (found \(hits.count))")
            return false
        }
        // One cave: the identity trampoline, then the feature-version clamp.
        let featureSlot = 256
        guard let request = ARM64Encoder.encodeMovzW(rd: hit.rd, imm16: Self.paravirtTask3Version),
              let identity = paravirtTaskIdentity(),
              let cave = findCodeCave(size: featureSlot + 32),
              let code = pvIdentityCode(identity, at: cave), code.count <= featureSlot,
              let branch = ARM64Encoder.encodeB(from: identity.hook, to: cave),
              let featureCode = pvFeatureVersionCode(
                  granted: hit.granted, version: hit.version, at: cave + featureSlot, resume: hit.featureArg + 4,
              ),
              let featureBranch = ARM64Encoder.encodeB(from: hit.featureArg, to: cave + featureSlot)
        else {
            log("  [-] Task3 discovery or encoding failed; no Task3 sites written")
            return false
        }

        emit(cave, code, patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".identity_code",
             virtualAddress: fileOffsetToVA(cave), description: "copy the owning executable's 20-byte cdhash into TaskRoot+0x28")
        emit(identity.hook, branch, patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".identity_hook",
             virtualAddress: fileOffsetToVA(identity.hook), description: "write Task3 identity before descriptor preparation and task registration")

        emit(
            hit.request,
            request,
            patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".request",
            virtualAddress: fileOffsetToVA(hit.request),
            description: "binary version request mov w\(hit.rd),#\(hit.version) -> #\(Self.paravirtTask3Version)",
        )
        emit(
            cave + featureSlot,
            featureCode,
            patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".features_code",
            virtualAddress: fileOffsetToVA(cave + featureSlot),
            description: "guest features from min(granted, \(hit.version)); a refusal passes through",
        )
        emit(
            hit.featureArg,
            featureBranch,
            patchID: FirmwarePatchSetCatalog.paravirtTask3Patch + ".features",
            virtualAddress: fileOffsetToVA(hit.featureArg),
            description: "guest features version mov x0,x\(hit.granted) -> b clamp",
        )
        return true
    }

    /// `x0` for the guest's feature lookup: the granted version, or the kext's
    /// own when the host granted a newer one. A granted version below the
    /// kext's own (an older host's maximum) and a refusal (bit 31) pass through
    /// as the displaced `mov x0, xV` would have passed them.
    private func pvFeatureVersionCode(granted: UInt32, version: UInt16, at cave: Int, resume: Int) -> Data? {
        let passThrough = cave + 20
        let words: [Data?] = [
            ARM64Encoder.encodeSubImm12(rd: 0, rn: granted, imm12: UInt32(version) + 1),
            ARM64Encoder.encodeTestBitBranch(nonzero: true, register: 0, bit: 63, from: cave + 4, to: passThrough),
            ARM64Encoder.encodeTestBitBranch(nonzero: true, register: granted, bit: 31, from: cave + 8, to: passThrough),
            ARM64Encoder.encodeMovzW(rd: 0, imm16: version),
            ARM64Encoder.encodeB(from: cave + 16, to: resume),
            ARM64Encoder.encodeMovX(rd: 0, rm: granted),
            ARM64Encoder.encodeB(from: cave + 24, to: resume),
        ]
        guard words.allSatisfy({ $0 != nil }) else { return nil }
        return words.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
    }

    /// The register number and value when the instruction at `off` is a lone
    /// `mov wN, #imm` (no `movk` after it).
    private func plainMoveW(at off: Int) -> (UInt32, UInt16)? {
        guard let insn = disasAt(off), insn.mnemonic == "mov",
              let ops = insn.detail?.operands, ops.count == 2,
              ops[0].type == .register, ops[1].type == .immediate,
              (0 ... 0xFFFF).contains(ops[1].imm),
              let rd = (0 ... 30).first(where: { ARM64Register.w($0) == ops[0].reg }),
              disasAt(off + 4)?.mnemonic != "movk"
        else { return nil }
        return (UInt32(rd), UInt16(ops[1].imm))
    }

    /// The displacement of the register store `str wN, [xB, #disp]` that follows
    /// within four instructions, where `xB` was just loaded from memory: the
    /// version request written to the device.
    private func requestStore(of rd: UInt32, after off: Int) -> Int32? {
        let reg = ARM64Register.w(Int(rd))
        var loadedBases: Set<ARM64Register> = []
        for delta in stride(from: 4, through: 16, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "ldr", ops.count == 2, ops[0].type == .register, ops[1].type == .memory {
                loadedBases.insert(ops[0].reg)
            }
            if insn.mnemonic == "str", ops.count == 2, ops[0].type == .register, ops[0].reg == reg,
               ops[1].type == .memory, ops[1].mem.index == .invalid, loadedBases.contains(ops[1].mem.base)
            {
                return ops[1].mem.disp
            }
            if insn.isJump || insn.isCall || insn.isReturn { return nil }
        }
        return nil
    }

    /// The 32-bit load of the same device register within the next 12
    /// instructions: what the host granted.
    private func readback(disp: Int32, after off: Int) -> (register: ARM64Register, offset: Int)? {
        for delta in stride(from: 8, through: 48, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "ldr", ops.count == 2, ops[0].type == .register,
               (0 ... 30).contains(where: { ARM64Register.w($0) == ops[0].reg }),
               ops[1].type == .memory, ops[1].mem.index == .invalid, ops[1].mem.disp == disp
            {
                return (ops[0].reg, off + delta)
            }
            if insn.isReturn || insn.mnemonic == "b" || insn.mnemonic == "br" { return nil }
        }
        return nil
    }

    /// The `mov x0, xV` immediately before a `bl`, within the next 16
    /// instructions, passing the granted version on.
    private func versionArgument(_ granted: ARM64Register, after off: Int) -> Int? {
        guard let number = (0 ... 30).first(where: { ARM64Register.w($0) == granted }) else { return nil }
        let wide = ARM64Register.x(number)
        for delta in stride(from: 4, through: 64, by: 4) {
            guard let insn = disasAt(off + delta), let ops = insn.detail?.operands else { return nil }
            if insn.mnemonic == "mov", ops.count == 2,
               ops[0].type == .register, ops[0].reg == .x(0),
               ops[1].type == .register, ops[1].reg == wide,
               disasAt(off + delta + 4)?.mnemonic == "bl"
            {
                return off + delta
            }
            if insn.isReturn || insn.mnemonic == "b" || insn.mnemonic == "br" { return nil }
        }
        return nil
    }
}

// MARK: - Task3 executable identity

extension KernelCustomFirmwarePatcher {
    private struct ParavirtTaskIdentity {
        let hook: Int
        let selfRegister: UInt32
        let rootRegister: UInt32
        let descriptorOffset: UInt32
        let ownerOffset: UInt32
        let getBSDTaskInfo: Int
        let getCDHash: Int
    }

    /// Discover every dependency before emitting any of the indivisible Task3 sites.
    /// XNU sources: kern_cs.c::cs_get_cdhash, flow_divert.c::flow_divert_get_app_data,
    /// bsd_kern.c::get_bsdtask_info. No task/proc layout offsets are assumed here.
    private func paravirtTaskIdentity() -> ParavirtTaskIdentity? {
        guard let anchor = buffer.findString("%s: Failed to create Page Table Lock\n") else {
            log("  [-] Task3 task initializer anchor absent")
            return nil
        }
        let starts = Set(findStringRefs(anchor).compactMap { pvFunctionStart($0.adrpOff) })
        guard starts.count == 1, let start = starts.first,
              let selfReg = pvIncomingRegister(0, at: start),
              let taskReg = pvIncomingRegister(2, at: start),
              let ownerOffset = pvOwnerOffset(start: start, selfReg: selfReg, taskReg: taskReg)
        else {
            log("  [-] Task3 owning task could not be recovered from the superclass initializer")
            return nil
        }

        var hooks: [(Int, UInt32, UInt32)] = []
        for off in stride(from: start, to: min(start + 0x1000, buffer.count - 40), by: 4) {
            // The original TaskRoot header ends at 0x28. Match its complete tail,
            // including the unaligned fields, then displace the descriptor load.
            guard let pair = disasAt(off), pair.mnemonic == "stp",
                  let p = pair.detail?.operands, p.count == 3,
                  pair.detail?.writeback == false, p[0].type == .register, p[0].reg == .w(0),
                  let version = plainMoveW(at: off - 4), version.1 == 2,
                  p[1].type == .register, p[1].reg == .w(Int(version.0)),
                  p[2].type == .memory, p[2].mem.disp == 0, p[2].mem.index == .invalid,
                  let root = pvXNumber(p[2].mem.base), root < 18,
                  pvMemory(off + 4, "str", .xzr, .x(Int(root)), 8),
                  pvMemory(off + 8, "str", .wzr, .x(Int(root)), 0x10),
                  let field = disasAt(off + 12)?.detail?.operands, field.count == 2,
                  disasAt(off + 12)?.mnemonic == "ldr", field[1].mem.base == .x(Int(selfReg)),
                  pvMemory(off + 16, "stur", field[0].reg, .x(Int(root)), 0x14),
                  pvMemory(off + 20, "stur", .xzr, .x(Int(root)), 0x1c),
                  pvMemory(off + 24, "str", .wzr, .x(Int(root)), 0x24),
                  let load = disasAt(off + 28), load.mnemonic == "ldr", load.detail?.writeback == false,
                  let l = load.detail?.operands, l.count == 2, l[0].reg == .x(0),
                  l[1].type == .memory, l[1].mem.base == .x(Int(selfReg)), l[1].mem.index == .invalid,
                  l[1].mem.disp >= 0,
                  pvDescriptorHasKeySpace(start: start, end: off, selfReg: selfReg, descriptorOffset: l[1].mem.disp),
                  pvMemory(off + 32, "ldr", .x(16), .x(0), 0)
            else { continue }
            hooks.append((off + 28, root, UInt32(l[1].mem.disp)))
        }
        guard hooks.count == 1, let hook = hooks.first, let helpers = pvIdentityHelpers() else {
            log("  [-] Task3 header or kernel identity helpers not resolved uniquely")
            return nil
        }
        return ParavirtTaskIdentity(
            hook: hook.0, selfRegister: selfReg, rootRegister: hook.1,
            descriptorOffset: hook.2, ownerOffset: ownerOffset,
            getBSDTaskInfo: helpers.bsd, getCDHash: helpers.hash
        )
    }

    /// Follow the sized allocation's saved return value to this descriptor ivar.
    /// The bounded header view is only 40 bytes; its backing allocation must
    /// independently have room for the host's 60-byte Task3 root read.
    private func pvDescriptorHasKeySpace(start: Int, end: Int, selfReg: UInt32, descriptorOffset: Int32) -> Bool {
        for off in stride(from: start, to: end, by: 4) {
            guard let size = plainMoveW(at: off), size.0 == 2, size.1 >= 60,
                  pvBranch(off + 4, mnemonic: "bl") != nil,
                  let move = disasAt(off + 8), move.mnemonic == "mov",
                  let p = move.detail?.operands, p.count == 2, p[1].reg == .x(0),
                  let saved = pvXNumber(p[0].reg), saved >= 19
            else { continue }
            if stride(from: off + 12, through: min(off + 64, end), by: 4).contains(where: {
                pvMemory($0, "str", .x(Int(saved)), .x(Int(selfReg)), descriptorOffset)
            }) { return true }
        }
        return false
    }

    private func pvFunctionStart(_ at: Int) -> Int? {
        for off in stride(from: at & ~3, through: max(0, at - 0x4000), by: -4) {
            if disasAt(off)?.mnemonic == "pacibsp" { return off }
        }
        return nil
    }

    private func pvXNumber(_ reg: ARM64Register) -> UInt32? {
        (0 ... 30).first { ARM64Register.x($0) == reg }.map(UInt32.init)
    }

    private func pvMove(_ at: Int, _ to: ARM64Register, _ from: ARM64Register) -> Bool {
        guard let i = disasAt(at), i.mnemonic == "mov", let p = i.detail?.operands, p.count == 2 else { return false }
        return p[0].type == .register && p[0].reg == to && p[1].type == .register && p[1].reg == from
    }

    private func pvMemory(_ at: Int, _ mnemonic: String, _ reg: ARM64Register, _ base: ARM64Register, _ disp: Int32) -> Bool {
        guard let i = disasAt(at), i.mnemonic == mnemonic, i.detail?.writeback == false,
              let p = i.detail?.operands, p.count == 2 else { return false }
        return p[0].type == .register && p[0].reg == reg && p[1].type == .memory
            && p[1].mem.base == base && p[1].mem.index == .invalid && p[1].mem.disp == disp
    }

    private func pvIncomingRegister(_ arg: Int, at start: Int) -> UInt32? {
        for off in stride(from: start + 4, to: start + 0x80, by: 4) {
            guard let i = disasAt(off) else { return nil }
            if i.isCall { return nil }
            if i.mnemonic == "mov", let p = i.detail?.operands, p.count == 2,
               p[1].type == .register, p[1].reg == .x(arg), let reg = pvXNumber(p[0].reg), reg >= 19 {
                return reg
            }
        }
        return nil
    }

    /// ADRP followed by a 64-bit load of a global. Values are file coordinates,
    /// as are Capstone's PC-relative operands in the kernel patcher.
    private func pvGlobalLoad(_ at: Int) -> (global: Int, register: ARM64Register)? {
        guard let a = disasAt(at), a.mnemonic == "adrp", let p = a.detail?.operands, p.count == 2,
              p[1].type == .immediate,
              let l = disasAt(at + 4), l.mnemonic == "ldr", l.detail?.writeback == false,
              let q = l.detail?.operands, q.count == 2, pvXNumber(q[0].reg) != nil,
              q[1].type == .memory, q[1].mem.base == p[0].reg, q[1].mem.index == .invalid
        else { return nil }
        let global = Int(p[1].imm) + Int(q[1].mem.disp)
        guard global >= 0, global + 8 <= buffer.count else { return nil }
        return (global, q[0].reg)
    }

    private func pvBranch(_ at: Int, mnemonic: String) -> Int? {
        guard let i = disasAt(at), i.mnemonic == mnemonic,
              let last = i.detail?.operands.last, last.type == .immediate else { return nil }
        let target = Int(last.imm)
        return jbIsInCodeRange(target) ? target : nil
    }

    /// Follow the superclass vtable, then recover the store of its incoming task
    /// argument. Both authenticated and unauthenticated kernelcache rebases use
    /// a base-relative 30-bit target; reject binds and out-of-image pointers.
    private func pvRebase(_ at: Int) -> Int? {
        guard at >= 0, at + 8 <= buffer.count else { return nil }
        let raw = buffer.readU64(at: at)
        guard raw & (1 << 62) == 0 else { return nil }
        let target = Int(raw & 0x3fff_ffff)
        return target > 0 && target < buffer.count ? target : nil
    }

    private func pvOwnerOffset(start: Int, selfReg: UInt32, taskReg: UInt32) -> UInt32? {
        var offsets = Set<UInt32>()
        for off in stride(from: start, to: start + 0x200, by: 4) {
            guard let g = pvGlobalLoad(off), let table = pvRebase(g.global),
                  let l = disasAt(off + 8), l.mnemonic == "ldr", l.detail?.writeback == true,
                  let p = l.detail?.operands, p.count == 2, p[1].type == .memory,
                  p[1].mem.base == g.register, p[1].mem.index == .invalid,
                  let parent = pvRebase(table + Int(p[1].mem.disp)), jbIsInCodeRange(parent),
                  disasAt(parent)?.mnemonic == "pacibsp",
                  let call = (1 ... 10).map({ off + 8 + $0 * 4 }).first(where: {
                      disasAt($0)?.mnemonic == "blraa" && disasAt($0)?.detail?.operands.first?.reg == p[0].reg
                  }), call > off + 8,
                  stride(from: off + 12, to: call, by: 4).contains(where: { pvMove($0, .x(2), .x(Int(taskReg))) }),
                  stride(from: off + 12, to: call, by: 4).contains(where: { pvMove($0, .x(0), .x(Int(selfReg))) }),
                  let parentSelf = pvIncomingRegister(0, at: parent),
                  let parentTask = pvIncomingRegister(2, at: parent)
            else { continue }
            for store in stride(from: parent + 4, to: parent + 0x200, by: 4) {
                guard let i = disasAt(store), i.mnemonic == "str", i.detail?.writeback == false,
                      let q = i.detail?.operands, q.count == 2, q[0].reg == .x(Int(parentTask)),
                      q[1].type == .memory, q[1].mem.base == .x(Int(parentSelf)), q[1].mem.index == .invalid,
                      q[1].mem.disp > 0, q[1].mem.disp % 8 == 0,
                      pvBranch(store - 4, mnemonic: "bl") != nil,
                      pvMove(store - 8, .x(0), .x(Int(parentTask)))
                else { continue }
                offsets.insert(UInt32(q[1].mem.disp))
            }
        }
        return offsets.count == 1 ? offsets.first : nil
    }

    private func pvIdentityHelpers() -> (bsd: Int, hash: Int)? {
        guard let string = buffer.findString("(%u): failed to get the cdhash\n") else { return nil }
        let refs = findStringRefs(string)
        guard refs.count == 1, let ref = refs.first, let start = pvFunctionStart(ref.adrpOff) else { return nil }
        var hashes = Set<Int>()
        for off in stride(from: start, to: ref.adrpOff, by: 4) {
            guard let target = pvBranch(off, mnemonic: "bl"),
                  let failure = pvBranch(off + 4, mnemonic: "cbz"),
                  disasAt(off + 4)?.detail?.operands.first?.reg == .x(0),
                  failure <= ref.adrpOff, failure >= ref.adrpOff - 32,
                  pvMove(off + 8, .x(3), .x(0)),
                  (3 ... 9).contains(where: { plainMoveW(at: off + $0 * 4).map { $0.0 == 2 && $0.1 == 20 } == true })
            else { continue }
            hashes.insert(target)
        }
        guard hashes.count == 1, let hash = hashes.first,
              disasAt(hash)?.mnemonic == "pacibsp" else { return nil }

        // Source-backed proc_task(p): test P_LHASTASK, load proc_struct_size,
        // add it to p, then test the returned task. This supplies the global
        // referenced by the inverse get_bsdtask_info() without a fixed address.
        var sizes = Set<Int>()
        for off in stride(from: ref.addOff + 4, through: ref.addOff + 80, by: 4) {
            guard let g = pvGlobalLoad(off), let add = disasAt(off + 8), add.mnemonic == "add",
                  let p = add.detail?.operands, p.count == 3, p[0].reg == .x(0), p[1].reg == g.register,
                  pvXNumber(p[2].reg) != nil, pvBranch(off + 12, mnemonic: "cbz") != nil,
                  let test = disasAt(off - 4), test.mnemonic == "tbz", let q = test.detail?.operands,
                  q.count == 3, q[1].type == .immediate, q[1].imm == 1
            else { continue }
            sizes.insert(g.global)
        }
        guard sizes.count == 1, let size = sizes.first else { return nil }
        var getters = Set<Int>()
        for off in adrpIndex[UInt64(size) & ~0xfff] ?? [] {
            guard let g = pvGlobalLoad(off), g.global == size,
                  let sub = disasAt(off + 8), sub.mnemonic == "subs", let p = sub.detail?.operands,
                  p.count == 3, p[0].reg == .x(1), p[1].reg == .x(0), p[2].reg == g.register,
                  let tail = pvBranch(off + 12, mnemonic: "b.eq"), tail > off, tail < off + 0x100,
                  let load = disasAt(tail), load.mnemonic == "ldr", let l = load.detail?.operands,
                  l.count == 2, l[1].type == .memory, l[1].mem.base == .x(0),
                  let test = disasAt(tail + 4), test.mnemonic == "tst", let t = test.detail?.operands,
                  t.count == 2, t[0].reg == l[0].reg, t[1].type == .immediate, t[1].imm == 0x0080_0000,
                  let select = disasAt(tail + 8), select.mnemonic == "csel", select.detail?.conditionCode == .eq,
                  let s = select.detail?.operands, s.count == 3,
                  s[0].reg == .x(0), s[1].reg == .xzr, s[2].reg == .x(1),
                  disasAt(tail + 12)?.mnemonic == "ret"
            else { continue }
            getters.insert(off)
        }
        guard getters.count == 1, let bsd = getters.first else { return nil }
        log(String(format: "  [+] Task3 helpers: get_bsdtask_info @ 0x%X, cs_get_cdhash @ 0x%X", bsd, hash))
        return (bsd, hash)
    }

    /// Inline trampoline: preserve every volatile GPR and LR, obtain the owning
    /// task's cdhash, copy exactly 20 bytes, replay the displaced descriptor load.
    /// A missing proc/hash leaves a zero key and the host's ephemeral fallback.
    private func pvIdentityCode(_ site: ParavirtTaskIdentity, at cave: Int) -> Data? {
        var words: [Data?] = []
        func put(_ word: Data?) { words.append(word) }
        let root = site.rootRegister
        put(ARM64Encoder.encodeStrXUnsignedOffset(rt: 31, rn: root, offset: 0x28))
        put(ARM64Encoder.encodeStrXUnsignedOffset(rt: 31, rn: root, offset: 0x30))
        put(ARM64Encoder.encodeStrWUnsignedOffset(rt: 31, rn: root, offset: 0x38))
        put(ARM64Encoder.encodeSubImm12(rd: 31, rn: 31, imm12: 160))
        for reg in stride(from: UInt32(0), through: 16, by: 2) {
            put(ARM64Encoder.encodeStpX(rt1: reg, rt2: reg + 1, rn: 31, offset: Int32(reg * 8)))
        }
        put(ARM64Encoder.encodeStpX(rt1: 18, rt2: 30, rn: 31, offset: 144))
        put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: site.selfRegister, offset: site.ownerOffset))
        put(ARM64Encoder.encodeBL(from: cave + words.count * 4, to: site.getBSDTaskInfo))
        let noProc = words.count; put(nil)
        put(ARM64Encoder.encodeBL(from: cave + words.count * 4, to: site.getCDHash))
        let noHash = words.count; put(nil)
        put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 9, rn: 31, offset: root * 8))
        for offset in stride(from: UInt32(0), to: 20, by: 4) {
            put(ARM64Encoder.encodeLdrWUnsignedOffset(rt: 10, rn: 0, offset: offset))
            put(ARM64Encoder.encodeStrWUnsignedOffset(rt: 10, rn: 9, offset: 0x28 + offset))
        }
        let done = cave + words.count * 4
        for index in [noProc, noHash] {
            words[index] = ARM64Encoder.encodeCompareBranch(nonzero: false, register: 0, from: cave + index * 4, to: done, width64: true)
        }
        for reg in UInt32(0) ... 18 {
            put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: reg, rn: 31, offset: reg * 8))
        }
        put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 30, rn: 31, offset: 152))
        put(ARM64Encoder.encodeAddImm12(rd: 31, rn: 31, imm12: 160))
        put(ARM64Encoder.encodeLdrXUnsignedOffset(rt: 0, rn: site.selfRegister, offset: site.descriptorOffset))
        put(ARM64Encoder.encodeB(from: cave + words.count * 4, to: site.hook + 4))
        guard words.allSatisfy({ $0 != nil }) else { return nil }
        return words.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
    }
}
