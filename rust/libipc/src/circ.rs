// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/circ/elem_def.h + elem_array.h.
// Lock-free circular buffer primitives for shared-memory IPC.
//
// The circular buffer uses a fixed-size array of 256 elements (indices
// wrap via truncation to u8). Connection tracking uses a 32-bit bitmask,
// supporting up to 32 concurrent receivers in broadcast mode.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use crate::SpinLock;

/// Connection ID type — a 32-bit bitmask (broadcast) or counter (unicast).
pub type ConnId = u32;

/// Truncate a u32 cursor to an 8-bit ring index (0..=255).
#[inline]
pub const fn index_of(cursor: u32) -> u8 {
    cursor as u8
}

/// Maximum number of elements in the circular buffer (2^8 = 256).
pub const ELEM_MAX: usize = 256;

// ---------------------------------------------------------------------------
// ConnHead — connection tracking header stored at the start of the shared
// memory region, shared between all producers and consumers.
// ---------------------------------------------------------------------------

/// Broadcast-mode connection head.
/// Each receiver is assigned a unique bit in the bitmask.
#[repr(C)]
pub struct BroadcastConnHead {
    cc: AtomicU32,
    lock: SpinLock,
    constructed: AtomicBool,
}

impl BroadcastConnHead {
    /// Initialise (idempotent via DCLP).
    pub fn init(&self) {
        if !self.constructed.load(Ordering::Acquire) {
            self.lock.lock();
            if !self.constructed.load(Ordering::Relaxed) {
                self.cc.store(0, Ordering::Relaxed);
                self.constructed.store(true, Ordering::Release);
            }
            self.lock.unlock();
        }
    }

    /// Current connection bitmask.
    pub fn connections(&self, order: Ordering) -> ConnId {
        self.cc.load(order)
    }

    /// Connect a new receiver — finds the first zero bit and sets it.
    /// Returns the bit-mask for this receiver, or 0 if full.
    pub fn connect(&self) -> ConnId {
        let mut k = 0u32;
        loop {
            let curr = self.cc.load(Ordering::Acquire);
            let next = curr | (curr.wrapping_add(1)); // set first 0 bit
            if next == curr {
                return 0; // full
            }
            if self
                .cc
                .compare_exchange_weak(curr, next, Ordering::Release, Ordering::Relaxed)
                .is_ok()
            {
                return next ^ curr; // the bit we just set
            }
            crate::spin_lock::adaptive_yield_pub(&mut k);
        }
    }

    /// Disconnect a receiver by clearing its bits from the bitmask.
    /// Returns the resulting bitmask.
    pub fn disconnect(&self, cc_id: ConnId) -> ConnId {
        self.cc.fetch_and(!cc_id, Ordering::AcqRel) & !cc_id
    }

    /// Whether the given receiver is still connected.
    pub fn connected(&self, cc_id: ConnId) -> bool {
        (self.connections(Ordering::Acquire) & cc_id) != 0
    }

    /// Number of connected receivers (popcount of the bitmask).
    pub fn conn_count(&self, order: Ordering) -> usize {
        self.cc.load(order).count_ones() as usize
    }
}

/// Unicast-mode connection head.
/// Simple counter of connected receivers.
#[repr(C)]
pub struct UnicastConnHead {
    cc: AtomicU32,
    lock: SpinLock,
    constructed: AtomicBool,
}

impl UnicastConnHead {
    pub fn init(&self) {
        if !self.constructed.load(Ordering::Acquire) {
            self.lock.lock();
            if !self.constructed.load(Ordering::Relaxed) {
                self.cc.store(0, Ordering::Relaxed);
                self.constructed.store(true, Ordering::Release);
            }
            self.lock.unlock();
        }
    }

    pub fn connections(&self, order: Ordering) -> ConnId {
        self.cc.load(order)
    }

    pub fn connect(&self) -> ConnId {
        self.cc.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub fn disconnect(&self, cc_id: ConnId) -> ConnId {
        if cc_id == !0u32 {
            self.cc.store(0, Ordering::Relaxed);
            return 0;
        }
        self.cc.fetch_sub(1, Ordering::Relaxed) - 1
    }

    pub fn connected(&self, cc_id: ConnId) -> bool {
        (self.connections(Ordering::Acquire) != 0) && (cc_id != 0)
    }

    pub fn conn_count(&self, order: Ordering) -> usize {
        self.connections(order) as usize
    }
}
