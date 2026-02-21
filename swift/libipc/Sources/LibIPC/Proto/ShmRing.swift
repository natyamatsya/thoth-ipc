// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/shm_ring.h.
// Lock-free SPSC ring buffer over a named shared memory segment.
//
// T must be BitwiseCopyable (trivially copyable, fixed size).
// capacity must be a power of two.

import Darwin.POSIX
import Atomics
import LibIPCShim

// MARK: - ShmRing

/// Lock-free single-producer single-consumer ring buffer over shared memory.
///
/// Binary layout (matches C++ / Rust `shm_ring<T, N>`):
///   Header (192 bytes, 3 × 64-byte cache lines):
///     writeIdx : UInt64  + 56 bytes padding
///     readIdx  : UInt64  + 56 bytes padding
///     constructed : UInt8 + 63 bytes padding
///   Slots: capacity × MemoryLayout<T>.stride
///
/// Port of `ipc::proto::shm_ring<T, N>`.
public final class ShmRing<T: BitwiseCopyable>: @unchecked Sendable {

    // MARK: - Header layout (192 bytes)

    private static var headerSize: Int { 192 }

    private static func shmSize(capacity: Int) -> Int {
        headerSize + MemoryLayout<T>.stride * capacity
    }

    // MARK: - Raw storage (managed manually to avoid ~Copyable class issues)

    private var mem: UnsafeMutableRawPointer?
    private var mappedSize: Int = 0
    private var posixName: String = ""

    private let shmName: String
    private let capacity: Int
    private let mask: UInt64

    // MARK: - Init

    public init(name: String, capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0,
                     "ShmRing capacity must be a power of two")
        self.shmName  = name
        self.capacity = capacity
        self.mask     = UInt64(capacity) - 1
    }

    deinit { closeMapping() }

    // MARK: - Open / Close

    /// Open or create the shared memory segment, initialising it on first creation.
    public func openOrCreate() throws(IpcError) {
        closeMapping()
        let (m, total, pname) = try rawAcquire(name: shmName, size: Self.shmSize(capacity: capacity), create: true)
        mem = m; mappedSize = total; posixName = pname
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        if ua8(&hdr.pointee.constructed).load(ordering: .acquiring) == 0 {
            ua64(&hdr.pointee.writeIdx).store(0, ordering: .relaxed)
            ua64(&hdr.pointee.readIdx).store(0, ordering: .relaxed)
            m.advanced(by: Self.headerSize)
                .initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.stride * capacity)
            ua8(&hdr.pointee.constructed).store(1, ordering: .releasing)
        }
    }

    /// Open an existing segment. Returns `true` if fully initialised.
    @discardableResult
    public func openExisting() throws(IpcError) -> Bool {
        closeMapping()
        let (m, total, pname) = try rawAcquire(name: shmName, size: Self.shmSize(capacity: capacity), create: false)
        mem = m; mappedSize = total; posixName = pname
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        return ua8(&hdr.pointee.constructed).load(ordering: .acquiring) != 0
    }

    /// Unmap the SHM segment (does not unlink it).
    public func close() { closeMapping() }

    /// Unmap and unlink the SHM segment.
    public func destroy() {
        let pname = posixName
        closeMapping()
        if !pname.isEmpty { _ = pname.withCString { shm_unlink($0) } }
    }

    public var valid: Bool { mem != nil }

    // MARK: - Producer API (single writer)

    /// Write `item` into the next slot. Returns `false` if the ring is full.
    @discardableResult
    public func write(_ item: T) -> Bool {
        guard let m = mem else { return false }
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        let w = ua64(&hdr.pointee.writeIdx).load(ordering: .relaxed)
        let r = ua64(&hdr.pointee.readIdx).load(ordering: .acquiring)
        guard w &- r < UInt64(capacity) else { return false }
        slotPtr(m, idx: w).initialize(to: item)
        ua64(&hdr.pointee.writeIdx).loadThenWrappingIncrement(by: 1, ordering: .releasing)
        return true
    }

    /// Write `item`, overwriting the oldest entry if the ring is full.
    public func writeOverwrite(_ item: T) {
        guard let m = mem else { return }
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        let w = ua64(&hdr.pointee.writeIdx).load(ordering: .relaxed)
        let r = ua64(&hdr.pointee.readIdx).load(ordering: .acquiring)
        if w &- r >= UInt64(capacity) {
            ua64(&hdr.pointee.readIdx).store(r &+ 1, ordering: .releasing)
        }
        slotPtr(m, idx: w).initialize(to: item)
        ua64(&hdr.pointee.writeIdx).loadThenWrappingIncrement(by: 1, ordering: .releasing)
    }

    // MARK: - Consumer API (single reader)

    /// Read the next item into `out`. Returns `false` if the ring is empty.
    public func read(into out: inout T) -> Bool {
        guard let m = mem else { return false }
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        let r = ua64(&hdr.pointee.readIdx).load(ordering: .relaxed)
        let w = ua64(&hdr.pointee.writeIdx).load(ordering: .acquiring)
        guard r < w else { return false }
        out = slotPtr(m, idx: r).pointee
        ua64(&hdr.pointee.readIdx).loadThenWrappingIncrement(by: 1, ordering: .releasing)
        return true
    }

    // MARK: - Status

    public var available: Int {
        guard let m = mem else { return 0 }
        let hdr = m.assumingMemoryBound(to: RingHeader192.self)
        let w = ua64(&hdr.pointee.writeIdx).load(ordering: .acquiring)
        let r = ua64(&hdr.pointee.readIdx).load(ordering: .acquiring)
        return Int(w &- r)
    }

    public var isEmpty: Bool { available == 0 }
    public var isFull: Bool  { available >= capacity }

    // MARK: - Private helpers

    private func slotPtr(_ m: UnsafeMutableRawPointer, idx: UInt64) -> UnsafeMutablePointer<T> {
        m.advanced(by: Self.headerSize)
            .assumingMemoryBound(to: T.self)
            .advanced(by: Int(idx & mask))
    }

    private func closeMapping() {
        guard let m = mem else { return }
        munmap(m, mappedSize)
        mem = nil; mappedSize = 0; posixName = ""
    }
}

// MARK: - Raw SHM acquire (bypasses ShmHandle ~Copyable)

private func rawAcquire(name: String, size: Int, create: Bool) throws(IpcError) -> (UnsafeMutableRawPointer, Int, String) {
    let posixName = "/" + name.prefix(255)
    let total = size + MemoryLayout<Int32>.size
    let perms: mode_t = 0o666

    let fd: Int32
    if create {
        let f = posixName.withCString { libipc_shm_open_create($0, perms) }
        if f != -1 {
            guard ftruncate(f, off_t(total)) == 0 else {
                let e = errno; Darwin.close(f); throw .osError(e)
            }
            fd = f
        } else {
            guard errno == EEXIST else { throw .osError(errno) }
            let f2 = posixName.withCString { libipc_shm_open_open($0, perms) }
            guard f2 != -1 else { throw .osError(errno) }
            fd = f2
        }
    } else {
        let f = posixName.withCString { libipc_shm_open_open($0, perms) }
        guard f != -1 else { throw .osError(errno) }
        fd = f
    }

    let raw = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    Darwin.close(fd)
    guard raw != MAP_FAILED, let m = raw else { throw .osError(errno) }
    return (m, total, posixName)
}

// MARK: - Ring header layout (192 bytes = 3 × 64-byte cache lines)

private struct RingHeader192 {
    var writeIdx: UInt64.AtomicRepresentation = .init(0)
    var _pad0: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var readIdx: UInt64.AtomicRepresentation = .init(0)
    var _pad1: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var constructed: UInt8.AtomicRepresentation = .init(0)
    var _pad2: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
         0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - UnsafeAtomic helpers

@inline(__always)
private func ua8(_ field: inout UInt8.AtomicRepresentation) -> UnsafeAtomic<UInt8> {
    UnsafeAtomic(at: withUnsafeMutablePointer(to: &field) {
        $0.withMemoryRebound(to: UnsafeAtomic<UInt8>.Storage.self, capacity: 1) { $0 }
    })
}

@inline(__always)
private func ua64(_ field: inout UInt64.AtomicRepresentation) -> UnsafeAtomic<UInt64> {
    UnsafeAtomic(at: withUnsafeMutablePointer(to: &field) {
        $0.withMemoryRebound(to: UnsafeAtomic<UInt64>.Storage.self, capacity: 1) { $0 }
    })
}
