// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
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

let dataLength: Int  = 64
let ringSize: Int    = 256
let epMask: UInt64 = 0x0000_0000_FFFF_FFFF
let epIncr: UInt64 = 0x0000_0001_0000_0000
private let spinCount: UInt32 = 32

// MARK: - Ring slot (byte-exact with C++ broadcast elem_t<80,8>)
//
// { data_[80]; rc_ } = 88 bytes. `data_` holds a msg_t<64,8>:
//   cc_id_@0 (u32), id_@4 (u32), remain_@8 (i32), storage_@12 (u8), payload@16 (64).
// Accessed via raw offsets (Swift struct layout is not guaranteed C-compatible).
let offBlock   = 192   // C++ block_ offset (after conn_head_base + head_)
let elemStride = 88    // sizeof(elem_t)
let elemRcOff  = 80    // rc_ within a slot
let msgCcId = 0, msgId = 4, msgRemain = 8, msgStorage = 12, msgPayload = 16

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
let ringShmSizeBytes = 22784  // sizeof(C++ elem_array<broadcast,80,8>) on Apple arm64
func ringShmSize() -> Int { ringShmSizeBytes }

// Ring element alignment folded into the shm name: C++ AlignSize =
// min(dataLength, alignof(max_align_t)) = 8 on Apple arm64 (16 on x86-64).
let ringAlign = 8

// Byte-exact object names (C++ make_prefix: prefix + "__IPC_SHM__" + TAG + ...).
@inline(__always) func fullPrefix(_ prefix: String) -> String { "\(prefix)__IPC_SHM__" }
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
    assert(MemoryLayout<RingHeader>.size == 192)
    assert(MemoryLayout<RingHeader>.offset(of: \.connections)! == 0)
    assert(MemoryLayout<RingHeader>.offset(of: \.lc)! == 4)
    assert(MemoryLayout<RingHeader>.offset(of: \.constructed)! == 8)
    assert(MemoryLayout<RingHeader>.offset(of: \.writeCursor)! == 64)
    assert(MemoryLayout<RingHeader>.offset(of: \.epoch)! == 128)
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
    var chunkShms: [Int: ChunkShmEntry] = [:]
    var connId:     UInt32
    var ccId:       UInt32
    var readCursor: UInt32
    var sendSeq: UInt32 = 0                        // per-sender msg_t.id_ counter
    var recvCache: [UInt32: (Int, [UInt8])] = [:]  // id_ -> (fill offset, buffer)
    let wtWaiter: Waiter
    let rdWaiter: Waiter
    let ccWaiter: Waiter
    var disconnected: Bool = false

    static func open(prefix: String, name: String, mode: Mode) async throws(IpcError) -> ChanInner {
        let fp = fullPrefix(prefix)
        let chunkPrefix = "\(fp)\(name)_"
        let ringShm  = try ShmHandle.acquire(name: ringName(prefix, name), size: ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: ccIdName(prefix), size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
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
            readCursor = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
            try? ccWaiter.broadcast()
        }

        return ChanInner(name: name, prefix: prefix, chunkPrefix: chunkPrefix, mode: mode,
                         ringShm: ringShm, ccIdShm: ccIdShm,
                         connId: connId, ccId: ccId, readCursor: readCursor,
                         wtWaiter: wtWaiter, rdWaiter: rdWaiter, ccWaiter: ccWaiter)
    }

    static func openSync(prefix: String, name: String, mode: Mode) throws(IpcError) -> ChanInner {
        let fp = fullPrefix(prefix)
        let chunkPrefix = "\(fp)\(name)_"
        let ringShm  = try ShmHandle.acquire(name: ringName(prefix, name), size: ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: ccIdName(prefix), size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
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
            readCursor = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
            try? ccWaiter.broadcast()
        }

        return ChanInner(name: name, prefix: prefix, chunkPrefix: chunkPrefix, mode: mode,
                         ringShm: ringShm, ccIdShm: ccIdShm,
                         connId: connId, ccId: ccId, readCursor: readCursor,
                         wtWaiter: wtWaiter, rdWaiter: rdWaiter, ccWaiter: ccWaiter)
    }

    init(name: String, prefix: String, chunkPrefix: String, mode: Mode,
         ringShm: consuming ShmHandle, ccIdShm: consuming ShmHandle,
         connId: UInt32, ccId: UInt32, readCursor: UInt32,
         wtWaiter: consuming Waiter, rdWaiter: consuming Waiter, ccWaiter: consuming Waiter) {
        self.name = name; self.prefix = prefix; self.chunkPrefix = chunkPrefix; self.mode = mode
        self.ringShm = ringShm; self.ccIdShm = ccIdShm
        self.connId = connId; self.ccId = ccId; self.readCursor = readCursor
        self.wtWaiter = wtWaiter; self.rdWaiter = rdWaiter; self.ccWaiter = ccWaiter
    }

    var hdrPtr: UnsafeMutablePointer<RingHeader> {
        ringShm.ptr.assumingMemoryBound(to: RingHeader.self)
    }
    var recvCount: Int {
        Int(ua32(&hdrPtr.pointee.connections).load(ordering: .acquiring).nonzeroBitCount)
    }

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
        let msgId = sendSeq; sendSeq &+= 1
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
        return true
    }

    /// Claim the next ring slot (C++ prod_cons broadcast push/force_push) and write
    /// one msg_t fragment, then advance wt_ and wake receivers.
    func pushFragment(msgId: UInt32, remain: Int32, payload: [UInt8], timeout: Duration) throws(IpcError) -> Bool {
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

            if !keep { continue }

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
                continue
            }

            // Inline fragment reassembly by id_.
            let f = frag!
            if var entry = recvCache[id] {
                recvCache[id] = nil
                entry.1.replaceSubrange(entry.0 ..< entry.0 + f.count, with: f)
                if remain <= 0 { return IpcBuffer(bytes: entry.1) }
                recvCache[id] = (entry.0 + f.count, entry.1)
            } else if remain <= 0 {
                return IpcBuffer(bytes: f)
            } else {
                var buf = [UInt8](repeating: 0, count: Int(rSize))
                buf.replaceSubrange(0 ..< f.count, with: f)
                recvCache[id] = (f.count, buf)
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
