// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Lock-free single-producer single-consumer ring buffer over shared memory.
// Port of cpp-ipc/include/libipc/proto/shm_ring.h.
//
// T must be Copy + 'static (trivially copyable equivalent).
// N must be a power of two.

use std::io;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::{ShmHandle, ShmOpenMode};

// ---------------------------------------------------------------------------
// Shared memory layout (must match C++ `layout` struct)
// ---------------------------------------------------------------------------

/// Cache-line-padded header stored at the start of the SHM segment.
#[repr(C)]
struct Header {
    write_idx: AtomicU64,
    _pad0: [u8; 64 - 8],
    read_idx: AtomicU64,
    _pad1: [u8; 64 - 8],
    constructed: AtomicBool,
    _pad2: [u8; 64 - 1],
}

const _: () = assert!(std::mem::size_of::<Header>() == 192);

/// Lock-free SPSC ring buffer over a named shared memory segment.
///
/// - `T` must be `Copy` (trivially copyable).
/// - `N` must be a power of two (asserted at construction).
/// - One writer process calls [`write`] / [`write_overwrite`].
/// - One reader process calls [`read`].
///
/// Port of `ipc::proto::shm_ring<T, N>` from the C++ libipc library.
pub struct ShmRing<T: Copy + 'static, const N: usize> {
    shm: Option<ShmHandle>,
    name: String,
    _marker: PhantomData<T>,
}

impl<T: Copy + 'static, const N: usize> ShmRing<T, N> {
    const MASK: u64 = (N as u64) - 1;

    fn layout_size() -> usize {
        std::mem::size_of::<Header>() + std::mem::size_of::<T>() * N
    }

    /// Create a new ring backed by `name`. Does not open SHM yet.
    pub fn new(name: &str) -> Self {
        assert!((N & (N - 1)) == 0, "ShmRing capacity N must be a power of two");
        Self { shm: None, name: name.to_owned(), _marker: PhantomData }
    }

    /// Open or create the shared memory segment.
    pub fn open_or_create(&mut self) -> io::Result<()> {
        let shm = ShmHandle::acquire(&self.name, Self::layout_size(), ShmOpenMode::CreateOrOpen)?;
        let hdr = unsafe { &*(shm.get() as *const Header) };
        if !hdr.constructed.load(Ordering::Acquire) {
            hdr.write_idx.store(0, Ordering::Relaxed);
            hdr.read_idx.store(0, Ordering::Relaxed);
            unsafe {
                let slots_ptr = shm.get().add(std::mem::size_of::<Header>());
                std::ptr::write_bytes(slots_ptr, 0, std::mem::size_of::<T>() * N);
            }
            hdr.constructed.store(true, Ordering::Release);
        }
        self.shm = Some(shm);
        Ok(())
    }

    /// Open an existing segment (fails if not yet created).
    pub fn open_existing(&mut self) -> io::Result<bool> {
        let shm = ShmHandle::acquire(&self.name, Self::layout_size(), ShmOpenMode::Open)?;
        let hdr = unsafe { &*(shm.get() as *const Header) };
        let ready = hdr.constructed.load(Ordering::Acquire);
        self.shm = Some(shm);
        Ok(ready)
    }

    /// Close the handle (unmaps SHM; does not unlink the segment).
    pub fn close(&mut self) {
        self.shm = None;
    }

    /// Close and unlink the backing SHM segment.
    pub fn destroy(&mut self) {
        self.shm = None;
        ShmHandle::clear_storage(&self.name);
    }

    pub fn valid(&self) -> bool {
        self.shm.is_some()
    }

    // --- helpers ---

    fn hdr(&self) -> &Header {
        let shm = self.shm.as_ref().expect("ShmRing not open");
        unsafe { &*(shm.get() as *const Header) }
    }

    fn slot_ptr(&self, idx: u64) -> *mut T {
        let shm = self.shm.as_ref().expect("ShmRing not open");
        let base = unsafe { shm.get().add(std::mem::size_of::<Header>()) };
        unsafe { (base as *mut T).add((idx & Self::MASK) as usize) }
    }

    // --- Producer API (single writer) ---

    /// Return a pointer to the next writable slot, or `None` if the ring is full.
    /// Call [`write_commit`] after filling the slot.
    pub fn write_slot(&self) -> Option<*mut T> {
        let hdr = self.hdr();
        let w = hdr.write_idx.load(Ordering::Relaxed);
        let r = hdr.read_idx.load(Ordering::Acquire);
        if w.wrapping_sub(r) >= N as u64 {
            return None;
        }
        Some(self.slot_ptr(w))
    }

    /// Advance the write index after filling a slot obtained from [`write_slot`].
    pub fn write_commit(&self) {
        self.hdr().write_idx.fetch_add(1, Ordering::Release);
    }

    /// Write `item` into the next slot. Returns `false` if the ring is full.
    pub fn write(&self, item: &T) -> bool {
        match self.write_slot() {
            None => false,
            Some(slot) => {
                unsafe { std::ptr::copy_nonoverlapping(item as *const T, slot, 1) };
                self.write_commit();
                true
            }
        }
    }

    /// Write `item`, overwriting the oldest entry if the ring is full.
    pub fn write_overwrite(&self, item: &T) {
        let hdr = self.hdr();
        let w = hdr.write_idx.load(Ordering::Relaxed);
        let r = hdr.read_idx.load(Ordering::Acquire);
        if w.wrapping_sub(r) >= N as u64 {
            hdr.read_idx.store(r.wrapping_add(1), Ordering::Release);
        }
        let slot = self.slot_ptr(w);
        unsafe { std::ptr::copy_nonoverlapping(item as *const T, slot, 1) };
        hdr.write_idx.fetch_add(1, Ordering::Release);
    }

    // --- Consumer API (single reader) ---

    /// Return a pointer to the next readable slot, or `None` if the ring is empty.
    /// Call [`read_commit`] after consuming the slot.
    pub fn read_slot(&self) -> Option<*const T> {
        let hdr = self.hdr();
        let r = hdr.read_idx.load(Ordering::Relaxed);
        let w = hdr.write_idx.load(Ordering::Acquire);
        if r >= w {
            return None;
        }
        Some(self.slot_ptr(r) as *const T)
    }

    /// Advance the read index after consuming a slot from [`read_slot`].
    pub fn read_commit(&self) {
        self.hdr().read_idx.fetch_add(1, Ordering::Release);
    }

    /// Read the next item into `out`. Returns `false` if the ring is empty.
    pub fn read(&self, out: &mut T) -> bool {
        match self.read_slot() {
            None => false,
            Some(slot) => {
                unsafe { std::ptr::copy_nonoverlapping(slot, out as *mut T, 1) };
                self.read_commit();
                true
            }
        }
    }

    // --- Status ---

    /// Number of items currently available to read.
    pub fn available(&self) -> usize {
        let hdr = self.hdr();
        let w = hdr.write_idx.load(Ordering::Acquire);
        let r = hdr.read_idx.load(Ordering::Acquire);
        w.wrapping_sub(r) as usize
    }

    pub fn is_empty(&self) -> bool {
        self.available() == 0
    }

    pub fn is_full(&self) -> bool {
        self.available() >= N
    }
}
