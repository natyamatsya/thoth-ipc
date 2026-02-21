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
let sizeLast: UInt32    = 0x8000_0000
let sizeStorage: UInt32 = 0x4000_0000
let sizeMask: UInt32    = 0x3FFF_FFFF
let epMask: UInt64 = 0x0000_0000_FFFF_FFFF
let epIncr: UInt64 = 0x0000_0001_0000_0000
private let spinCount: UInt32 = 32

// MARK: - Ring layout (binary-compatible with C++ / Rust)

@_alignment(8)
struct RingSlot {
    var data: (
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8
    ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var size: UInt32.AtomicRepresentation = .init(0)
    var ccId: UInt32.AtomicRepresentation = .init(0)
    var rc:   UInt64.AtomicRepresentation = .init(0)
}

@_alignment(8)
struct RingHeader {
    var connections: UInt32.AtomicRepresentation = .init(0)
    var writeCursor: UInt32.AtomicRepresentation = .init(0)
    var senderCount: UInt32.AtomicRepresentation = .init(0)
    var epoch:       UInt64.AtomicRepresentation = .init(0)
}

let ringHeaderSize = MemoryLayout<RingHeader>.size
let ringSlotSize   = MemoryLayout<RingSlot>.size
func ringShmSize() -> Int { ringHeaderSize + ringSize * ringSlotSize }

// MARK: - Mode

public enum Mode: Sendable { case sender, receiver }

// MARK: - ChanInner

final class ChanInner: @unchecked Sendable {
    let name: String
    let prefix: String
    let chunkPrefix: String
    let mode: Mode
    let ringShm:  ShmHandle
    let ccIdShm:  ShmHandle
    var chunkShm: ShmHandle?
    var connId:     UInt32
    var ccId:       UInt32
    var readCursor: UInt32
    let wtWaiter: Waiter
    let rdWaiter: Waiter
    let ccWaiter: Waiter
    var disconnected: Bool = false

    static func open(prefix: String, name: String, mode: Mode) async throws(IpcError) -> ChanInner {
        let fp = prefix.isEmpty ? "" : "\(prefix)_"
        let chunkPrefix = "\(fp)\(name)_"
        let ringShm  = try ShmHandle.acquire(name: "\(fp)QU_CONN__\(name)", size: ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: "\(fp)CA_CONN__\(name)", size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
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
        let fp = prefix.isEmpty ? "" : "\(prefix)_"
        let chunkPrefix = "\(fp)\(name)_"
        let ringShm  = try ShmHandle.acquire(name: "\(fp)QU_CONN__\(name)", size: ringShmSize(), mode: .createOrOpen)
        let ccIdShm  = try ShmHandle.acquire(name: "\(fp)CA_CONN__\(name)", size: MemoryLayout<UInt32>.size, mode: .createOrOpen)
        let wtWaiter = try Waiter.openSync(name: "\(fp)WT_CONN__\(name)")
        let rdWaiter = try Waiter.openSync(name: "\(fp)RD_CONN__\(name)")
        let ccWaiter = try Waiter.openSync(name: "\(fp)CC_CONN__\(name)")

        let ccIdAtom = UnsafeAtomic<UInt32>(at: ccIdShm.ptr.withMemoryRebound(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1) { $0 })
        var ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        if ccId == 0 {
            ccId = ccIdAtom.loadThenWrappingIncrement(by: 1, ordering: .relaxed).addingReportingOverflow(1).partialValue
        }

        let hdr = ringShm.ptr.assumingMemoryBound(to: RingHeader.self)
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
    func slotPtr(_ idx: UInt8) -> UnsafeMutablePointer<RingSlot> {
        ringShm.ptr.advanced(by: ringHeaderSize).assumingMemoryBound(to: RingSlot.self).advanced(by: Int(idx))
    }
    var recvCount: Int {
        Int(ua32(&hdrPtr.pointee.connections).load(ordering: .acquiring).nonzeroBitCount)
    }
    func getOrOpenChunkShm(chunkSize: Int) -> UnsafeMutablePointer<ShmHandle>? {
        if chunkShm == nil { chunkShm = try? openChunkShm(prefix: chunkPrefix, chunkSize: chunkSize) }
        guard chunkShm != nil else { return nil }
        return withUnsafeMutablePointer(to: &chunkShm!) { $0 }
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

// MARK: - Send

extension ChanInner {

    func send(data: [UInt8], timeout: Duration) throws(IpcError) -> Bool {
        guard !data.isEmpty else { return false }
        guard mode == .sender else { throw .osError(EPERM) }
        if data.count > dataLength {
            if let r = try sendLarge(data: data, timeout: timeout) { return r }
        }
        let hdr = hdrPtr
        var offset = 0
        while offset < data.count {
            let chunkLen = min(dataLength, data.count - offset)
            let isLast   = (offset + chunkLen) >= data.count
            var claimedWt: UInt32 = 0
            claimLoop: while true {
                let cc = UInt64(ua32(&hdr.pointee.connections).load(ordering: .relaxed))
                guard cc != 0 else { return false }
                let epoch = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
                let wt    = ua32(&hdr.pointee.writeCursor).load(ordering: .relaxed)
                let slot  = ringShm.ptr.advanced(by: ringHeaderSize)
                    .assumingMemoryBound(to: RingSlot.self).advanced(by: Int(wt & 0xFF))
                let curRc = ua64(&slot.pointee.rc).load(ordering: .acquiring)
                let remCc = curRc & epMask
                if (cc & remCc) != 0 && (curRc & ~epMask) == epoch {
                    let rb = ringShm.ptr
                    let ok = try waitFor(waiter: wtWaiter, pred: {
                        let s = rb.advanced(by: ringHeaderSize)
                            .assumingMemoryBound(to: RingSlot.self).advanced(by: Int(wt & 0xFF))
                        let rc = ua64(&s.pointee.rc).load(ordering: .acquiring)
                        let ep = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
                        return (cc & (rc & epMask)) != 0 && (rc & ~epMask) == ep
                    }, timeout: timeout)
                    if ok { continue claimLoop }
                    _ = ua64(&hdr.pointee.epoch).loadThenWrappingIncrement(by: epIncr, ordering: .acquiringAndReleasing)
                    let remCc2 = ua64(&slot.pointee.rc).load(ordering: .acquiring) & epMask
                    if remCc2 != 0 {
                        let newCc = ua32(&hdr.pointee.connections)
                            .loadThenBitwiseAnd(with: ~UInt32(remCc2), ordering: .acquiringAndReleasing) & ~UInt32(remCc2)
                        if newCc == 0 { return false }
                        _ = ua64(&slot.pointee.rc).loadThenBitwiseAnd(with: ~remCc2, ordering: .acquiringAndReleasing)
                    }
                    continue claimLoop
                }
                let (ok, _) = ua64(&slot.pointee.rc).weakCompareExchange(
                    expected: curRc, desired: epoch | cc, successOrdering: .releasing, failureOrdering: .relaxed)
                if ok { claimedWt = wt; break claimLoop }
                sched_yield()
            }
            let slot = slotPtr(UInt8(claimedWt & 0xFF))
            ua32(&slot.pointee.ccId).store(ccId, ordering: .relaxed)
            withUnsafeMutableBytes(of: &slot.pointee.data) { dst in
                data.withUnsafeBytes { src in
                    dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: offset), byteCount: chunkLen)
                }
            }
            ua32(&slot.pointee.size).store(isLast ? (sizeLast | UInt32(chunkLen)) : UInt32(chunkLen), ordering: .relaxed)
            _ = ua32(&hdr.pointee.writeCursor).loadThenWrappingIncrement(by: 1, ordering: .releasing)
            offset += chunkLen
            try? rdWaiter.broadcast()
        }
        return true
    }

    private func sendLarge(data: [UInt8], timeout: Duration) throws(IpcError) -> Bool? {
        let chunkSize = calcChunkSize(data.count)
        guard let shmPtr = getOrOpenChunkShm(chunkSize: chunkSize) else { return nil }
        let hdr   = hdrPtr
        let conns = ua32(&hdr.pointee.connections).load(ordering: .relaxed)
        guard let (storageId, payloadPtr) = acquireStorage(shm: shmPtr.pointee, chunkSize: chunkSize, conns: conns)
        else { return nil }
        data.withUnsafeBytes { payloadPtr.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        var claimedWt: UInt32 = 0
        claimLoop: while true {
            let cc = UInt64(ua32(&hdr.pointee.connections).load(ordering: .relaxed))
            if cc == 0 {
                recycleStorage(shm: shmPtr.pointee, chunkSize: chunkSize, id: storageId, connId: ~0)
                return false
            }
            let epoch = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
            let wt    = ua32(&hdr.pointee.writeCursor).load(ordering: .relaxed)
            let slot  = ringShm.ptr.advanced(by: ringHeaderSize)
                .assumingMemoryBound(to: RingSlot.self).advanced(by: Int(wt & 0xFF))
            let curRc = ua64(&slot.pointee.rc).load(ordering: .acquiring)
            let remCc = curRc & epMask
            if (cc & remCc) != 0 && (curRc & ~epMask) == epoch {
                let rb = ringShm.ptr
                let ok = try waitFor(waiter: wtWaiter, pred: {
                    let s = rb.advanced(by: ringHeaderSize)
                        .assumingMemoryBound(to: RingSlot.self).advanced(by: Int(wt & 0xFF))
                    let rc = ua64(&s.pointee.rc).load(ordering: .acquiring)
                    let ep = ua64(&hdr.pointee.epoch).load(ordering: .relaxed)
                    return (cc & (rc & epMask)) != 0 && (rc & ~epMask) == ep
                }, timeout: timeout)
                if ok { continue claimLoop }
                _ = ua64(&hdr.pointee.epoch).loadThenWrappingIncrement(by: epIncr, ordering: .acquiringAndReleasing)
                let remCc2 = ua64(&slot.pointee.rc).load(ordering: .acquiring) & epMask
                if remCc2 != 0 {
                    let newCc = ua32(&hdr.pointee.connections)
                        .loadThenBitwiseAnd(with: ~UInt32(remCc2), ordering: .acquiringAndReleasing) & ~UInt32(remCc2)
                    if newCc == 0 {
                        recycleStorage(shm: shmPtr.pointee, chunkSize: chunkSize, id: storageId, connId: ~0)
                        return false
                    }
                    _ = ua64(&slot.pointee.rc).loadThenBitwiseAnd(with: ~remCc2, ordering: .acquiringAndReleasing)
                }
                continue claimLoop
            }
            let (ok, _) = ua64(&slot.pointee.rc).weakCompareExchange(
                expected: curRc, desired: epoch | cc, successOrdering: .releasing, failureOrdering: .relaxed)
            if ok { claimedWt = wt; break claimLoop }
            sched_yield()
        }
        let slot = slotPtr(UInt8(claimedWt & 0xFF))
        ua32(&slot.pointee.ccId).store(ccId, ordering: .relaxed)
        withUnsafeMutableBytes(of: &slot.pointee.data) { dst in
            var sid = storageId; var psz = UInt32(data.count)
            withUnsafeBytes(of: &sid) { dst.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: 4) }
            withUnsafeBytes(of: &psz) { dst.baseAddress!.advanced(by: 4).copyMemory(from: $0.baseAddress!, byteCount: 4) }
        }
        ua32(&slot.pointee.size).store(sizeLast | sizeStorage | 8, ordering: .relaxed)
        _ = ua32(&hdrPtr.pointee.writeCursor).loadThenWrappingIncrement(by: 1, ordering: .releasing)
        try? rdWaiter.broadcast()
        return true
    }
}

// MARK: - Recv

extension ChanInner {

    func recv(timeout: Duration?) throws(IpcError) -> IpcBuffer {
        guard mode == .receiver else { throw .osError(EPERM) }
        let deadline  = timeout.map { ContinuousClock.now + $0 }
        var assembled = [UInt8]()
        let connMask  = UInt64(connId)
        let ringBase  = ringShm.ptr

        while true {
            let hdr = hdrPtr
            let wc  = ua32(&hdr.pointee.writeCursor).load(ordering: .acquiring)
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

            let idx  = UInt8(readCursor & 0xFF)
            let slot = ringBase.advanced(by: ringHeaderSize)
                .assumingMemoryBound(to: RingSlot.self).advanced(by: Int(idx))
            let sizeVal   = ua32(&slot.pointee.size).load(ordering: .relaxed)
            let chunkLen  = Int(sizeVal & sizeMask)
            let isLast    = (sizeVal & sizeLast) != 0
            let isStorage = (sizeVal & sizeStorage) != 0
            let isOwn     = ua32(&slot.pointee.ccId).load(ordering: .relaxed) == ccId

            if !isOwn {
                if isStorage {
                    var idBytes = [UInt8](repeating: 0, count: 4)
                    var szBytes = [UInt8](repeating: 0, count: 4)
                    withUnsafeBytes(of: slot.pointee.data) { src in
                        idBytes.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: 4) }
                        szBytes.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: 4), byteCount: 4) }
                    }
                    let storageId   = idBytes.withUnsafeBytes { $0.load(as: StorageId.self) }
                    let payloadSize = Int(szBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let chunkSize   = calcChunkSize(payloadSize)
                    if let shmPtr = getOrOpenChunkShm(chunkSize: chunkSize) {
                        if let ptr = findStorage(shm: shmPtr.pointee, chunkSize: chunkSize, id: storageId) {
                            assembled.append(contentsOf: UnsafeRawBufferPointer(start: ptr, count: payloadSize))
                        }
                        recycleStorage(shm: shmPtr.pointee, chunkSize: chunkSize, id: storageId, connId: connId)
                    }
                } else {
                    withUnsafeBytes(of: slot.pointee.data) { assembled.append(contentsOf: $0.prefix(chunkLen)) }
                }
            }

            var k: UInt32 = 0
            while true {
                let cur = ua64(&slot.pointee.rc).load(ordering: .acquiring)
                let (ok, _) = ua64(&slot.pointee.rc).weakCompareExchange(
                    expected: cur, desired: cur & ~connMask, successOrdering: .releasing, failureOrdering: .relaxed)
                if ok { break }
                adaptiveYieldSync(&k)
            }

            try? wtWaiter.broadcast()
            readCursor = readCursor &+ 1

            if isLast {
                if isOwn { assembled.removeAll(keepingCapacity: false); return IpcBuffer() }
                return IpcBuffer(bytes: assembled)
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
