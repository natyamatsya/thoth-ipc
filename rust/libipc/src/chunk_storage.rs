// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/ipc.cpp: chunk_info_t / id_pool / acquire_storage /
// find_storage / recycle_storage. **Byte-exact with the C++ chunk storage** so a
// C++ sender's large (>64B) messages can be read by a Rust receiver — see
// context/xlang-channel-abi.md §6c.
//
// A C++ sender stores messages >large_msg_limit (64B) in a chunk shm and pushes a
// single msg_t with storage_=true and the storage_id in the payload. A Rust
// receiver reads it via find_storage and frees it via recycle_storage. (A Rust
// sender keeps fragmenting instead — C++ recv reassembles — so acquire_storage is
// present for symmetry but unused by the current send path.)
//
// Chunk shm layout for a given `chunk_size` (name __IPC_SHM__CHUNK_INFO__<size>):
//   [ chunk_info_t (40B) ] [ chunk_t of chunk_size bytes ] × MAX_COUNT
// chunk_info_t: id_pool { next_[32]; cursor_; prepared_ } + spin_lock @36.
// chunk_t: conns (AtomicU32) @0, payload @ make_align(8,4)=8.

#![allow(dead_code)] // acquire_storage/id_pool helpers unused by the fragmenting send path

use std::io;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use crate::abi_generated as abi;

#[cfg(unix)]
use crate::platform::posix::{cached_shm_acquire, cached_shm_purge, cached_shm_release, CachedShm};
use crate::shm::ShmHandle;
#[cfg(not(unix))]
use crate::shm::ShmOpenMode;

/// Max large-message slots per chunk size (C++ `large_msg_cache = 32`).
pub const MAX_COUNT: usize = abi::large_msg_cache;
/// Chunk-size alignment (C++ `large_msg_align = 1024`).
pub const CHUNK_ALIGN: usize = abi::large_msg_align;
/// Per-chunk header = `make_align(alignof(max_align_t)=8, sizeof(atomic<cc_t>)=4)` = 8.
const CHUNK_HEADER: usize = abi::chunk_header_size;

/// A `storage_id` (C++ `storage_id_t = int32`); < 0 means invalid.
pub type StorageId = i32;

// ---------------------------------------------------------------------------
// chunk_info_t — byte-exact with C++ { id_pool pool_; spin_lock lock_; }
// ---------------------------------------------------------------------------

#[repr(C)]
struct ChunkInfo {
    next_: [u8; MAX_COUNT], // @0  id_pool free-list links
    cursor_: u8,            // @32 head of the free list
    prepared_: u8,          // @33 id_pool::prepared_ (bool)
    _pad: [u8; 2],          // @34..36
    #[cfg(target_vendor = "apple")]
    lock_: libc::os_unfair_lock, // @36 (C++ spin_lock)
    #[cfg(not(target_vendor = "apple"))]
    lock_: AtomicU32, // @36 (C++ generic spin_lock = atomic<u32> TAS-spin)
}

const _: () = {
    assert!(std::mem::size_of::<ChunkInfo>() == abi::chunk_info_size);
    assert!(std::mem::offset_of!(ChunkInfo, next_) == 0);
    assert!(std::mem::offset_of!(ChunkInfo, cursor_) == 32);
    assert!(std::mem::offset_of!(ChunkInfo, prepared_) == 33);
    assert!(std::mem::offset_of!(ChunkInfo, lock_) == 36);
};

impl ChunkInfo {
    /// Total shm size: header + MAX_COUNT chunks of `chunk_size` bytes.
    pub const fn shm_size(chunk_size: usize) -> usize {
        std::mem::size_of::<ChunkInfo>() + MAX_COUNT * chunk_size
    }

    /// C++ id_pool::prepare()/init(): a fresh (zeroed) pool is "invalid" → build the
    /// free list `next_[i] = i+1`. Call under the lock.
    fn prepare(&mut self) {
        if self.prepared_ == 0 && self.cursor_ == 0 && self.next_[0] == 0 {
            for i in 0..MAX_COUNT {
                self.next_[i] = (i + 1) as u8;
            }
        }
        self.prepared_ = 1;
    }

    /// C++ id_pool::acquire(): id = cursor_; cursor_ = next_[id].
    fn acquire(&mut self) -> StorageId {
        if self.cursor_ as usize >= MAX_COUNT {
            return -1;
        }
        let id = self.cursor_ as StorageId;
        self.cursor_ = self.next_[id as usize];
        id
    }

    /// C++ id_pool::release(): next_[id] = cursor_; cursor_ = id.
    fn release(&mut self, id: StorageId) {
        if id < 0 || id as usize >= MAX_COUNT {
            return;
        }
        self.next_[id as usize] = self.cursor_;
        self.cursor_ = id as u8;
    }
}

/// Lock the chunk_info_t spin_lock: os_unfair_lock on Apple; on other targets the
/// C++ generic spin_lock — an atomic<u32> test-and-set spin (1 = locked, 0 = free),
/// byte-exact at lock_ @36 so a C++ peer and this port serialise pool access.
unsafe fn chunk_lock(info: &ChunkInfo) {
    #[cfg(target_vendor = "apple")]
    {
        libc::os_unfair_lock_lock(&info.lock_ as *const _ as *mut libc::os_unfair_lock);
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let mut k = 0u32;
        while info.lock_.swap(1, Ordering::Acquire) != 0 {
            crate::spin_lock::adaptive_yield_pub(&mut k);
        }
    }
}

unsafe fn chunk_unlock(info: &ChunkInfo) {
    #[cfg(target_vendor = "apple")]
    {
        libc::os_unfair_lock_unlock(&info.lock_ as *const _ as *mut libc::os_unfair_lock);
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        info.lock_.store(0, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// Chunk-size calculation — byte-exact with C++ calc_chunk_size
// ---------------------------------------------------------------------------

/// `calc_chunk_size(size) = ceil((CHUNK_HEADER + size) / CHUNK_ALIGN) * CHUNK_ALIGN`
/// (C++: make_align(8, align_chunk_size(make_align(8, sizeof(atomic<cc_t>)) + size))).
/// `size` is the message size. The chunk-shm name embeds this, so it must match C++.
pub fn calc_chunk_size(size: usize) -> usize {
    let x = CHUNK_HEADER + size;
    x.div_ceil(CHUNK_ALIGN) * CHUNK_ALIGN
}

// ---------------------------------------------------------------------------
// Process-local chunk shm cache
// ---------------------------------------------------------------------------

/// A cached chunk shm handle — wraps a `CachedShm` so same-process endpoints
/// share the same mmap (required for data coherency on macOS with MAP_SHARED).
#[cfg(unix)]
pub struct ChunkShmHandle {
    cached: Arc<CachedShm>,
    name: String,
}

#[cfg(unix)]
impl ChunkShmHandle {
    pub fn get(&self) -> *mut u8 {
        self.cached.shm.as_mut_ptr()
    }
}

#[cfg(unix)]
impl Drop for ChunkShmHandle {
    fn drop(&mut self) {
        cached_shm_release(chunk_cache(), &self.name);
    }
}

#[cfg(unix)]
fn chunk_cache() -> &'static std::sync::Mutex<crate::platform::posix::ShmCache> {
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<crate::platform::posix::ShmCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(crate::platform::posix::ShmCache::new()))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Chunk-shm name, byte-exact with C++ make_prefix(prefix, "CHUNK_INFO__", chunk_size).
/// `full_prefix` must be the prefix-global `"{prefix}__IPC_SHM__"` (NO channel name).
fn chunk_shm_name(full_prefix: &str, chunk_size: usize) -> String {
    format!("{full_prefix}CHUNK_INFO__{chunk_size}")
}

/// Open (or create) the chunk-storage shm for `chunk_size`-byte chunks.
#[cfg(unix)]
pub fn open_chunk_shm(full_prefix: &str, chunk_size: usize) -> io::Result<ChunkShmHandle> {
    let name = chunk_shm_name(full_prefix, chunk_size);
    let size = ChunkInfo::shm_size(chunk_size);
    let cached = cached_shm_acquire(chunk_cache(), &name, size, |_| Ok(()))?;
    Ok(ChunkShmHandle { cached, name })
}

#[cfg(not(unix))]
pub fn open_chunk_shm(full_prefix: &str, chunk_size: usize) -> io::Result<ShmHandle> {
    let name = chunk_shm_name(full_prefix, chunk_size);
    let size = ChunkInfo::shm_size(chunk_size);
    ShmHandle::acquire(&name, size, ShmOpenMode::CreateOrOpen)
}

/// C++ acquire_storage: allocate a chunk id, stamp its conns bitmask, return the
/// payload pointer. (Unused by the fragmenting send path; kept for symmetry.)
pub fn acquire_storage(base: *mut u8, chunk_size: usize, conns: u32) -> Option<(StorageId, *mut u8)> {
    let info = unsafe { &mut *(base as *mut ChunkInfo) };
    unsafe { chunk_lock(info) };
    info.prepare();
    let id = info.acquire();
    unsafe { chunk_unlock(info) };
    if id < 0 {
        return None;
    }
    let conns_ptr = unsafe { chunk_conns_ptr(base, chunk_size, id) };
    unsafe { (*conns_ptr).store(conns, Ordering::Relaxed) };
    Some((id, chunk_payload_ptr(base, chunk_size, id)))
}

/// C++ find_storage: pointer to the payload of chunk `id` (offset CHUNK_HEADER).
pub fn find_storage(base: *mut u8, chunk_size: usize, id: StorageId) -> Option<*mut u8> {
    if id < 0 || id as usize >= MAX_COUNT {
        return None;
    }
    Some(chunk_payload_ptr(base, chunk_size, id))
}

/// C++ recycle_storage / sub_rc<broadcast>: clear this receiver's bit from the
/// chunk's conns; when it reaches 0 (last reader), release the id to the pool.
pub fn recycle_storage(base: *mut u8, chunk_size: usize, id: StorageId, conn_id: u32) {
    if id < 0 || id as usize >= MAX_COUNT {
        return;
    }
    let conns = unsafe { &*chunk_conns_ptr(base, chunk_size, id) };
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
        unsafe { chunk_lock(info) };
        info.release(id);
        unsafe { chunk_unlock(info) };
    }
}

/// Remove the chunk-storage shm segment for `chunk_size`.
pub fn clear_chunk_shm(full_prefix: &str, chunk_size: usize) {
    let name = chunk_shm_name(full_prefix, chunk_size);
    #[cfg(unix)]
    cached_shm_purge(chunk_cache(), &name);
    ShmHandle::clear_storage(&name);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Pointer to chunk `id`'s conns bitmask (AtomicU32 @ start of the chunk).
unsafe fn chunk_conns_ptr(base: *mut u8, chunk_size: usize, id: StorageId) -> *mut AtomicU32 {
    let chunks_base = base.add(std::mem::size_of::<ChunkInfo>());
    chunks_base.add(chunk_size * id as usize) as *mut AtomicU32
}

/// Pointer to chunk `id`'s payload (after the CHUNK_HEADER-byte conns header).
fn chunk_payload_ptr(base: *mut u8, chunk_size: usize, id: StorageId) -> *mut u8 {
    unsafe {
        let chunks_base = base.add(std::mem::size_of::<ChunkInfo>());
        chunks_base.add(chunk_size * id as usize).add(CHUNK_HEADER)
    }
}
