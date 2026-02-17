// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/rw_lock.h (rw_lock class).
// Single-word atomic read-write lock using bit flags.
// - High bit (w_flag) marks exclusive/write lock.
// - Low bits count concurrent shared/read locks.

use std::sync::atomic::{AtomicU32, Ordering};

/// Adaptive backoff (shared with spin_lock).
#[inline]
fn adaptive_yield(k: &mut u32) {
    if *k < 4 {
        // busy spin
    } else if *k < 16 {
        std::hint::spin_loop();
    } else if *k < 32 {
        std::thread::yield_now();
    } else {
        std::thread::sleep(std::time::Duration::from_millis(1));
        return;
    }
    *k += 1;
}

const W_MASK: u32 = i32::MAX as u32;   // 0x7FFF_FFFF — reader count mask
const W_FLAG: u32 = W_MASK + 1;        // 0x8000_0000 — writer flag

/// A single-word atomic read-write lock.
///
/// Port of `ipc::rw_lock` from cpp-ipc. Writers get exclusive access,
/// multiple readers can hold the lock concurrently.
///
/// The high bit signals a write lock; the remaining 31 bits count active readers.
pub struct RwLock {
    lc: AtomicU32,
}

impl RwLock {
    /// Create a new unlocked read-write lock.
    pub const fn new() -> Self {
        Self { lc: AtomicU32::new(0) }
    }

    /// Acquire an exclusive (write) lock.
    pub fn lock(&self) {
        let mut k = 0u32;
        loop {
            let old = self.lc.fetch_or(W_FLAG, Ordering::AcqRel);
            if old == 0 {
                return; // got w-lock, no readers
            }
            if old & W_FLAG == 0 {
                break; // readers present but no other writer — wait for them to finish
            }
            // another writer holds the lock, spin
            adaptive_yield(&mut k);
        }
        // Wait for all readers to finish
        let mut k = 0u32;
        while self.lc.load(Ordering::Acquire) & W_MASK != 0 {
            adaptive_yield(&mut k);
        }
    }

    /// Release the exclusive (write) lock.
    pub fn unlock(&self) {
        self.lc.store(0, Ordering::Release);
    }

    /// Acquire a shared (read) lock.
    pub fn lock_shared(&self) {
        let mut old = self.lc.load(Ordering::Acquire);
        let mut k = 0u32;
        loop {
            if old & W_FLAG != 0 {
                // writer is active, spin
                adaptive_yield(&mut k);
                old = self.lc.load(Ordering::Acquire);
            } else if self
                .lc
                .compare_exchange_weak(old, old + 1, Ordering::Release, Ordering::Relaxed)
                .is_ok()
            {
                return;
            } else {
                // CAS failed, `old` has been updated by compare_exchange_weak
                old = self.lc.load(Ordering::Acquire);
            }
        }
    }

    /// Release a shared (read) lock.
    pub fn unlock_shared(&self) {
        self.lc.fetch_sub(1, Ordering::Release);
    }
}

impl Default for RwLock {
    fn default() -> Self {
        Self::new()
    }
}

unsafe impl Send for RwLock {}
unsafe impl Sync for RwLock {}
