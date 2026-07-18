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
// chunk_info_t: id_pool { next_[32]@0; cursor_@32; prepared_@33 } + os_unfair_lock@36.
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

// MARK: - chunk_info_t layout (byte-exact: id_pool + os_unfair_lock)

private let ciNextOffset     = 0   // next_[32]
private let ciCursorOffset   = 32  // cursor_ (u8)
private let ciPreparedOffset = 33  // prepared_ (bool)
private let ciLockOffset     = 36  // os_unfair_lock
/// sizeof(chunk_info_t) = 40; the chunk array starts here (C++ `this + 1`).
let chunkInfoSize: Int = ABI.chunk_info_size

func chunkShmSize(_ chunkSize: Int) -> Int { chunkInfoSize + chunkMaxCount * chunkSize }

private func ciNextPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciNextOffset).assumingMemoryBound(to: UInt8.self)
}
private func ciCursorPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<UInt8> {
    base.advanced(by: ciCursorOffset).assumingMemoryBound(to: UInt8.self)
}
private func ciLockPtr(_ base: UnsafeMutableRawPointer) -> UnsafeMutablePointer<os_unfair_lock> {
    base.advanced(by: ciLockOffset).assumingMemoryBound(to: os_unfair_lock.self)
}

// MARK: - id_pool acquire / release (byte-exact with C++ id_pool)

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
        os_unfair_lock_lock(lock)
        chunkRelease(base, id: id)
        os_unfair_lock_unlock(lock)
    }
}

/// C++ acquire_storage: allocate a chunk id, stamp its conns, return the payload.
/// (Unused by the fragmenting send path; kept for symmetry.)
func acquireStorage(shm: borrowing ShmHandle, chunkSize: Int, conns: UInt32) -> (StorageId, UnsafeMutableRawPointer)? {
    let base = shm.ptr
    let lock = ciLockPtr(base)
    os_unfair_lock_lock(lock)
    // prepare(): a fresh (zeroed) pool is invalid → build the free list.
    let prepared = base.advanced(by: ciPreparedOffset).assumingMemoryBound(to: UInt8.self)
    if prepared.pointee == 0 && ciCursorPtr(base).pointee == 0 && ciNextPtr(base).pointee == 0 {
        for i in 0..<chunkMaxCount { ciNextPtr(base).advanced(by: i).pointee = UInt8(i + 1) }
    }
    prepared.pointee = 1
    let id = chunkAcquire(base)
    os_unfair_lock_unlock(lock)
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
