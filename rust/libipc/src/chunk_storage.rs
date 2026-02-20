// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/ipc.cpp: chunk_info_t / acquire_storage /
// find_storage / recycle_storage / id_pool.
//
// Large messages (> DATA_LENGTH bytes) are stored in a separate named shm
// segment instead of being fragmented across multiple ring slots.  Only a
// 4-byte `storage_id` is placed in the ring slot's data field.
//
// Shared-memory layout for a given `chunk_size`:
//
//   [ ChunkInfo header ]
//   [ chunk_size bytes ] × MAX_COUNT   ← chunk data array
//
// ChunkInfo header:
//   lock    : AtomicU32   (spin-lock protecting cursor + next[])
//   cursor  : u8          (head of the free-list)
//   next    : [u8; MAX_COUNT]  (free-list links; next[i] = index of next free slot)
//
// Each chunk (chunk_size bytes):
//   conns   : AtomicU32   (broadcast connection bitmask — ref-count per receiver)
//   payload : [u8; chunk_size - CHUNK_HEADER]

use std::io;
use std::sync::atomic::{AtomicU32, Ordering};

use crate::shm::{ShmHandle, ShmOpenMode};

/// Maximum number of large-message slots per chunk size (matches C++ `large_msg_cache = 32`).
pub const MAX_COUNT: usize = 32;

/// Alignment for chunk sizes (matches C++ `large_msg_align = 1024`).
pub const CHUNK_ALIGN: usize = 1024;

/// Bytes consumed by the per-chunk connection bitmask at the start of each chunk.
const CHUNK_HEADER: usize = std::mem::size_of::<u32>(); // AtomicU32 is 4 bytes

/// A `storage_id` value; -1 means "invalid / not allocated".
pub type StorageId = i32;

// ---------------------------------------------------------------------------
// ChunkInfo — lives at the start of the chunk shm segment
// ---------------------------------------------------------------------------

/// Header stored at the beginning of each chunk-storage shm segment.
///
/// Mirrors C++ `chunk_info_t` (id_pool + spin_lock).
/// The chunk data array follows immediately after this struct in memory.
#[repr(C)]
struct ChunkInfo {
    /// Spin-lock protecting `cursor` and `next`.
    lock: AtomicU32,
    /// Head of the free-list (index of the next free slot, or MAX_COUNT when empty).
    cursor: u8,
    /// Free-list links: `next[i]` is the index of the slot after `i` in the free list.
    next: [u8; MAX_COUNT],
}

impl ChunkInfo {
    /// Total shm size for this header + `MAX_COUNT` chunks of `chunk_size` bytes each.
    pub const fn shm_size(chunk_size: usize) -> usize {
        std::mem::size_of::<ChunkInfo>() + MAX_COUNT * chunk_size
    }

    /// Initialise the free-list if the pool looks uninitialised (all-zero = fresh shm).
    ///
    /// Mirrors C++ `id_pool::prepare()` / `id_pool::init()`.
    /// Must be called while the spin-lock is held.
    fn ensure_init(&mut self) {
        // Fresh shm is zero-filled: cursor==0 and next==[0,0,...].
        // A properly initialised pool has next[i] = i+1 for i < MAX_COUNT-1
        // and next[MAX_COUNT-1] = MAX_COUNT (sentinel).
        // We detect uninitialised state by checking next[0]: in a valid pool
        // next[0] == 1 (or MAX_COUNT if the pool was full and then emptied).
        // A zero value for next[0] is only valid if cursor==MAX_COUNT (empty).
        if self.cursor == 0 && self.next[0] == 0 {
            for i in 0..MAX_COUNT {
                self.next[i] = (i + 1) as u8;
            }
            // cursor stays 0 — first free slot is index 0
        }
    }

    fn acquire(&mut self) -> StorageId {
        if self.cursor as usize >= MAX_COUNT {
            return -1; // pool exhausted
        }
        let id = self.cursor as StorageId;
        self.cursor = self.next[id as usize];
        id
    }

    fn release(&mut self, id: StorageId) {
        if id < 0 || id as usize >= MAX_COUNT {
            return;
        }
        self.next[id as usize] = self.cursor;
        self.cursor = id as u8;
    }
}

// ---------------------------------------------------------------------------
// Spin-lock helpers (reuse the same pattern as spin_lock.rs)
// ---------------------------------------------------------------------------

fn spin_lock(lock: &AtomicU32) {
    let mut k = 0u32;
    while lock
        .compare_exchange_weak(0, 1, Ordering::Acquire, Ordering::Relaxed)
        .is_err()
    {
        crate::spin_lock::adaptive_yield_pub(&mut k);
    }
}

fn spin_unlock(lock: &AtomicU32) {
    lock.store(0, Ordering::Release);
}

// ---------------------------------------------------------------------------
// Chunk-size calculation (mirrors C++ calc_chunk_size / align_chunk_size)
// ---------------------------------------------------------------------------

/// Round `size` up to the next multiple of `CHUNK_ALIGN`, then add the per-chunk
/// header (AtomicU32 conn bitmask).  This is the total bytes allocated per slot.
pub fn calc_chunk_size(payload_size: usize) -> usize {
    let aligned = ((payload_size + CHUNK_ALIGN - 1) / CHUNK_ALIGN) * CHUNK_ALIGN;
    // Add header, then align the whole thing to max_align (16 bytes on most platforms).
    let total = std::mem::size_of::<u32>() + aligned;
    let align = std::mem::align_of::<u128>(); // 16
    (total + align - 1) / align * align
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Open (or create) the chunk-storage shm segment for `chunk_size`-byte chunks.
/// Returns the `ShmHandle`; the caller must keep it alive for the duration of use.
pub fn open_chunk_shm(full_prefix: &str, chunk_size: usize) -> io::Result<ShmHandle> {
    let name = format!("{full_prefix}CH_CONN__{chunk_size}");
    let size = ChunkInfo::shm_size(chunk_size);
    ShmHandle::acquire(&name, size, ShmOpenMode::CreateOrOpen)
}

/// Acquire a free slot from the chunk-storage shm.
///
/// Returns `(storage_id, *mut u8 payload pointer)` on success, or `None` if
/// the pool is exhausted or the shm is unavailable.
///
/// Mirrors C++ `acquire_storage`.
pub fn acquire_storage(
    shm: &ShmHandle,
    chunk_size: usize,
    conns: u32,
) -> Option<(StorageId, *mut u8)> {
    let base = shm.get();
    let info = unsafe { &mut *(base as *mut ChunkInfo) };

    spin_lock(&info.lock);
    info.ensure_init();
    let id = info.acquire();
    spin_unlock(&info.lock);

    if id < 0 {
        return None;
    }

    let payload_ptr = chunk_payload_ptr(base, chunk_size, id);

    // Store the connection bitmask in the per-chunk header (before the payload).
    let conns_ptr = unsafe { chunk_conns_ptr(base, chunk_size, id) };
    unsafe { (*conns_ptr).store(conns, Ordering::Relaxed) };

    Some((id, payload_ptr))
}

/// Return a pointer to the payload of chunk `id`.
///
/// Mirrors C++ `chunk_info_t::at(chunk_size, id)->data()`.
pub fn find_storage(shm: &ShmHandle, chunk_size: usize, id: StorageId) -> Option<*mut u8> {
    if id < 0 || id as usize >= MAX_COUNT {
        return None;
    }
    Some(chunk_payload_ptr(shm.get(), chunk_size, id))
}

/// Clear the receiver's bit from the chunk's connection bitmask.
/// When the bitmask reaches zero (last reader), release the slot back to the pool.
///
/// Mirrors C++ `recycle_storage` / `sub_rc<broadcast>`.
pub fn recycle_storage(shm: &ShmHandle, chunk_size: usize, id: StorageId, conn_id: u32) {
    if id < 0 || id as usize >= MAX_COUNT {
        return;
    }

    let base = shm.get();
    let conns_ptr = unsafe { chunk_conns_ptr(base, chunk_size, id) };
    let conns = unsafe { &*conns_ptr };

    // CAS-clear our bit; check if we were the last reader.
    let mut k = 0u32;
    let last = loop {
        let cur = conns.load(Ordering::Acquire);
        let nxt = cur & !conn_id;
        if conns
            .compare_exchange_weak(cur, nxt, Ordering::Release, Ordering::Relaxed)
            .is_ok()
        {
            break nxt == 0;
        }
        crate::spin_lock::adaptive_yield_pub(&mut k);
    };

    if last {
        let info = unsafe { &mut *(base as *mut ChunkInfo) };
        spin_lock(&info.lock);
        info.release(id);
        spin_unlock(&info.lock);
    }
}

/// Remove the chunk-storage shm segment for `chunk_size`.
pub fn clear_chunk_shm(full_prefix: &str, chunk_size: usize) {
    let name = format!("{full_prefix}CH_CONN__{chunk_size}");
    ShmHandle::clear_storage(&name);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Pointer to the `AtomicU32` connection bitmask at the start of chunk `id`.
unsafe fn chunk_conns_ptr(base: *mut u8, chunk_size: usize, id: StorageId) -> *mut AtomicU32 {
    let chunks_base = base.add(std::mem::size_of::<ChunkInfo>());
    chunks_base.add(chunk_size * id as usize) as *mut AtomicU32
}

/// Pointer to the payload bytes of chunk `id` (after the 4-byte conn header).
fn chunk_payload_ptr(base: *mut u8, chunk_size: usize, id: StorageId) -> *mut u8 {
    unsafe {
        let chunks_base = base.add(std::mem::size_of::<ChunkInfo>());
        chunks_base.add(chunk_size * id as usize).add(CHUNK_HEADER)
    }
}
