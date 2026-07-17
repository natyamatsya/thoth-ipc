// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Dead-connection reaper owner table (RFC:
// context/dead-connection-reaper-rfc.md), Swift side. **Byte-exact with
// cpp/libipc/src/libipc/liveness.h and rust/libipc/src/liveness.rs**
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
let livenessSlotStride = 16   // sizeof(slot_owner)
let livenessPidOffset = 0     // int32
let livenessTokOffset = 8     // uint64
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
