// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/rw_lock.h (spin_lock class).
// Lock-free spin lock with adaptive backoff: pause → yield → sleep.

use std::sync::atomic::{AtomicU32, Ordering};

/// Adaptive backoff matching the C++ `ipc::yield(k)` function.
///
/// - k < 4:  busy spin (do nothing)
/// - k < 16: CPU pause hint
/// - k < 32: thread yield
/// - k >= 32: sleep 1ms
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

/// Public (crate-internal) access to the adaptive yield for other modules.
#[inline]
pub(crate) fn adaptive_yield_pub(k: &mut u32) {
    adaptive_yield(k);
}

/// A simple spin lock with adaptive backoff.
///
/// Port of `ipc::spin_lock` from cpp-ipc. Uses an `AtomicU32` exchanged
/// to 1 on lock, stored to 0 on unlock, with adaptive yield between retries.
pub struct SpinLock {
    lc: AtomicU32,
}

impl SpinLock {
    /// Create a new unlocked spin lock.
    pub const fn new() -> Self {
        Self {
            lc: AtomicU32::new(0),
        }
    }

    /// Acquire the lock (spinning with adaptive backoff).
    pub fn lock(&self) {
        let mut k = 0u32;
        while self.lc.swap(1, Ordering::Acquire) != 0 {
            adaptive_yield(&mut k);
        }
    }

    /// Release the lock.
    pub fn unlock(&self) {
        self.lc.store(0, Ordering::Release);
    }
}

impl Default for SpinLock {
    fn default() -> Self {
        Self::new()
    }
}

// Safety: SpinLock is designed for concurrent access.
unsafe impl Send for SpinLock {}
unsafe impl Sync for SpinLock {}
