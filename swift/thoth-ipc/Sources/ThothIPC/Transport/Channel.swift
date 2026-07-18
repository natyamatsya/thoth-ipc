// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/include/libipc/ipc.h + ipc.cpp.
// IPC channels built on top of shared memory, condition variables, and
// a lock-free circular ring buffer.

import Darwin.POSIX
import Atomics

// MARK: - UnsafeAtomic helpers for in-shm fields
//
// AtomicRepresentation ordering params are @_semantics-constrained and cannot
// be passed through generic functions. Instead we use UnsafeAtomic, which
// wraps a raw pointer and exposes the full ordering-parameterised API.

@inline(__always)
private func ua32(_ field: inout UInt32.AtomicRepresentation) -> UnsafeAtomic<UInt32> {
    UnsafeAtomic(at: withUnsafeMutablePointer(to: &field) {
        $0.withMemoryRebound(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1) { $0 }
    })
}

@inline(__always)
private func ua64(_ field: inout UInt64.AtomicRepresentation) -> UnsafeAtomic<UInt64> {
    UnsafeAtomic(at: withUnsafeMutablePointer(to: &field) {
        $0.withMemoryRebound(to: UnsafeAtomic<UInt64>.Storage.self, capacity: 1) { $0 }
    })
}

// MARK: - Constants

// Transport ABI constants — sourced from the generated `ABI` namespace
// (abi/abi.json → Sources/ThothIPC/Generated/ABI.swift). A layout/mask change in
// the spec propagates here by regeneration rather than hand-editing.
let dataLength: Int  = ABI.data_length
let ringSize: Int    = ABI.ring_size
let epMask: UInt64 = ABI.route_ep_mask
let epIncr: UInt64 = ABI.route_ep_incr
private let spinCount: UInt32 = 32

// MARK: - Ring slot (byte-exact with C++ broadcast elem_t<80,8>)
//
// { data_[80]; rc_ } = 88 bytes. `data_` holds a msg_t<64,8>:
//   cc_id_@0 (u32), id_@4 (u32), remain_@8 (i32), storage_@12 (u8), payload@16 (64).
// Accessed via raw offsets (Swift struct layout is not guaranteed C-compatible).
let offBlock   = ABI.ring_header_size   // C++ block_ offset (after conn_head_base + head_)
let elemStride = ABI.route_elem_size    // sizeof(elem_t)
let elemRcOff  = ABI.route_elem_rc_off  // rc_ within a slot
let msgCcId = ABI.msg_t_cc_id_off, msgId = ABI.msg_t_id_off, msgRemain = ABI.msg_t_remain_off,
    msgStorage = ABI.msg_t_storage_off, msgPayload = ABI.msg_t_payload_off

@inline(__always) func slotBase(_ ringBase: UnsafeMutableRawPointer, _ idx: UInt8) -> UnsafeMutableRawPointer {
    ringBase.advanced(by: offBlock + Int(idx) * elemStride)
}
@inline(__always) func slotRc(_ sb: UnsafeMutableRawPointer) -> UnsafeAtomic<UInt64> {
    UnsafeAtomic(at: sb.advanced(by: elemRcOff).assumingMemoryBound(to: UnsafeAtomic<UInt64>.Storage.self))
}
@inline(__always) func writeMsgHeader(_ sb: UnsafeMutableRawPointer, ccId: UInt32, id: UInt32, remain: Int32, storage: Bool) {
    sb.storeBytes(of: ccId,   toByteOffset: msgCcId,   as: UInt32.self)
    sb.storeBytes(of: id,     toByteOffset: msgId,     as: UInt32.self)
    sb.storeBytes(of: remain, toByteOffset: msgRemain, as: Int32.self)
    sb.storeBytes(of: UInt8(storage ? 1 : 0), toByteOffset: msgStorage, as: UInt8.self)
}
@inline(__always) func readMsgHeader(_ sb: UnsafeMutableRawPointer) -> (ccId: UInt32, id: UInt32, remain: Int32, storage: Bool) {
    (sb.loadUnaligned(fromByteOffset: msgCcId,   as: UInt32.self),
     sb.loadUnaligned(fromByteOffset: msgId,     as: UInt32.self),
     sb.loadUnaligned(fromByteOffset: msgRemain, as: Int32.self),
     sb.loadUnaligned(fromByteOffset: msgStorage, as: UInt8.self) != 0)
}

// MARK: - Multi-writer channel ring (C++ prod_cons_impl<multi,multi,broadcast>)
//
// A channel slot is 96 bytes: { data_[80]; rc_ (u64)@80; f_ct_ (u64)@88 }. The
// header reuses writeCursor@64 as the shared commit index ct_. Readers detect a
// committed slot via `f_ct_ == ~ct`; the `rc_` word packs a per-reader bitmask
// (low 32) + an internal read-generation (bits 32..55) + an epoch (top byte).
// Byte-exact with the Rust/Zig channel ports. See
// context/xlang-channel-multiwriter-rfc.md.
let channelElemStride = ABI.channel_elem_size
let channelElemFctOff = ABI.channel_elem_f_ct_off
let channelRingShmSizeBytes = ABI.channel_ring_size

let chRcMask: UInt64 = ABI.chan_rc_mask   // low 32: per-reader "needs to read" bitmask
let chEpMask: UInt64 = ABI.chan_ep_mask   // low 56: rc bits + internal read-generation
let chEpIncr: UInt64 = ABI.chan_ep_incr   // epoch increment (top byte)
let chIcMask: UInt64 = ABI.chan_ic_mask   // invert-carry mask
let chIcIncr: UInt64 = ABI.chan_ic_incr   // internal read-generation increment (bits 32..)

@inline(__always) func incRc(_ rc: UInt64) -> UInt64 {
    (rc & chIcMask) | ((rc &+ chIcIncr) & ~chIcMask)
}
@inline(__always) func incMask(_ rc: UInt64) -> UInt64 { incRc(rc) & ~chRcMask }

@inline(__always) func channelSlotBase(_ ringBase: UnsafeMutableRawPointer, _ idx: UInt8) -> UnsafeMutableRawPointer {
    ringBase.advanced(by: offBlock + Int(idx) * channelElemStride)
}
// rc_ lives at the same +80 offset as a route slot; f_ct_ is channel-only at +88.
@inline(__always) func slotFct(_ sb: UnsafeMutableRawPointer) -> UnsafeAtomic<UInt64> {
    UnsafeAtomic(at: sb.advanced(by: channelElemFctOff).assumingMemoryBound(to: UnsafeAtomic<UInt64>.Storage.self))
}

// Ring header — byte-exact with the C++ elem_array head (conn_head_base + the
// cache-line-aligned prod_cons head_). See context/xlang-channel-abi.md.
//   0 connections  @0   == C++ conn_head_base::cc_
//   4 lc           @4   == C++ conn_head_base::lc_ (os_unfair_lock)
//   8 constructed  @8   == C++ conn_head_base::constructed_ (DCLP flag)
//  64 writeCursor  @64  == C++ head_.wt_   (alignas cache line)
// 128 epoch        @128 == C++ head_.epoch_
// 136 senderCount  @136 Swift-internal (C++ padding)
// Explicit padding forces the offsets (Swift alignas changes offset via padding,
// not a sized wrapper). Guarded at runtime by assertHeaderLayout().
@_alignment(8)
struct RingHeader {
    var connections: UInt32.AtomicRepresentation = .init(0)   // @0
    var lc: os_unfair_lock = os_unfair_lock()                 // @4
    var constructed: UInt8 = 0                                // @8
    var _padA: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var writeCursor: UInt32.AtomicRepresentation = .init(0)   // @64
    var _padB: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var epoch: UInt64.AtomicRepresentation = .init(0)         // @128
    var senderCount: UInt32.AtomicRepresentation = .init(0)   // @136
    var _padC: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

let ringHeaderSize = MemoryLayout<RingHeader>.size
let ringShmSizeBytes = ABI.route_ring_size  // sizeof(C++ elem_array<broadcast,80,8>) on Apple arm64
func ringShmSize() -> Int { ringShmSizeBytes }

// Ring element alignment folded into the shm name: C++ AlignSize =
// min(dataLength, alignof(max_align_t)) = 8 on Apple arm64 (16 on x86-64).
let ringAlign = 8

// Byte-exact object names (C++ make_public_abi_prefix: prefix + "__THOTH_SHM__" + TAG + ...).
@inline(__always) func fullPrefix(_ prefix: String) -> String { "\(prefix)__THOTH_SHM__" }
func ringName(_ prefix: String, _ name: String) -> String {
    "\(fullPrefix(prefix))QU_CONN__\(name)__\(dataLength)__\(ringAlign)"
}
// cc_id endpoint-identity counter is PREFIX-GLOBAL (no channel name), matching
// C++ cc_acc — else a C++ sender and a Swift receiver collide on cc_id.
func ccIdName(_ prefix: String) -> String { "\(fullPrefix(prefix))CA_CONN__" }

/// C++ conn_head_base::init() DCLP via os_unfair_lock — so a C++ peer that sees
/// constructed_ == 0 does not re-zero the header and wipe our connection bit.
func initHeader(_ hdr: UnsafeMutablePointer<RingHeader>) {
    if hdr.pointee.constructed != 0 { return }
    os_unfair_lock_lock(&hdr.pointee.lc)
    if hdr.pointee.constructed == 0 {
        ua32(&hdr.pointee.connections).store(0, ordering: .relaxed)
        hdr.pointee.constructed = 1
    }
    os_unfair_lock_unlock(&hdr.pointee.lc)
}

/// Guard the header layout against C++ drift (offsets from the spec).
func assertHeaderLayout() {
    // Verify the Swift struct matches the generated ABI layout.
    assert(MemoryLayout<RingHeader>.size == ABI.ring_header_size)
    assert(MemoryLayout<RingHeader>.offset(of: \.connections)! == ABI.ring_header_cc_off)
    assert(MemoryLayout<RingHeader>.offset(of: \.lc)! == ABI.ring_header_lc_off)
    assert(MemoryLayout<RingHeader>.offset(of: \.constructed)! == ABI.ring_header_constructed_off)
    assert(MemoryLayout<RingHeader>.offset(of: \.writeCursor)! == ABI.ring_header_cursor_off)
    assert(MemoryLayout<RingHeader>.offset(of: \.epoch)! == ABI.ring_header_epoch_off)
}

// MARK: - Mode

public enum Mode: Sendable { case sender, receiver }

// MARK: - ChanInner

final class ChunkShmEntry: @unchecked Sendable {
    let shm: ShmHandle

    init(shm: consuming ShmHandle) {
        self.shm = shm
    }
}

final class ChanInner: @unchecked Sendable {
    let name: String
    let prefix: String
    let chunkPrefix: String
    let mode: Mode
    let ringShm:  ShmHandle
    let ccIdShm:  ShmHandle
    let livenessShm: ShmHandle   // LV_CONN__ owner table (dead-connection reaper)
    let notifySource = NotifySource() // Layer 1: post on send
    let notifySink = NotifySink()     // Layer 1: readiness fd (registered lazily)
    var chunkShms: [Int: ChunkShmEntry] = [:]
    var connId:     UInt32
    var ccId:       UInt32
    var readCursor: UInt32
    var sendSeq: UInt32 = 0                        // route: per-sender msg_t.id_ counter
    let multi: Bool                                // multi-writer (channel) vs single-writer (route)
    let acIdShm: ShmHandle?                        // channel: shared AC_CONN__ msg-id counter (owns the mapping)
    let acIdPtr: UnsafeMutableRawPointer?          // cached base of acIdShm (~Copyable can't be re-read from a class)
    var recvCache: [UInt32: (Int, [UInt8])] = [:]  // id_ -> (fill offset, buffer)
    let wtWaiter: Waiter
    let rdWaiter: Waiter
    let ccWaiter: Waiter
    var disconnected: Bool = false

    static func open(prefix: String, name: String, mode: Mode, multi: Bool = false) async throws(IpcError) -> ChanInner {
        let fp = fullPrefix(prefix)
        let chunkPrefix = "\(fp)\(name)_"
        // Channel and route share the ring NAME but not the size: the multi-writer
        // ring has 96-byte slots (24832 B) vs the route's 88 (22784 B).
        let ringShm  = try ShmHandle.acquire(name: ringName(prefix, name), size: multi ? channelRingShmSizeBytes : ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: ccIdName(prefix), size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
        // Multi-writer channels draw msg_t.id_ from a SHARED per-channel counter
        // (C++ AC_CONN__<name>) so concurrent writers never collide in a receiver's
        // reassembly cache. Route uses a process-local sendSeq.
        let acIdShm: ShmHandle?
        let acIdPtr: UnsafeMutableRawPointer?
        if multi {
            let h = try ShmHandle.acquire(name: "\(fp)AC_CONN__\(name)", size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
            acIdPtr = h.ptr   // borrow-read before the consume-move below
            acIdShm = consume h
        } else {
            acIdShm = nil; acIdPtr = nil
        }
        let livenessShm = try ShmHandle.acquire(name: livenessName(prefix, name), size: livenessShmSizeBytes, mode: .createOrOpen)
        let wtWaiter = try await Waiter.open(name: "\(fp)WT_CONN__\(name)")
        let rdWaiter = try await Waiter.open(name: "\(fp)RD_CONN__\(name)")
        let ccWaiter = try await Waiter.open(name: "\(fp)CC_CONN__\(name)")

        // Allocate unique endpoint identity from shared counter.
        let ccIdAtom = UnsafeAtomic<UInt32>(at: ccIdShm.ptr.withMemoryRebound(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1) { $0 })
        var ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        if ccId == 0 {
            ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        }

        let hdr = ringShm.ptr.assumingMemoryBound(to: RingHeader.self)
        assertHeaderLayout()
        initHeader(hdr)  // byte-exact DCLP so a C++ peer does not re-zero the header
        var connId: UInt32 = 0
        var readCursor: UInt32 = 0

        switch mode {
        case .sender:
            _ = ua32(&hdr.pointee.senderCount).loadThenWrappingIncrement(by: 1, ordering: .relaxed)

        case .receiver:
            // Reclaim slots held by dead peers before claiming one (byte-exact
            // with C++/Rust reap-on-connect).
            let lv = livenessShm.ptr
            let liveMask = ua32(&hdr.pointee.connections).load(ordering: .acquiring)
            reapDeadReceivers(lv, liveMask) { bit in
                _ = ua32(&hdr.pointee.connections).loadThenBitwiseAnd(with: ~bit, ordering: .acquiringAndReleasing)
            }
            var k: UInt32 = 0
            while true {
                let curr = ua32(&hdr.pointee.connections).load(ordering: .acquiring)
                let next = curr | curr.addingReportingOverflow(1).partialValue
                if next == curr { throw .osError(EAGAIN) }
                let (exchanged, _) = ua32(&hdr.pointee.connections).weakCompareExchange(
                    expected: curr, desired: next, successOrdering: .releasing, failureOrdering: .relaxed)
                if exchanged { connId = next ^ curr; break }
                await adaptiveYield(&k)
            }
            livenessSetOwner(lv, connId)
            readCursor = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
            try? ccWaiter.broadcast()
        }

        return ChanInner(name: name, prefix: prefix, chunkPrefix: chunkPrefix, mode: mode,
                         ringShm: ringShm, ccIdShm: ccIdShm, livenessShm: livenessShm,
                         connId: connId, ccId: ccId, readCursor: readCursor, multi: multi, acIdShm: acIdShm, acIdPtr: acIdPtr,
                         wtWaiter: wtWaiter, rdWaiter: rdWaiter, ccWaiter: ccWaiter)
    }

    static func openSync(prefix: String, name: String, mode: Mode, multi: Bool = false) throws(IpcError) -> ChanInner {
        let fp = fullPrefix(prefix)
        let chunkPrefix = "\(fp)\(name)_"
        let ringShm  = try ShmHandle.acquire(name: ringName(prefix, name), size: multi ? channelRingShmSizeBytes : ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: ccIdName(prefix), size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
        let acIdShm: ShmHandle?
        let acIdPtr: UnsafeMutableRawPointer?
        if multi {
            let h = try ShmHandle.acquire(name: "\(fp)AC_CONN__\(name)", size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
            acIdPtr = h.ptr   // borrow-read before the consume-move below
            acIdShm = consume h
        } else {
            acIdShm = nil; acIdPtr = nil
        }
        let livenessShm = try ShmHandle.acquire(name: livenessName(prefix, name), size: livenessShmSizeBytes, mode: .createOrOpen)
        let wtWaiter = try Waiter.openSync(name: "\(fp)WT_CONN__\(name)")
        let rdWaiter = try Waiter.openSync(name: "\(fp)RD_CONN__\(name)")
        let ccWaiter = try Waiter.openSync(name: "\(fp)CC_CONN__\(name)")

        let ccIdAtom = UnsafeAtomic<UInt32>(at: ccIdShm.ptr.withMemoryRebound(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1) { $0 })
        var ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        if ccId == 0 {
            ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        }

        let hdr = ringShm.ptr.assumingMemoryBound(to: RingHeader.self)
        assertHeaderLayout()
        initHeader(hdr)  // byte-exact DCLP so a C++ peer does not re-zero the header
        var connId: UInt32 = 0
        var readCursor: UInt32 = 0

        switch mode {
        case .sender:
            _ = ua32(&hdr.pointee.senderCount).loadThenWrappingIncrement(by: 1, ordering: .relaxed)
        case .receiver:
            let lv = livenessShm.ptr
            let liveMask = ua32(&hdr.pointee.connections).load(ordering: .acquiring)
            reapDeadReceivers(lv, liveMask) { bit in
                _ = ua32(&hdr.pointee.connections).loadThenBitwiseAnd(with: ~bit, ordering: .acquiringAndReleasing)
            }
            var k: UInt32 = 0
            while true {
                let curr = ua32(&hdr.pointee.connections).load(ordering: .acquiring)
                let next = curr | curr.addingReportingOverflow(1).partialValue
                if next == curr { throw .osError(EAGAIN) }
                let (exchanged, _) = ua32(&hdr.pointee.connections).weakCompareExchange(
                    expected: curr, desired: next, successOrdering: .releasing, failureOrdering: .relaxed)
                if exchanged { connId = next ^ curr; break }
                k &+= 1; if k < 16 { } else if k < 64 { sched_yield() } else {
                    var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000); nanosleep(&ts, nil)
                }
            }
            livenessSetOwner(lv, connId)
            readCursor = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
            try? ccWaiter.broadcast()
        }

        return ChanInner(name: name, prefix: prefix, chunkPrefix: chunkPrefix, mode: mode,
                         ringShm: ringShm, ccIdShm: ccIdShm, livenessShm: livenessShm,
                         connId: connId, ccId: ccId, readCursor: readCursor, multi: multi, acIdShm: acIdShm, acIdPtr: acIdPtr,
                         wtWaiter: wtWaiter, rdWaiter: rdWaiter, ccWaiter: ccWaiter)
    }

    init(name: String, prefix: String, chunkPrefix: String, mode: Mode,
         ringShm: consuming ShmHandle, ccIdShm: consuming ShmHandle, livenessShm: consuming ShmHandle,
         connId: UInt32, ccId: UInt32, readCursor: UInt32, multi: Bool,
         acIdShm: consuming ShmHandle?, acIdPtr: UnsafeMutableRawPointer?,
         wtWaiter: consuming Waiter, rdWaiter: consuming Waiter, ccWaiter: consuming Waiter) {
        self.name = name; self.prefix = prefix; self.chunkPrefix = chunkPrefix; self.mode = mode
        self.ringShm = ringShm; self.ccIdShm = ccIdShm; self.livenessShm = livenessShm
        self.connId = connId; self.ccId = ccId; self.readCursor = readCursor
        self.multi = multi; self.acIdShm = acIdShm; self.acIdPtr = acIdPtr
        self.wtWaiter = wtWaiter; self.rdWaiter = rdWaiter; self.ccWaiter = ccWaiter
    }

    var hdrPtr: UnsafeMutablePointer<RingHeader> {
        ringShm.ptr.assumingMemoryBound(to: RingHeader.self)
    }
    var recvCount: Int {
        Int(ua32(&hdrPtr.pointee.connections).load(ordering: .acquiring).nonzeroBitCount)
    }

    /// Layer 1: this receiver's readiness fd (or -1), woken on every matching
    /// enqueue (including from a C++/Rust sender). Registered lazily on first call
    /// so the blocking recv path stays zero-cost. Byte-exact with C++
    /// `native_wait_handle()`.
    func nativeWaitHandle() -> Int32 {
        guard mode == .receiver else { return -1 }
        if !notifySink.valid { notifySink.open(prefix, name) }
        return notifySink.valid ? notifySink.fd : -1
    }

    /// Drain pending readiness tokens after the fd signalled (level-triggered).
    func drainWaitHandle() { notifySink.drain() }

    func withChunkShm<R>(chunkSize: Int, _ body: (borrowing ShmHandle) -> R) -> R? {
        if chunkShms[chunkSize] == nil {
            guard let shm = try? openChunkShm(prefix: prefix, chunkSize: chunkSize) else { return nil }
            chunkShms[chunkSize] = ChunkShmEntry(shm: shm)
        }
        guard let entry = chunkShms[chunkSize] else { return nil }
        return body(entry.shm)
    }

    var valid: Bool { !disconnected }
    func disconnect() {
        guard !disconnected else { return }
        switch mode {
        case .sender:
            _ = ua32(&hdrPtr.pointee.senderCount).loadThenWrappingDecrement(by: 1, ordering: .relaxed)
        case .receiver:
            _ = ua32(&hdrPtr.pointee.connections).loadThenBitwiseAnd(with: ~connId, ordering: .acquiringAndReleasing)
            livenessClearOwner(livenessShm.ptr, connId)
            notifySink.close()
            try? wtWaiter.broadcast()
        }
        disconnected = true
    }
    deinit { disconnect() }
}

// MARK: - waitFor helper

func waitFor(waiter: borrowing Waiter, pred: () -> Bool, timeout: Duration?) throws(IpcError) -> Bool {
    if let t = timeout, t <= .zero { return !pred() }
    let deadline = timeout.map { ContinuousClock.now + $0 }
    var k: UInt32 = 0
    while pred() {
        if k < spinCount {
            sched_yield()
            k += 1
        } else {
            let remaining = deadline.map { $0 - ContinuousClock.now }
            if let r = remaining, r <= .zero { return false }
            let ok = try waiter.waitIf(pred, timeout: remaining)
            if !ok { return false }
            k = 0
        }
    }
    return true
}

// MARK: - Send / Recv (byte-exact msg_t framing, mirroring the Rust port)

extension ChanInner {

    /// Send `data`; fragment into msg_t records (C++ ipc.cpp send()): each carries
    /// remain_ = size - offset - dataLength (<=0 on the last). No chunk-storage
    /// send path — Rust/C++ receivers reassemble fragments, so >64B still crosses.
    func send(data: [UInt8], timeout: Duration) throws(IpcError) -> Bool {
        guard !data.isEmpty else { return false }
        guard mode == .sender else { throw .osError(EPERM) }
        guard ua32(&hdrPtr.pointee.connections).load(ordering: .relaxed) != 0 else { return false }
        let size = data.count
        // Multi-writer: shared AC_CONN__ counter (concurrent writers must not
        // collide in a receiver's reassembly cache); route: process-local sendSeq.
        let msgId: UInt32
        if multi, let acPtr = acIdPtr {
            let atom = UnsafeAtomic<UInt32>(at: acPtr.withMemoryRebound(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1) { $0 })
            msgId = atom.loadThenWrappingIncrement(by: 1, ordering: .relaxed)
        } else {
            msgId = sendSeq; sendSeq &+= 1
        }
        let full = size / dataLength
        var offset = 0
        for _ in 0..<full {
            let remain = Int32(size) - Int32(offset) - Int32(dataLength)
            if !(try pushFragment(msgId: msgId, remain: remain, payload: Array(data[offset..<offset + dataLength]), timeout: timeout)) { return false }
            offset += dataLength
        }
        let tail = size - offset
        if tail > 0 {
            let remain = Int32(tail) - Int32(dataLength)
            if !(try pushFragment(msgId: msgId, remain: remain, payload: Array(data[offset...]), timeout: timeout)) { return false }
        }
        // Layer 1: wake any async receiver parked on the readiness fd (byte-exact
        // with C++/Rust notify_signal). libnotify is multicast; a no-op if unlistened.
        notifySource.signal(prefix, name)
        return true
    }

    /// Claim the next ring slot (C++ prod_cons broadcast push/force_push) and write
    /// one msg_t fragment, then advance wt_ and wake receivers.
    func pushFragment(msgId: UInt32, remain: Int32, payload: [UInt8], timeout: Duration) throws(IpcError) -> Bool {
        if multi { return try pushFragmentMulti(msgId: msgId, remain: remain, payload: payload, timeout: timeout) }
        let hdr = hdrPtr
        let ringBase = ringShm.ptr
        var claimedWt: UInt32 = 0
        var yk: UInt32 = 0
        claimLoop: while true {
            let cc = UInt64(ua32(&hdr.pointee.connections).load(ordering: .relaxed))
            guard cc != 0 else { return false }
            let epoch = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
            let wt = ua32(&hdr.pointee.writeCursor).load(ordering: .relaxed)
            let sb = slotBase(ringBase, UInt8(wt & 0xFF))
            let curRc = slotRc(sb).load(ordering: .acquiring)
            let remCc = curRc & epMask
            if (cc & remCc) != 0 && (curRc & ~epMask) == epoch {
                let ok = try waitFor(waiter: wtWaiter, pred: {
                    let s = slotBase(ringBase, UInt8(wt & 0xFF))
                    let rc = slotRc(s).load(ordering: .acquiring)
                    let ep = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
                    return (cc & (rc & epMask)) != 0 && (rc & ~epMask) == ep
                }, timeout: timeout)
                if ok { continue claimLoop }
                _ = ua64(&hdr.pointee.epoch).loadThenWrappingIncrement(by: epIncr, ordering: .acquiringAndReleasing)
                let rem2 = slotRc(sb).load(ordering: .acquiring) & epMask
                if rem2 != 0 {
                    let mask = ~UInt32(truncatingIfNeeded: rem2)
                    let newCc = ua32(&hdr.pointee.connections).loadThenBitwiseAnd(with: mask, ordering: .acquiringAndReleasing) & mask
                    if newCc == 0 { return false }
                    _ = slotRc(sb).loadThenBitwiseAnd(with: ~rem2, ordering: .acquiringAndReleasing)
                }
                continue claimLoop
            }
            let (ok, _) = slotRc(sb).weakCompareExchange(expected: curRc, desired: epoch | cc, successOrdering: .releasing, failureOrdering: .relaxed)
            if ok { claimedWt = wt; break claimLoop }
            adaptiveYieldSync(&yk)
        }
        let sb = slotBase(ringBase, UInt8(claimedWt & 0xFF))
        writeMsgHeader(sb, ccId: ccId, id: msgId, remain: remain, storage: false)
        let dst = sb.advanced(by: msgPayload)
        payload.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        _ = ua32(&hdr.pointee.writeCursor).loadThenWrappingIncrement(by: 1, ordering: .releasing)
        try? rdWaiter.broadcast()
        return true
    }

    /// Receive one message; reassemble msg_t fragments by id_ (C++ ipc.cpp recv()).
    /// Large (storage_) messages are read from chunk shm and recycled.
    func recv(timeout: Duration?) throws(IpcError) -> IpcBuffer {
        if multi { return try recvMulti(timeout: timeout) }
        guard mode == .receiver else { throw .osError(EPERM) }
        let deadline = timeout.map { ContinuousClock.now + $0 }
        let ringBase = ringShm.ptr
        while true {
            let hdr = hdrPtr
            let wc = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
            if wc == readCursor {
                let cur = readCursor
                let remaining = deadline.map { $0 - ContinuousClock.now }
                if let r = remaining, r <= .zero { return IpcBuffer() }
                let ok = try waitFor(waiter: rdWaiter, pred: {
                    let h = ringBase.assumingMemoryBound(to: RingHeader.self)
                    return ua32(&h.pointee.writeCursor).load(ordering: .acquiring) == cur
                }, timeout: remaining)
                if !ok { return IpcBuffer() }
                continue
            }

            let idx = UInt8(readCursor & 0xFF)
            let sb = slotBase(ringBase, idx)
            let (ccIdVal, id, remain, storage) = readMsgHeader(sb)
            let isSelf = ccIdVal == ccId
            let rSize = Int32(dataLength) + remain
            let keep = !isSelf && rSize > 0

            // Read out of the slot BEFORE releasing it.
            var storageId: Int32? = nil
            var frag: [UInt8]? = nil
            if keep {
                if storage {
                    storageId = sb.loadUnaligned(fromByteOffset: msgPayload, as: Int32.self)
                } else {
                    let n = remain <= 0 ? Int(rSize) : dataLength
                    frag = Array(UnsafeRawBufferPointer(start: sb.advanced(by: msgPayload), count: n))
                }
            }

            // Release our rc_ bit (preserve epoch), advance, wake senders — always.
            var k: UInt32 = 0
            while true {
                let curRc = slotRc(sb).load(ordering: .acquiring)
                if (curRc & epMask) == 0 { break }
                let (ok, _) = slotRc(sb).weakCompareExchange(expected: curRc, desired: curRc & ~UInt64(connId), successOrdering: .releasing, failureOrdering: .relaxed)
                if ok { break }
                adaptiveYieldSync(&k)
            }
            try? wtWaiter.broadcast()
            readCursor = readCursor &+ 1

            if let out = assembleMessage(keep: keep, id: id, remain: remain, rSize: rSize, storageId: storageId, frag: frag) {
                return out
            }
        }
    }

    /// Shared tail of `recv` / `recvMulti`: after a slot has been decoded and
    /// released, either read a large message from chunk storage or reassemble
    /// inline fragments by id_. Returns the completed message, or nil to keep
    /// reading (self / malformed slot, unavailable chunk shm, or a still-
    /// incomplete multi-fragment message). Byte-exact with C++ ipc.cpp recv()
    /// regardless of the single- or multi-writer ring.
    private func assembleMessage(keep: Bool, id: UInt32, remain: Int32, rSize: Int32,
                                 storageId: Int32?, frag: [UInt8]?) -> IpcBuffer? {
        guard keep else { return nil }  // self-message / malformed — slot already released
        // Large message via chunk storage (single msg_t — no reassembly).
        if let sid = storageId {
            let msgSize = Int(rSize)
            let chunkSize = calcChunkSize(msgSize)
            let out = withChunkShm(chunkSize: chunkSize) { shm -> [UInt8] in
                defer { recycleStorage(shm: shm, chunkSize: chunkSize, id: sid, connId: connId) }
                guard let ptr = findStorage(shm: shm, chunkSize: chunkSize, id: sid) else { return [] }
                return Array(UnsafeRawBufferPointer(start: ptr, count: msgSize))
            }
            if let b = out, !b.isEmpty { return IpcBuffer(bytes: b) }
            return nil  // chunk shm unavailable
        }
        // Inline fragment reassembly by id_.
        let f = frag!
        if var entry = recvCache[id] {
            recvCache[id] = nil
            entry.1.replaceSubrange(entry.0 ..< entry.0 + f.count, with: f)
            if remain <= 0 { return IpcBuffer(bytes: entry.1) }  // last fragment
            recvCache[id] = (entry.0 + f.count, entry.1)
            return nil
        } else if remain <= 0 {
            return IpcBuffer(bytes: f)  // single fragment
        } else {
            var buf = [UInt8](repeating: 0, count: Int(rSize))
            buf.replaceSubrange(0 ..< f.count, with: f)
            recvCache[id] = (f.count, buf)
            return nil
        }
    }

    // MARK: - Multi-writer (channel) push / recv

    /// Multi-writer push (C++ prod_cons_impl<multi,multi,broadcast>): claim the
    /// `ct_` commit slot via a CAS on `rc_` + an epoch re-validate, advance `ct_`,
    /// write the fragment, then publish `f_ct_ = ~ct` for readers. Busy-polls with
    /// a deadline while the target slot is still owed a read / not yet drained.
    func pushFragmentMulti(msgId: UInt32, remain: Int32, payload: [UInt8], timeout: Duration) throws(IpcError) -> Bool {
        let hdr = hdrPtr
        let ringBase = ringShm.ptr
        let deadline = ContinuousClock.now + timeout
        var epoch = ua64(&hdr.pointee.epoch).load(ordering: .acquiring)
        var claimedCt: UInt32 = 0
        var yk: UInt32 = 0
        claimLoop: while true {
            let cc = UInt64(ua32(&hdr.pointee.connections).load(ordering: .relaxed))
            guard cc != 0 else { return false }
            let curCt = ua32(&hdr.pointee.writeCursor).load(ordering: .relaxed) // commit index (ct_)
            let sb = channelSlotBase(ringBase, UInt8(curCt & 0xFF))
            let curRc = slotRc(sb).load(ordering: .relaxed)
            let remCc = curRc & chRcMask
            if (cc & remCc) != 0 && (curRc & ~chEpMask) == epoch {
                // Slot still held by a live reader in the current epoch.
                if ContinuousClock.now >= deadline { return false }
                adaptiveYieldSync(&yk)
                continue claimLoop
            } else if remCc == 0 {
                let curFl = slotFct(sb).load(ordering: .acquiring)
                if curFl != UInt64(curCt) && curFl != 0 {
                    // Previous lap's data not yet drained by the reader.
                    if ContinuousClock.now >= deadline { return false }
                    adaptiveYieldSync(&yk)
                    continue claimLoop
                }
            }
            let desired = incMask(epoch | (curRc & chEpMask)) | cc
            let (rcOk, _) = slotRc(sb).weakCompareExchange(expected: curRc, desired: desired, successOrdering: .relaxed, failureOrdering: .relaxed)
            if rcOk {
                // Won the slot; re-validate the epoch has not moved. An acquire
                // load is equivalent to the old self-CAS (a no-op store publishes
                // nothing) without the weak-CAS spurious-failure retry.
                let now = ua64(&hdr.pointee.epoch).load(ordering: .acquiring)
                if now == epoch { claimedCt = curCt; break claimLoop }
                epoch = now
            }
            adaptiveYieldSync(&yk)
        }
        ua32(&hdr.pointee.writeCursor).store(claimedCt &+ 1, ordering: .releasing) // advance ct_
        let sb = channelSlotBase(ringBase, UInt8(claimedCt & 0xFF))
        writeMsgHeader(sb, ccId: ccId, id: msgId, remain: remain, storage: false)
        let dst = sb.advanced(by: msgPayload)
        payload.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        slotFct(sb).store(~UInt64(claimedCt), ordering: .releasing) // publish commit flag
        try? rdWaiter.broadcast()
        return true
    }

    /// Multi-writer recv: emptiness via `f_ct_ == ~cur`, the channel `rc_`/`f_ct_`
    /// slot-free protocol, then the same fragment reassembly / chunk-storage decode
    /// as route `recv()`.
    func recvMulti(timeout: Duration?) throws(IpcError) -> IpcBuffer {
        guard mode == .receiver else { throw .osError(EPERM) }
        let deadline = timeout.map { ContinuousClock.now + $0 }
        let ringBase = ringShm.ptr
        var yk: UInt32 = 0
        while true {
            let cur = readCursor
            let sb = channelSlotBase(ringBase, UInt8(cur & 0xFF))
            if slotFct(sb).load(ordering: .acquiring) != ~UInt64(cur) {
                // Empty — the sender has not published this cursor's commit flag.
                if let dl = deadline, ContinuousClock.now >= dl { return IpcBuffer() }
                adaptiveYieldSync(&yk)
                continue
            }
            yk = 0

            let (ccIdVal, id, remain, storage) = readMsgHeader(sb)
            let isSelf = ccIdVal == ccId
            let rSize = Int32(dataLength) + remain
            let keep = !isSelf && rSize > 0

            var storageId: Int32? = nil
            var frag: [UInt8]? = nil
            if keep {
                if storage {
                    storageId = sb.loadUnaligned(fromByteOffset: msgPayload, as: Int32.self)
                } else {
                    let n = remain <= 0 ? Int(rSize) : dataLength
                    frag = Array(UnsafeRawBufferPointer(start: sb.advanced(by: msgPayload), count: n))
                }
            }

            // Clear our rc_ bit (channel incRc protocol); the last reader frees the
            // slot by setting f_ct_ to the next-lap ct value (cur + RING_SIZE).
            let curPost = cur &+ 1
            let freeFlag = UInt64(curPost) + UInt64(ringSize - 1)
            var k: UInt32 = 0
            while true {
                let curRc = slotRc(sb).load(ordering: .acquiring)
                if (curRc & chRcMask) == 0 {
                    slotFct(sb).store(freeFlag, ordering: .releasing)
                    break
                }
                let nxt = incRc(curRc) & ~UInt64(connId)
                if (nxt & chRcMask) == 0 {
                    slotFct(sb).store(freeFlag, ordering: .releasing)
                }
                let (ok, _) = slotRc(sb).weakCompareExchange(expected: curRc, desired: nxt, successOrdering: .releasing, failureOrdering: .relaxed)
                if ok { break }
                adaptiveYieldSync(&k)
            }
            readCursor = curPost
            try? wtWaiter.broadcast()

            if let out = assembleMessage(keep: keep, id: id, remain: remain, rSize: rSize, storageId: storageId, frag: frag) {
                return out
            }
        }
    }

    func tryRecv() throws(IpcError) -> IpcBuffer { try recv(timeout: Duration.zero) }
}

// MARK: - waitForRecv

extension ChanInner {
    func waitForRecv(count: Int, timeout: Duration?) throws(IpcError) -> Bool {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while true {
            if recvCount >= count { return true }
            let remaining = deadline.map { $0 - ContinuousClock.now }
            if let r = remaining, r <= .zero { return false }
            let ok = try ccWaiter.waitIf({ self.recvCount < count }, timeout: remaining)
            if !ok { return false }
            if recvCount >= count { return true }
        }
    }
}
