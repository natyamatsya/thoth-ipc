// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/thoth_ipc/ipc.cpp: chunk_info_t / id_pool / acquire_storage /
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
// Chunk shm layout for a given `chunk_size` (name __THOTH_SHM__CHUNK_INFO__<size>):
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
    // @36 — C++ `thoth::spin_lock` (rw_lock.h): an atomic<u32> test-and-set spin,
    // 1 = locked, 0 = free, on every target including Apple. Verified by
    // compiling against the C++ headers rather than by reading them: the type is
    // `thoth::spin_lock`, and locking one writes 0x00000001.
    //
    // thoth has a *second* spin_lock at platform/apple/spin_lock.h wrapping
    // os_unfair_lock. It is a different type in a different namespace
    // (`thoth::detail::sync`), it is documented there as process-local, and
    // chunk_info_t does not use it — but three ports and the ABI notes had it
    // the other way round.
    //
    // What the mismatch actually cost is narrower than it looks. Both algorithms
    // acquire only from 0 and store non-zero, so they do exclude each other in
    // the uncontended case — `os_unfair_lock_trylock` over a TAS-held lock does
    // fail. The hazard is in the contended path: os_unfair_lock treats the field
    // as a thread token to park and donate priority on, and `1` is not one, in a
    // primitive Apple documents as unusable across processes. Matching the peer's
    // algorithm removes that rather than fixing an outright missing lock.
    lock_: AtomicU32,
}

const _: () = {
    assert!(std::mem::size_of::<ChunkInfo>() == abi::chunk_info_size);
    assert!(std::mem::offset_of!(ChunkInfo, next_) == abi::chunk_info_next_off);
    assert!(std::mem::offset_of!(ChunkInfo, cursor_) == abi::chunk_info_cursor_off);
    assert!(std::mem::offset_of!(ChunkInfo, prepared_) == abi::chunk_info_prepared_off);
    assert!(std::mem::offset_of!(ChunkInfo, lock_) == abi::chunk_info_lock_off);
};

impl ChunkInfo {
    /// Total shm size: header + MAX_COUNT chunks of `chunk_size` bytes.
    pub const fn shm_size(chunk_size: usize) -> usize {
        std::mem::size_of::<ChunkInfo>() + MAX_COUNT * chunk_size
    }

    /// C++ id_pool::prepare()/init(): a fresh (zeroed) pool is "invalid" → build the
    /// free list `next_[i] = i+1`. Call under the lock.
    ///
    /// "Fresh" means the whole structure compares equal to a zeroed one — C++
    /// `id_pool::invalid()` is a memcmp over all of it. Sampling only `next_[0]`
    /// is not the same rule: a partially written pool (a torn init, say) reads as
    /// fresh to that test and as used to C++, and the two would then disagree
    /// about whether to rebuild the free list. Caught by the conformance probe
    /// (`probe idpool-partial`), which is what it is for.
    fn prepare(&mut self) {
        if self.prepared_ == 0 && self.cursor_ == 0 && self.next_.iter().all(|&b| b == 0) {
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

/// Lock the chunk_info_t spin_lock — C++ `thoth::spin_lock`, an atomic<u32>
/// test-and-set spin (1 = locked, 0 = free) at lock_ @36, so a C++ peer and this
/// port serialise pool access against each other.
unsafe fn chunk_lock(info: &ChunkInfo) {
    let mut k = 0u32;
    while info.lock_.swap(1, Ordering::Acquire) != 0 {
        crate::spin_lock::adaptive_yield_pub(&mut k);
    }
}

unsafe fn chunk_unlock(info: &ChunkInfo) {
    info.lock_.store(0, Ordering::Release);
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

/// Chunk-shm name, byte-exact with C++ make_public_abi_prefix(prefix, "CHUNK_INFO__", chunk_size).
/// `full_prefix` must be the prefix-global `"{prefix}__THOTH_SHM__"` (NO channel name).
fn chunk_shm_name(full_prefix: &str, chunk_size: usize) -> String {
    format!("{full_prefix}CHUNK_INFO__{chunk_size}")
}

#[cfg(test)]
mod name_golden {
    use super::chunk_shm_name;
    use crate::abi_generated as abi;
    /// Byte-exact with the generated chunk-name golden (canonical chunk_size=1024;
    /// full_prefix = "" + "__THOTH_SHM__").
    #[test]
    fn chunk_shm_name_matches_generated_golden() {
        assert_eq!(chunk_shm_name("__THOTH_SHM__", 1024), abi::name_golden_chunk);
    }
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

// ---------------------------------------------------------------------------
// Conformance probe
// ---------------------------------------------------------------------------

/// Byte-level trace of the primitives whose *protocol* the ABI cannot express —
/// what the pool lock writes while held, and how the free list evolves. Every
/// port emits the same lines or one of them is wrong; C++ is the reference (see
/// `context/abi-consistency-review.md`).
///
/// No shared memory and no peer: the point is to compare implementations, not to
/// move data, and a local zeroed structure makes the trace deterministic.
pub mod conform {
    use super::{chunk_lock, chunk_unlock, ChunkInfo, MAX_COUNT};
    use std::sync::atomic::Ordering;

    fn dump(step: &str, info: &ChunkInfo, out: &mut Vec<String>) {
        let next: String = info.next_.iter().map(|b| format!("{b:02x}")).collect();
        out.push(format!(
            "step={step} next={next} cursor={:02x} prepared={:02x}",
            info.cursor_, info.prepared_
        ));
    }

    fn zeroed() -> ChunkInfo {
        // repr(C) over plain integers and an AtomicU32 — all-zero is a valid value
        // and is exactly the state a freshly created shm segment is in.
        unsafe { std::mem::zeroed() }
    }

    /// What the pool lock writes into its four bytes while held.
    pub fn spinlock() -> Vec<String> {
        let info = zeroed();
        let mut out = Vec::new();
        let raw = |i: &ChunkInfo| i.lock_.load(Ordering::Relaxed);
        out.push(format!("step=init bytes={:08x}", raw(&info)));
        unsafe { chunk_lock(&info) };
        out.push(format!("step=locked bytes={:08x}", raw(&info)));
        unsafe { chunk_unlock(&info) };
        out.push(format!("step=unlocked bytes={:08x}", raw(&info)));
        out
    }

    /// How the free list evolves across prepare / acquire / release.
    pub fn idpool() -> Vec<String> {
        let mut info = zeroed();
        let mut out = Vec::new();
        dump("zeroed", &info, &mut out);
        info.prepare();
        dump("prepared", &info, &mut out);
        for _ in 0..3 {
            let id = info.acquire();
            out.push(format!("step=acquire id={id}"));
        }
        dump("after-acquire3", &info, &mut out);
        info.release(1);
        dump("after-release1", &info, &mut out);
        let id = info.acquire();
        out.push(format!("step=acquire id={id}"));
        dump("after-reacquire", &info, &mut out);
        out
    }

    /// A pool that is not all-zero but whose first link is: C++ decides "already
    /// initialised" by comparing the *whole* structure against a zeroed one, so
    /// init() must not run here.
    pub fn idpool_partial() -> Vec<String> {
        let mut info = zeroed();
        info.next_[5] = 7;
        let mut out = Vec::new();
        dump("partial-before", &info, &mut out);
        info.prepare();
        dump("partial-after", &info, &mut out);
        out
    }

    /// Release on its own, from a pool seeded by writing its bytes rather than
    /// by calling prepare(). A port that implements only the receiving half of
    /// chunk storage still implements release, and this is the probe it can
    /// answer.
    pub fn idpool_release() -> Vec<String> {
        let mut info = zeroed();
        for i in 0..MAX_COUNT {
            info.next_[i] = (i + 1) as u8;
        }
        info.cursor_ = 3; // ids 0,1,2 handed out
        info.prepared_ = 1;
        let mut out = Vec::new();
        dump("seeded", &info, &mut out);
        info.release(1);
        dump("after-release1", &info, &mut out);
        info.release(0);
        dump("after-release0", &info, &mut out);
        out
    }

    /// `MAX_COUNT` is part of the trace's shape; assert the ports agree on it.
    pub const SLOTS: usize = MAX_COUNT;
}
