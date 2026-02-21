// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/ipc.cpp: chunk_info_t / acquire_storage /
// find_storage / recycle_storage / id_pool.
//
// Large messages (> DATA_LENGTH bytes) are stored in a separate named shm
// segment instead of being fragmented across multiple ring slots. Only a
// 4-byte `storageId` is placed in the ring slot's data field.
//
// Shared-memory layout for a given `chunkSize`:
//
//   [ ChunkInfo header ]
//   [ chunkSize bytes ] × MAX_COUNT   ← chunk data array
//
// ChunkInfo header (at offset 0):
//   lock    : UInt32   (spin-lock: 0=free, 1=held)
//   cursor  : UInt8    (head of the free-list)
//   next    : [UInt8; MAX_COUNT]  (free-list links)
//
// Each chunk (chunkSize bytes):
//   conns   : UInt32   (broadcast connection bitmask — ref-count per receiver)
//   payload : [UInt8; chunkSize - CHUNK_HEADER]

import Darwin.POSIX
import Atomics

// MARK: - Constants

/// Maximum number of large-message slots per chunk size (matches C++ `large_msg_cache = 32`).
let chunkMaxCount: Int = 32

/// Alignment for chunk sizes (matches C++ `large_msg_align = 1024`).
let chunkAlign: Int = 1024

/// Bytes consumed by the per-chunk connection bitmask at the start of each chunk.
let chunkHeaderSize: Int = MemoryLayout<UInt32>.size  // 4

/// A storage slot identifier; -1 means invalid / not allocated.
typealias StorageId = Int32

// MARK: - Chunk-size calculation

/// Round `payloadSize` up to the next multiple of `chunkAlign`, add the per-chunk
/// header, then align the total to 16 bytes.
/// Mirrors C++ `calc_chunk_size` / Rust `calc_chunk_size`.
func calcChunkSize(_ payloadSize: Int) -> Int {
    let aligned = ((payloadSize + chunkAlign - 1) / chunkAlign) * chunkAlign
    let total = MemoryLayout<UInt32>.size + aligned
    let align = 16  // MemoryLayout<(UInt64, UInt64)>.alignment
    return (total + align - 1) / align * align
}

// MARK: - ChunkInfo layout helpers

/// Offset of the spin-lock field within ChunkInfo.
private let ciLockOffset = 0
/// Offset of the cursor field within ChunkInfo.
private let ciCursorOffset = MemoryLayout<UInt32>.size  // 4
/// Offset of the next[] array within ChunkInfo.
private let ciNextOffset = ciCursorOffset + 1  // 5
/// Total size of the ChunkInfo header.
let chunkInfoSize: Int = ciNextOffset + chunkMaxCount  // 5 + 32 = 37, but we round up

// We store ChunkInfo as a flat byte region; use helpers to access fields.

private func ciLockPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt32> {
    base.advanced(by: ciLockOffset).assumingMemoryBound(to: UInt32.self)
}

private func ciCursorPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciCursorOffset).assumingMemoryBound(to: UInt8.self)
}

private func ciNextPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciNextOffset).assumingMemoryBound(to: UInt8.self)
}

/// Actual header size rounded up to 16-byte alignment so chunk array starts aligned.
let chunkInfoAlignedSize: Int = (ciNextOffset + chunkMaxCount + 15) / 16 * 16  // = 48

/// Total shm size for a chunk-storage segment with `chunkSize`-byte chunks.
func chunkShmSize(_ chunkSize: Int) -> Int {
    chunkInfoAlignedSize + chunkMaxCount * chunkSize
}

// MARK: - Spin-lock helpers (raw UInt32 in shm)

private func rawSpinLock(_ ptr: UnsafeMutablePointer<UInt32>) {
    var k: UInt32 = 0
    ptr.withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        while true {
            var expected: UInt32 = 0
            let (exchanged, _) = UInt32.AtomicRepresentation.atomicWeakCompareExchange(
                expected: expected,
                desired: 1,
                at: rep,
                successOrdering: .acquiring,
                failureOrdering: .relaxed
            )
            _ = expected  // suppress unused warning
            if exchanged { return }
            adaptiveYieldSync(&k)
        }
    }
}

private func rawSpinUnlock(_ ptr: UnsafeMutablePointer<UInt32>) {
    ptr.withMemoryRebound(to: UInt32.AtomicRepresentation.self, capacity: 1) { rep in
        UInt32.AtomicRepresentation.atomicStore(0, at: rep, ordering: .releasing)
    }
}

// MARK: - Free-list init / acquire / release

/// Initialise the free-list if the pool looks uninitialised (all-zero = fresh shm).
/// Must be called while the spin-lock is held.
private func ensureInit(_ base: UnsafeMutableRawPointer) {
    let cursor = ciCursorPtr(base).pointee
    let next0 = ciNextPtr(base).pointee
    guard cursor == 0 && next0 == 0 else { return }
    let nextArr = ciNextPtr(base)
    for i in 0..<chunkMaxCount {
        nextArr.advanced(by: i).pointee = UInt8(i + 1)
    }
    // cursor stays 0 — first free slot is index 0
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

/// Pointer to the `UInt32` connection bitmask at the start of chunk `id`.
func chunkConnsPtr(
    _ base: UnsafeMutableRawPointer,
    chunkSize: Int,
    id: StorageId
) -> UnsafeMutablePointer<UInt32> {
    base.advanced(by: chunkInfoAlignedSize + chunkSize * Int(id))
        .assumingMemoryBound(to: UInt32.self)
}

/// Pointer to the payload bytes of chunk `id` (after the 4-byte conn header).
func chunkPayloadPtr(
    _ base: UnsafeMutableRawPointer,
    chunkSize: Int,
    id: StorageId
) -> UnsafeMutableRawPointer {
    base.advanced(by: chunkInfoAlignedSize + chunkSize * Int(id) + chunkHeaderSize)
}

// MARK: - Public API

/// Open (or create) the chunk-storage shm segment for `chunkSize`-byte chunks.
func openChunkShm(prefix: String, chunkSize: Int) throws(IpcError) -> ShmHandle {
    let name = "\(prefix)CH_CONN__\(chunkSize)"
    return try ShmHandle.acquire(name: name, size: chunkShmSize(chunkSize), mode: .createOrOpen)
}

/// Acquire a free slot from the chunk-storage shm.
///
/// Returns `(storageId, payloadPointer)` on success, or `nil` if the pool is exhausted.
/// Mirrors C++ `acquire_storage` / Rust `acquire_storage`.
func acquireStorage(
    shm: borrowing ShmHandle,
    chunkSize: Int,
    conns: UInt32
) -> (StorageId, UnsafeMutableRawPointer)? {
    let base = shm.ptr
    let lockPtr = ciLockPtr(base)
    rawSpinLock(lockPtr)
    ensureInit(base)
    let id = chunkAcquire(base)
    rawSpinUnlock(lockPtr)
    guard id >= 0 else { return nil }
    let payload = chunkPayloadPtr(base, chunkSize: chunkSize, id: id)
    // Store the connection bitmask in the per-chunk header.
    chunkConnsPtr(base, chunkSize: chunkSize, id: id).withMemoryRebound(
        to: UInt32.AtomicRepresentation.self, capacity: 1
    ) { rep in
        UInt32.AtomicRepresentation.atomicStore(conns, at: rep, ordering: .relaxed)
    }
    return (id, payload)
}

/// Return a pointer to the payload of chunk `id`.
/// Mirrors C++ `chunk_info_t::at(chunk_size, id)->data()` / Rust `find_storage`.
func findStorage(
    shm: borrowing ShmHandle,
    chunkSize: Int,
    id: StorageId
) -> UnsafeMutableRawPointer? {
    guard id >= 0 && id < StorageId(chunkMaxCount) else { return nil }
    return chunkPayloadPtr(shm.ptr, chunkSize: chunkSize, id: id)
}

/// Clear the receiver's bit from the chunk's connection bitmask.
/// When the bitmask reaches zero (last reader), release the slot back to the pool.
/// Mirrors C++ `recycle_storage` / Rust `recycle_storage`.
func recycleStorage(
    shm: borrowing ShmHandle,
    chunkSize: Int,
    id: StorageId,
    connId: UInt32
) {
    guard id >= 0 && id < StorageId(chunkMaxCount) else { return }
    let base = shm.ptr
    let connsRaw = chunkConnsPtr(base, chunkSize: chunkSize, id: id)
    var k: UInt32 = 0
    var isLast = false
    connsRaw.withMemoryRebound(
        to: UInt32.AtomicRepresentation.self, capacity: 1
    ) { rep in
        while true {
            let cur = UInt32.AtomicRepresentation.atomicLoad(at: rep, ordering: .acquiring)
            let nxt = cur & ~connId
            let (didExchange, _) = UInt32.AtomicRepresentation.atomicWeakCompareExchange(
                expected: cur,
                desired: nxt,
                at: rep,
                successOrdering: .releasing,
                failureOrdering: .relaxed
            )
            if didExchange { isLast = (nxt == 0); return }
            adaptiveYieldSync(&k)
        }
    }
    if isLast {
        let lockPtr = ciLockPtr(base)
        rawSpinLock(lockPtr)
        chunkRelease(base, id: id)
        rawSpinUnlock(lockPtr)
    }
}

/// Remove the chunk-storage shm segment for `chunkSize`.
func clearChunkShm(prefix: String, chunkSize: Int) {
    let name = "\(prefix)CH_CONN__\(chunkSize)"
    ShmHandle.clearStorage(name: name)
}
