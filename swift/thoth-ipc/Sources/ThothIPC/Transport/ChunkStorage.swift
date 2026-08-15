// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/ipc.cpp: chunk_info_t / id_pool / find_storage /
// recycle_storage. **Byte-exact with the C++ chunk storage** so a C++ sender's
// large (>64B) messages can be read by a Swift receiver — see
// context/xlang-channel-abi.md §6c.
//
// Chunk shm layout for a given `chunkSize` (name __THOTH_SHM__CHUNK_INFO__<size>):
//   [ chunk_info_t (40B) ] [ chunk of chunkSize bytes ] × chunkMaxCount
// chunk_info_t: id_pool { next_[32]@0; cursor_@32; prepared_@33 } + spin_lock@36.
// chunk: conns (UInt32) @0, payload @ make_align(8,4)=8.

import Darwin.POSIX
import Atomics

// MARK: - Constants

/// Max large-message slots per chunk size (C++ large_msg_cache = 32).
let chunkMaxCount: Int = ABI.large_msg_cache
/// Chunk-size alignment (C++ large_msg_align = 1024).
let chunkAlign: Int = ABI.large_msg_align
/// Per-chunk header = make_align(alignof(max_align_t)=8, sizeof(atomic<cc_t>)=4) = 8.
let chunkHeaderSize: Int = ABI.chunk_header_size

/// A storage slot identifier (C++ storage_id_t = int32); < 0 means invalid.
typealias StorageId = Int32

// MARK: - Chunk-size calculation (byte-exact with C++ calc_chunk_size)

/// ceil((chunkHeaderSize + size) / chunkAlign) * chunkAlign. `size` is the message
/// size; the chunk-shm name embeds this, so it must match C++.
func calcChunkSize(_ size: Int) -> Int {
    let x = chunkHeaderSize + size
    return (x + chunkAlign - 1) / chunkAlign * chunkAlign
}

// MARK: - chunk_info_t layout (byte-exact: id_pool + thoth::spin_lock)

private let ciNextOffset     = ABI.chunk_info_next_off      // next_[32]
private let ciCursorOffset   = ABI.chunk_info_cursor_off    // cursor_ (u8)
private let ciPreparedOffset = ABI.chunk_info_prepared_off  // prepared_ (bool)
private let ciLockOffset     = ABI.chunk_info_lock_off      // thoth::spin_lock (atomic<u32> TAS)
/// sizeof(chunk_info_t) = 40; the chunk array starts here (C++ `this + 1`).
let chunkInfoSize: Int = ABI.chunk_info_size

func chunkShmSize(_ chunkSize: Int) -> Int { chunkInfoSize + chunkMaxCount * chunkSize }

private func ciNextPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciNextOffset).assumingMemoryBound(to: UInt8.self)
}
private func ciCursorPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciCursorOffset).assumingMemoryBound(to: UInt8.self)
}
private func ciLockPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    base.advanced(by: ciLockOffset)
}

/// C++ `thoth::spin_lock` (rw_lock.h) — `lc_.exchange(1, acquire)` spun until it
/// reads 0, released with `store(0, release)`. It is that on every target, Apple
/// included, and this lock lives in shared memory: a C++ peer takes the same four
/// bytes, so the algorithm has to be identical.
///
/// This used the Apple unfair lock until 2026-08-15, following the ABI notes
/// rather than the C++ — which has a *separate*, process-local wrapper under
/// platform/apple/ that chunk_info_t does not use. Apple does not support that
/// primitive on memory shared between processes: its contended path treats the
/// field as a thread token to park on and donate priority to, and a C++ peer
/// stores 1 there.
private func spinLock(_ raw: UnsafeMutableRawPointer) {
    var k: UInt32 = 0
    raw.withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        while UInt32.AtomicRepresentation.atomicExchange(1, at: rep, ordering: .acquiring) != 0 {
            adaptiveYieldSync(&k)
        }
    }
}

private func spinUnlock(_ raw: UnsafeMutableRawPointer) {
    raw.withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        UInt32.AtomicRepresentation.atomicStore(0, at: rep, ordering: .releasing)
    }
}

// MARK: - id_pool acquire / release (byte-exact with C++ id_pool)

/// C++ id_pool::prepare()/init(): build the free list `next_[i] = i+1` when the
/// pool is fresh. "Fresh" means the whole structure compares equal to a zeroed
/// one — C++ `id_pool::invalid()` is a memcmp over all of it. Sampling only
/// `next_[0]` is a different rule: a partially written pool reads as fresh to
/// that test and as used to C++, and the two would then disagree about whether
/// to rebuild the free list. Call under the lock.
func chunkPrepare(_ base: UnsafeMutableRawPointer) {
    let prepared = base.advanced(by: ciPreparedOffset).assumingMemoryBound(to: UInt8.self)
    var untouched = prepared.pointee == 0 && ciCursorPtr(base).pointee == 0
    if untouched {
        for i in 0..<chunkMaxCount where ciNextPtr(base).advanced(by: i).pointee != 0 {
            untouched = false
            break
        }
    }
    if untouched {
        for i in 0..<chunkMaxCount { ciNextPtr(base).advanced(by: i).pointee = UInt8(i + 1) }
    }
    prepared.pointee = 1
}

private func chunkAcquire(_ base: UnsafeMutableRawPointer) -> StorageId {
    let cursor = ciCursorPtr(base).pointee
    guard cursor < UInt8(chunkMaxCount) else { return -1 }
    let id = StorageId(cursor)
    ciCursorPtr(base).pointee = ciNextPtr(base).advanced(by: Int(id)).pointee
    return id
}
private func chunkRelease(_ base: UnsafeMutableRawPointer, id: StorageId) {
    guard id >= 0 && id < StorageId(chunkMaxCount) else { return }
    ciNextPtr(base).advanced(by: Int(id)).pointee = ciCursorPtr(base).pointee
    ciCursorPtr(base).pointee = UInt8(id)
}

// MARK: - Chunk pointer helpers

func chunkConnsPtr(_ base: UnsafeMutableRawPointer, chunkSize: Int, id: StorageId) -> UnsafeMutablePointer<UInt32> {
    base.advanced(by: chunkInfoSize + chunkSize * Int(id)).assumingMemoryBound(to: UInt32.self)
}
func chunkPayloadPtr(_ base: UnsafeMutableRawPointer, chunkSize: Int, id: StorageId) -> UnsafeMutableRawPointer {
    base.advanced(by: chunkInfoSize + chunkSize * Int(id) + chunkHeaderSize)
}

// MARK: - Public API

/// Byte-exact chunk-shm name (C++ make_public_abi_prefix(prefix, "CHUNK_INFO__", chunkSize)):
/// prefix-global (no channel name).
func chunkShmName(prefix: String, chunkSize: Int) -> String {
    "\(fullPrefix(prefix))CHUNK_INFO__\(chunkSize)"
}

/// Open (or create) the chunk-storage shm for `chunkSize`-byte chunks. `prefix` is
/// the channel prefix; the name is prefix-global.
func openChunkShm(prefix: String, chunkSize: Int) throws(IpcError) -> ShmHandle {
    try ShmHandle.acquire(name: chunkShmName(prefix: prefix, chunkSize: chunkSize),
                          size: chunkShmSize(chunkSize), mode: .createOrOpen)
}

/// C++ find_storage: pointer to the payload of chunk `id` (offset chunkHeaderSize).
func findStorage(shm: borrowing ShmHandle, chunkSize: Int, id: StorageId) -> UnsafeMutableRawPointer? {
    guard id >= 0 && id < StorageId(chunkMaxCount) else { return nil }
    return chunkPayloadPtr(shm.ptr, chunkSize: chunkSize, id: id)
}

/// C++ recycle_storage / sub_rc<broadcast>: clear this receiver's bit from the
/// chunk conns; when it reaches 0 (last reader), release the id under lock_.
func recycleStorage(shm: borrowing ShmHandle, chunkSize: Int, id: StorageId, connId: UInt32) {
    guard id >= 0 && id < StorageId(chunkMaxCount) else { return }
    let base = shm.ptr
    let connsRaw = chunkConnsPtr(base, chunkSize: chunkSize, id: id)
    var k: UInt32 = 0
    var isLast = false
    connsRaw.withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        while true {
            let cur = UInt32.AtomicRepresentation.atomicLoad(at: rep, ordering: .acquiring)
            let nxt = cur & ~connId
            let (didExchange, _) = UInt32.AtomicRepresentation.atomicWeakCompareExchange(
                expected: cur, desired: nxt, at: rep, successOrdering: .releasing, failureOrdering: .relaxed)
            if didExchange { isLast = (nxt == 0); return }
            adaptiveYieldSync(&k)
        }
    }
    if isLast {
        let lock = ciLockPtr(base)
        spinLock(lock)
        chunkRelease(base, id: id)
        spinUnlock(lock)
    }
}

/// C++ acquire_storage: allocate a chunk id, stamp its conns, return the payload.
/// (Unused by the fragmenting send path; kept for symmetry.)
func acquireStorage(shm: borrowing ShmHandle, chunkSize: Int, conns: UInt32) -> (StorageId, UnsafeMutableRawPointer)? {
    let base = shm.ptr
    let lock = ciLockPtr(base)
    spinLock(lock)
    chunkPrepare(base)
    let id = chunkAcquire(base)
    spinUnlock(lock)
    guard id >= 0 else { return nil }
    chunkConnsPtr(base, chunkSize: chunkSize, id: id).withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        UInt32.AtomicRepresentation.atomicStore(conns, at: rep, ordering: .relaxed)
    }
    return (id, chunkPayloadPtr(base, chunkSize: chunkSize, id: id))
}

/// Remove the chunk-storage shm segment for `chunkSize`.
func clearChunkShm(prefix: String, chunkSize: Int) {
    ShmHandle.clearStorage(name: chunkShmName(prefix: prefix, chunkSize: chunkSize))
}


// MARK: - Conformance probe

/// Byte-level trace of the primitives whose *protocol* the ABI cannot express —
/// what the pool lock writes while held, and how the free list evolves. Every
/// port emits the same lines or one of them is wrong; C++ is the reference. See
/// context/abi-consistency-review.md.
///
/// No shared memory and no peer: a local zeroed buffer makes the trace
/// deterministic, and it is the state a fresh shm segment is in anyway.
public enum ChunkConform {
    private static func withPool(_ body: (UnsafeMutableRawPointer) -> Void) {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: chunkInfoSize, alignment: 8)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: chunkInfoSize)
        defer { raw.deallocate() }
        body(raw)
    }

    private static func dump(_ step: String, _ base: UnsafeMutableRawPointer) -> String {
        var next = ""
        for i in 0..<chunkMaxCount {
            next += String(format: "%02x", ciNextPtr(base).advanced(by: i).pointee)
        }
        return String(format: "step=%@ next=%@ cursor=%02x prepared=%02x",
                      step, next, ciCursorPtr(base).pointee,
                      base.advanced(by: ciPreparedOffset).assumingMemoryBound(to: UInt8.self).pointee)
    }

    public static func spinlock() -> [String] {
        var out: [String] = []
        withPool { base in
            let lock = base.advanced(by: ciLockOffset)
            let raw = { lock.assumingMemoryBound(to: UInt32.self).pointee }
            out.append(String(format: "step=init bytes=%08x", raw()))
            spinLock(lock)
            out.append(String(format: "step=locked bytes=%08x", raw()))
            spinUnlock(lock)
            out.append(String(format: "step=unlocked bytes=%08x", raw()))
        }
        return out
    }

    public static func idpool() -> [String] {
        var out: [String] = []
        withPool { base in
            out.append(dump("zeroed", base))
            chunkPrepare(base)
            out.append(dump("prepared", base))
            for _ in 0..<3 { out.append("step=acquire id=\(chunkAcquire(base))") }
            out.append(dump("after-acquire3", base))
            chunkRelease(base, id: 1)
            out.append(dump("after-release1", base))
            out.append("step=acquire id=\(chunkAcquire(base))")
            out.append(dump("after-reacquire", base))
        }
        return out
    }

    public static func idpoolPartial() -> [String] {
        var out: [String] = []
        withPool { base in
            ciNextPtr(base).advanced(by: 5).pointee = 7
            out.append(dump("partial-before", base))
            chunkPrepare(base)
            out.append(dump("partial-after", base))
        }
        return out
    }
}
