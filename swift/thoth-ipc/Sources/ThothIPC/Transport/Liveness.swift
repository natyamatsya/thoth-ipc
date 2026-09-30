// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Dead-connection reaper owner table (RFC:
// context/dead-connection-reaper-rfc.md), Swift side. **Byte-exact with
// cpp/thoth-ipc/src/thoth-ipc/liveness.h and rust/thoth-ipc/src/liveness.rs**
// (xlang-channel-abi.md §9): a per-cc_-bit table of { pid:int32 @0, start_tok:u64
// @8 } (16 bytes each, 32 slots = 512 bytes) in a dedicated LV_CONN__ segment.
// A receiver records its {pid, start_token} on connect so any participant's
// reaper can reclaim the slot if the process dies; a receiver reaps dead peers on
// connect. The start-token formula MUST match C++/Rust exactly, or a reaper of a
// different language would compute a mismatched token for a LIVE Swift receiver
// and falsely reap it.
//
// Swift struct layout is not C-guaranteed, so the table is accessed via raw byte
// offsets + UnsafeAtomic, the same way the ring header/slots are.

import Darwin
import Atomics

let livenessMaxSlots = 32
let livenessSlotStride = ABI.liveness_slot_size        // sizeof(slot_owner) = 16
let livenessPidOffset = ABI.liveness_slot_pid_off      // int32 @0
let livenessTokOffset = ABI.liveness_slot_start_tok_off // uint64 @8
let livenessShmSizeBytes = livenessMaxSlots * livenessSlotStride  // 512

func livenessName(_ prefix: String, _ name: String) -> String {
    "\(fullPrefix(prefix))LV_CONN__\(name)"
}

@inline(__always) func slotIndex(_ bit: UInt32) -> Int { Int(bit.trailingZeroBitCount) }

@inline(__always) func ownerPid(_ lv: UnsafeMutableRawPointer, _ idx: Int) -> UnsafeAtomic<UInt32> {
    UnsafeAtomic(at: lv.advanced(by: idx * livenessSlotStride + livenessPidOffset)
        .assumingMemoryBound(to: UnsafeAtomic<UInt32>.Storage.self))
}
@inline(__always) func ownerTok(_ lv: UnsafeMutableRawPointer, _ idx: Int) -> UnsafeAtomic<UInt64> {
    UnsafeAtomic(at: lv.advanced(by: idx * livenessSlotStride + livenessTokOffset)
        .assumingMemoryBound(to: UnsafeAtomic<UInt64>.Storage.self))
}

@inline(__always) func selfPid() -> Int32 { getpid() }

/// Process start token — byte-exact with C++/Rust: BSD start time packed as
/// tvsec * 1_000_000 + tvusec. 0 == "couldn't determine".
func startToken(_ pid: Int32) -> UInt64 {
    guard pid > 0 else { return 0 }
    var info = proc_bsdinfo()
    let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz)
    guard n == sz else { return 0 }
    return UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
}

/// Is the recorded process (pid + token) still alive? Conservative: any
/// "can't determine" answer errs toward ALIVE so a live peer is never false-reaped.
func isProcessAlive(_ pid: Int32, _ tok: UInt64) -> Bool {
    guard pid > 0 else { return false }
    let exists = kill(pid, 0) == 0 || errno != ESRCH
    if !exists { return false }        // definitely gone
    if tok == 0 { return true }        // no recorded token → token-less fallback
    let cur = startToken(pid)
    if cur == 0 { return true }        // couldn't read → don't risk a false reap
    return cur == tok                  // mismatch ⇒ PID reused ⇒ our owner is gone
}

/// Record ownership of a freshly connected slot (after the cc_ bit is claimed).
func livenessSetOwner(_ lv: UnsafeMutableRawPointer, _ bit: UInt32) {
    guard bit != 0 else { return }
    let idx = slotIndex(bit)
    // Token first, then pid with release: a reader that sees our pid sees the token.
    ownerTok(lv, idx).store(startToken(selfPid()), ordering: .relaxed)
    ownerPid(lv, idx).store(UInt32(bitPattern: selfPid()), ordering: .releasing)
}

/// Release ownership of a slot on clean disconnect.
func livenessClearOwner(_ lv: UnsafeMutableRawPointer, _ bit: UInt32) {
    guard bit != 0 else { return }
    let idx = slotIndex(bit)
    ownerPid(lv, idx).store(0, ordering: .releasing)
    ownerTok(lv, idx).store(0, ordering: .relaxed)
}

/// Reap the dead receivers among `live`, clearing each via `disconnect(bit)`.
/// Lock-free (CAS-on-owner). Returns the reaped mask.
@discardableResult
func reapDeadReceivers(_ lv: UnsafeMutableRawPointer, _ live: UInt32, _ disconnect: (UInt32) -> Void) -> UInt32 {
    var reaped: UInt32 = 0
    var m = live
    while m != 0 {
        let bit = m & (~m &+ 1)   // lowest set bit
        m &= m &- 1
        let idx = slotIndex(bit)
        let pidAtom = ownerPid(lv, idx)
        let p = pidAtom.load(ordering: .acquiring)
        if p == 0 { continue }    // unknown owner — never false-reap
        let tok = ownerTok(lv, idx).load(ordering: .relaxed)
        if isProcessAlive(Int32(bitPattern: p), tok) { continue }
        // Only reap if the owner is still the dead PID we saw.
        let (won, _) = pidAtom.compareExchange(expected: p, desired: 0,
                                               ordering: .acquiringAndReleasing)
        if won {
            ownerTok(lv, idx).store(0, ordering: .relaxed)
            disconnect(bit)
            reaped |= bit
        }
    }
    return reaped
}

// MARK: - Sole-owner claim (a route's single-sender guard; xlang-channel-abi.md §2a)

/// `pid` of a sole-owner record whose claim is in flight: never taken over.
let ownerClaiming: Int32 = -1

/// Claim a sole-owner record (one `slot_owner` at `o`) for this process: free,
/// or held by a dead process. False when a live process (this one included)
/// holds it, or a claim is in flight. Byte-exact with C++ `claim_sole_owner`
/// (liveness.h): CAS the pid to `ownerClaiming` first, so no claimant can pair
/// the new pid with the previous holder's token; then the token, then the pid.
func claimSoleOwner(_ o: UnsafeMutableRawPointer) -> Bool {
    let pidAtom = ownerPid(o, 0), tokAtom = ownerTok(o, 0)
    let cur = Int32(bitPattern: pidAtom.load(ordering: .acquiring))
    if cur == ownerClaiming { return false }
    if cur != 0 && isProcessAlive(cur, tokAtom.load(ordering: .acquiring)) { return false }
    let (won, _) = pidAtom.compareExchange(expected: UInt32(bitPattern: cur),
                                           desired: UInt32(bitPattern: ownerClaiming),
                                           successOrdering: .acquiringAndReleasing,
                                           failureOrdering: .relaxed)
    guard won else { return false }
    tokAtom.store(startToken(selfPid()), ordering: .relaxed)
    pidAtom.store(UInt32(bitPattern: selfPid()), ordering: .releasing)
    return true
}

/// Release a sole-owner record this process holds (a clean shutdown).
func releaseSoleOwner(_ o: UnsafeMutableRawPointer) {
    let me = UInt32(bitPattern: selfPid())
    let pidAtom = ownerPid(o, 0)
    guard pidAtom.load(ordering: .acquiring) == me else { return }
    ownerTok(o, 0).store(0, ordering: .relaxed)
    _ = pidAtom.compareExchange(expected: me, desired: 0,
                                successOrdering: .releasing, failureOrdering: .relaxed)
}

/// Conformance probes over the sole-owner claim (scenario: conform).
public enum OwnerConform {
    /// The claim on a local record, through every state it can be found in. Must
    /// print exactly what the C++ reference (`xlang_ipc conform sole-owner`) prints.
    public static func soleOwner() -> [String] {
        // A pid no process can have (above every OS's pid limit): a dead holder.
        let deadPid: Int32 = 0x7fff_fffe
        let o = UnsafeMutableRawPointer.allocate(byteCount: livenessSlotStride, alignment: 8)
        defer { o.deallocate() }
        o.initializeMemory(as: UInt8.self, repeating: 0, count: livenessSlotStride)
        let me = selfPid(), myTok = startToken(me)
        var out: [String] = []
        func dump(_ step: String, _ ok: Bool?) {
            let pid = Int32(bitPattern: ownerPid(o, 0).load(ordering: .relaxed))
            let tok = ownerTok(o, 0).load(ordering: .relaxed)
            let p = (pid != 0 && pid == me) ? "self" : String(pid)
            let t = (tok != 0 && tok == myTok) ? "self" : String(tok)
            let k = ok.map { $0 ? "1" : "0" } ?? "-"
            out.append("step=\(step) ok=\(k) pid=\(p) tok=\(t)")
        }
        func set(_ pid: Int32, _ tok: UInt64) {
            ownerPid(o, 0).store(UInt32(bitPattern: pid), ordering: .relaxed)
            ownerTok(o, 0).store(tok, ordering: .relaxed)
        }
        dump("zeroed", nil)
        dump("claim-free", claimSoleOwner(o))
        dump("claim-held-by-self", claimSoleOwner(o))
        releaseSoleOwner(o)
        dump("release", nil)
        // A pre-owner-record binary set only the first byte: pid 1, always alive.
        set(0, 0)
        o.storeBytes(of: UInt8(1), as: UInt8.self)
        dump("claim-legacy-flag", claimSoleOwner(o))
        releaseSoleOwner(o)
        dump("release-not-owner", nil)
        set(ownerClaiming, 0)
        dump("claim-in-flight", claimSoleOwner(o))
        set(deadPid, 12345)
        dump("claim-dead-holder", claimSoleOwner(o))
        // This pid with another start token: the recorded holder is gone.
        set(me, myTok &+ 1)
        dump("claim-reused-pid", claimSoleOwner(o))
        return out
    }
}
