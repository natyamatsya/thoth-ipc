// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Optional allocator helpers.
//
// Feature flags:
//   bump_alloc — enables BumpArena (backed by bumpalo).
//   slab_pool  — enables SlabPool (backed by slab).
//
// Neither is wired into the hot path by default; they exist so benchmarks can
// compare allocation strategies for IpcBuffer-sized workloads.

// ---------------------------------------------------------------------------
// BumpArena — monotonic bump-pointer arena (mirrors monotonic_buffer_resource)
// ---------------------------------------------------------------------------

/// A thread-local bump-pointer arena backed by `bumpalo::Bump`.
///
/// Semantics mirror C++ `monotonic_buffer_resource`:
/// - `alloc_bytes` / `alloc_slice` never free individual allocations.
/// - `reset()` releases all memory at once (equivalent to `release()`).
///
/// The arena is **not** `Send`; use one per thread or wrap in a `Mutex`.
#[cfg(feature = "bump_alloc")]
pub struct BumpArena {
    bump: bumpalo::Bump,
}

#[cfg(feature = "bump_alloc")]
impl BumpArena {
    /// Create a new arena with the default initial capacity.
    pub fn new() -> Self {
        Self { bump: bumpalo::Bump::new() }
    }

    /// Create a new arena pre-allocated with `capacity` bytes.
    pub fn with_capacity(capacity: usize) -> Self {
        Self { bump: bumpalo::Bump::with_capacity(capacity) }
    }

    /// Allocate `len` uninitialised bytes aligned to `align`.
    ///
    /// # Panics
    /// Panics if `align` is not a power of two or if allocation fails.
    pub fn alloc_bytes(&self, len: usize, align: usize) -> &mut [u8] {
        let layout = std::alloc::Layout::from_size_align(len, align)
            .expect("invalid layout");
        let ptr = self.bump.alloc_layout(layout);
        unsafe { std::slice::from_raw_parts_mut(ptr.as_ptr(), len) }
    }

    /// Allocate space for a `Vec<u8>` of `len` bytes and copy `src` into it.
    /// The returned slice lives for the lifetime of the arena.
    pub fn alloc_slice_copy<'a>(&'a self, src: &[u8]) -> &'a [u8] {
        bumpalo::collections::Vec::from_iter_in(src.iter().copied(), &self.bump)
            .into_bump_slice()
    }

    /// Allocate a `bumpalo::collections::Vec<u8>` inside this arena.
    /// Useful for building messages without a separate heap allocation.
    pub fn alloc_vec(&self) -> bumpalo::collections::Vec<'_, u8> {
        bumpalo::collections::Vec::new_in(&self.bump)
    }

    /// Allocate a `bumpalo::collections::Vec<u8>` with pre-reserved capacity.
    pub fn alloc_vec_with_capacity(&self, cap: usize) -> bumpalo::collections::Vec<'_, u8> {
        bumpalo::collections::Vec::with_capacity_in(cap, &self.bump)
    }

    /// Release all allocations and reset the arena to its initial state.
    /// Equivalent to C++ `monotonic_buffer_resource::release()`.
    pub fn reset(&mut self) {
        self.bump.reset();
    }

    /// Total bytes currently allocated inside the arena.
    pub fn allocated_bytes(&self) -> usize {
        self.bump.allocated_bytes()
    }

    /// Expose the underlying `bumpalo::Bump` for direct use with bumpalo APIs.
    pub fn inner(&self) -> &bumpalo::Bump {
        &self.bump
    }
}

#[cfg(feature = "bump_alloc")]
impl Default for BumpArena {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// SlabPool — fixed-size object pool (mirrors block_pool / central_cache_pool)
// ---------------------------------------------------------------------------

/// A pool of fixed-size byte buffers backed by `slab::Slab`.
///
/// Semantics mirror C++ `block_pool<BlockSize, N>`:
/// - `insert` claims a slot and returns a stable key.
/// - `remove` returns the slot to the pool.
/// - The pool grows automatically (no fixed upper bound unlike the C++ shm version).
///
/// The pool is **not** `Send`; wrap in `Mutex` for shared use.
#[cfg(feature = "slab_pool")]
pub struct SlabPool<const BLOCK: usize> {
    slab: slab::Slab<[u8; BLOCK]>,
}

#[cfg(feature = "slab_pool")]
impl<const BLOCK: usize> SlabPool<BLOCK> {
    /// Create an empty pool.
    pub fn new() -> Self {
        Self { slab: slab::Slab::new() }
    }

    /// Create a pool pre-allocated for `capacity` entries.
    pub fn with_capacity(capacity: usize) -> Self {
        Self { slab: slab::Slab::with_capacity(capacity) }
    }

    /// Insert a zeroed block and return its stable key.
    pub fn insert_zeroed(&mut self) -> usize {
        self.slab.insert([0u8; BLOCK])
    }

    /// Insert a block initialised from `src` (truncated / zero-padded to `BLOCK`).
    pub fn insert_from_slice(&mut self, src: &[u8]) -> usize {
        let mut block = [0u8; BLOCK];
        let n = src.len().min(BLOCK);
        block[..n].copy_from_slice(&src[..n]);
        self.slab.insert(block)
    }

    /// Get a shared reference to the block at `key`.
    pub fn get(&self, key: usize) -> Option<&[u8; BLOCK]> {
        self.slab.get(key)
    }

    /// Get a mutable reference to the block at `key`.
    pub fn get_mut(&mut self, key: usize) -> Option<&mut [u8; BLOCK]> {
        self.slab.get_mut(key)
    }

    /// Return the block at `key` to the pool.
    pub fn remove(&mut self, key: usize) -> [u8; BLOCK] {
        self.slab.remove(key)
    }

    /// Number of occupied slots.
    pub fn len(&self) -> usize {
        self.slab.len()
    }

    /// Whether the pool has no occupied slots.
    pub fn is_empty(&self) -> bool {
        self.slab.is_empty()
    }

    /// Total capacity (occupied + free slots).
    pub fn capacity(&self) -> usize {
        self.slab.capacity()
    }
}

#[cfg(feature = "slab_pool")]
impl<const BLOCK: usize> Default for SlabPool<BLOCK> {
    fn default() -> Self {
        Self::new()
    }
}
