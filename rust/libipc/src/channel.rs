// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/ipc.h + ipc.cpp.
// IPC channels built on top of shared memory, condition variables, and
// a lock-free circular buffer.
//
// This provides two channel types:
// - `Route`   — single producer, multiple consumers (broadcast)
// - `Channel` — multiple producers, multiple consumers (broadcast)
//
// Messages are stored in a fixed-size circular buffer in shared memory.
// Small messages (≤ DATA_LENGTH bytes) are stored inline. Large messages
// are stored in a separate shared-memory "chunk" and only the chunk ID
// is placed in the ring slot.

use std::io;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::buffer::IpcBuffer;
use crate::chunk_storage as cs;
use crate::shm::{ShmHandle, ShmOpenMode};
use crate::waiter::Waiter;

/// Default data length per ring slot (matches C++ `ipc::data_length = 64`).
const DATA_LENGTH: usize = 64;

/// Bit 31 of `RingSlot::size`: this is the last fragment of a message.
const SIZE_LAST: u32 = 0x8000_0000;
/// Bit 30 of `RingSlot::size`: payload is a `storage_id` (large-message path).
const SIZE_STORAGE: u32 = 0x4000_0000;
/// Mask for the actual byte count stored in the low 30 bits of `size`.
const SIZE_MASK: u32 = 0x3FFF_FFFF;

/// Number of ring slots (matches C++ `elem_max = 256`).
const RING_SIZE: usize = 256;

// ---------------------------------------------------------------------------
// Ring slot layout in shared memory
// ---------------------------------------------------------------------------

/// A single slot in the circular ring buffer.
/// Each slot holds a fixed-size payload and metadata for tracking reads.
///
/// `rc` mirrors the C++ `prod_cons_impl<single,multi,broadcast>::elem_t::rc_`:
///   - low  32 bits (EP_MASK): connection bitmask — which receivers still need to read
///   - high 32 bits (~EP_MASK): epoch — generation counter written by the sender
///
/// A slot is free when `(rc & EP_MASK) == 0` OR the epoch in `rc` differs from the
/// sender's current epoch (stale bits from a previous generation).
#[repr(C)]
struct RingSlot {
    /// Message payload (up to DATA_LENGTH bytes).
    data: [u8; DATA_LENGTH],
    /// Actual size of data in this slot.
    size: AtomicU32,
    /// Sender identity stamp for self-message filtering (matches C++ msg_t::cc_id_).
    cc_id: AtomicU32,
    /// Read-counter + epoch packed into 64 bits (matches C++ rc_ field).
    rc: AtomicU64,
}

/// Bitmask for the connection bits in the 64-bit `rc` field (low 32 bits).
const EP_MASK: u64 = 0x0000_0000_ffff_ffff;
/// Increment for the epoch stored in the high 32 bits of `rc`.
const EP_INCR: u64 = 0x0000_0001_0000_0000;

/// Header of the shared ring buffer, followed by RING_SIZE `RingSlot`s.
#[repr(C)]
struct RingHeader {
    /// Connection bitmask: each receiver has one bit.
    connections: AtomicU32,
    /// Write cursor (only writer(s) advance this).
    write_cursor: AtomicU32,
    /// Number of connected senders (for multi-producer).
    sender_count: AtomicU32,
    /// Epoch counter — incremented by the sender on each force-push.
    /// Stored in the high 32 bits of each slot's `rc` to distinguish
    /// "slot is being read" from "slot was freed in a prior generation".
    epoch: AtomicU64,
}

/// Total shared memory size for the ring.
const fn ring_shm_size() -> usize {
    std::mem::size_of::<RingHeader>() + RING_SIZE * std::mem::size_of::<RingSlot>()
}

/// Get a pointer to the ring header from the shm base.
unsafe fn ring_header(base: *mut u8) -> &'static RingHeader {
    &*(base as *const RingHeader)
}

/// Get a pointer to slot `idx` from the shm base.
unsafe fn ring_slot(base: *mut u8, idx: u8) -> &'static RingSlot {
    let slots_base = base.add(std::mem::size_of::<RingHeader>());
    &*((slots_base as *const RingSlot).add(idx as usize))
}

// ---------------------------------------------------------------------------
// Connection mode
// ---------------------------------------------------------------------------

/// Whether this endpoint is a sender or receiver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Sender,
    Receiver,
}

// ---------------------------------------------------------------------------
// Shared implementation for Route and Channel
// ---------------------------------------------------------------------------

/// Internal channel state shared by `Route` and `Channel`.
struct ChanInner {
    name: String,
    _prefix: String,
    mode: Mode,
    ring_shm: ShmHandle,
    conn_id: u32,                 // bitmask for this receiver (0 for senders)
    cc_id: u32,                   // unique endpoint identity for self-message filtering
    read_cursor: u32,             // receiver's read position
    wt_waiter: Waiter,            // write-side waiter (senders block here when ring is full)
    rd_waiter: Waiter,            // read-side waiter (receivers block here when ring is empty)
    cc_waiter: Waiter,            // connection waiter (wait_for_recv)
    cc_id_shm: ShmHandle,         // shared atomic counter for cc_id allocation (CA_CONN__)
    chunk_shm: Option<ShmHandle>, // large-message chunk storage (CH_CONN__), lazily opened
}

impl ChanInner {
    fn open(prefix: &str, name: &str, mode: Mode) -> io::Result<Self> {
        let full_prefix = if prefix.is_empty() {
            String::new()
        } else {
            format!("{prefix}_")
        };
        let ring_name = format!("{full_prefix}QU_CONN__{name}");
        let wt_name = format!("{full_prefix}WT_CONN__{name}");
        let rd_name = format!("{full_prefix}RD_CONN__{name}");
        let cc_name = format!("{full_prefix}CC_CONN__{name}");
        let cc_id_name = format!("{full_prefix}CA_CONN__{name}");

        let ring_shm = ShmHandle::acquire(&ring_name, ring_shm_size(), ShmOpenMode::CreateOrOpen)?;
        let cc_id_shm = ShmHandle::acquire(
            &cc_id_name,
            std::mem::size_of::<u32>(),
            ShmOpenMode::CreateOrOpen,
        )?;

        // No explicit init needed: fresh shm from shm_open is zero-filled.
        let hdr = unsafe { ring_header(ring_shm.get()) };

        // Allocate a unique endpoint identity from the shared counter (mirrors C++ cc_acc()).
        let cc_id_atomic = unsafe { &*(cc_id_shm.get() as *const AtomicU32) };
        let mut cc_id = cc_id_atomic.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        if cc_id == 0 {
            cc_id = cc_id_atomic.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
        }

        let wt_waiter = Waiter::open(&wt_name)?;
        let rd_waiter = Waiter::open(&rd_name)?;
        let cc_waiter = Waiter::open(&cc_name)?;

        let mut conn_id = 0u32;
        let mut read_cursor = 0u32;

        match mode {
            Mode::Sender => {
                hdr.sender_count.fetch_add(1, Ordering::Relaxed);
            }
            Mode::Receiver => {
                // Allocate a bit in the connection bitmask
                let mut k = 0u32;
                loop {
                    let curr = hdr.connections.load(Ordering::Acquire);
                    let next = curr | curr.wrapping_add(1);
                    if next == curr {
                        return Err(io::Error::new(
                            io::ErrorKind::Other,
                            "too many receivers (max 32)",
                        ));
                    }
                    if hdr
                        .connections
                        .compare_exchange_weak(curr, next, Ordering::Release, Ordering::Relaxed)
                        .is_ok()
                    {
                        conn_id = next ^ curr;
                        break;
                    }
                    crate::spin_lock::adaptive_yield_pub(&mut k);
                }
                read_cursor = hdr.write_cursor.load(Ordering::Acquire);
                // Broadcast that a new receiver connected
                let _ = cc_waiter.broadcast();
            }
        }

        Ok(Self {
            name: name.to_string(),
            _prefix: full_prefix,
            mode,
            ring_shm,
            conn_id,
            cc_id,
            read_cursor,
            wt_waiter,
            rd_waiter,
            cc_waiter,
            cc_id_shm,
            chunk_shm: None,
        })
    }

    /// Open (or return cached) the chunk-storage shm for `chunk_size`-byte chunks.
    fn chunk_shm(&mut self, chunk_size: usize) -> Option<&ShmHandle> {
        if self.chunk_shm.is_none() {
            let shm = cs::open_chunk_shm(&self._prefix, chunk_size).ok()?;
            self.chunk_shm = Some(shm);
        }
        self.chunk_shm.as_ref()
    }

    fn hdr(&self) -> &RingHeader {
        unsafe { ring_header(self.ring_shm.get()) }
    }

    fn slot(&self, idx: u8) -> &RingSlot {
        unsafe { ring_slot(self.ring_shm.get(), idx) }
    }

    /// Number of connected receivers.
    fn recv_count(&self) -> usize {
        self.hdr().connections.load(Ordering::Acquire).count_ones() as usize
    }

    /// Wait until there are at least `count` receivers, with optional timeout.
    fn wait_for_recv(&self, count: usize, timeout_ms: Option<u64>) -> io::Result<bool> {
        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        loop {
            if self.recv_count() >= count {
                return Ok(true);
            }
            if let Some(dl) = deadline {
                let remaining = dl.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Ok(false);
                }
                self.cc_waiter.wait_if(
                    || self.recv_count() < count,
                    Some(remaining.as_millis() as u64),
                )?;
            } else {
                self.cc_waiter.wait_if(|| self.recv_count() < count, None)?;
            }
            if self.recv_count() >= count {
                return Ok(true);
            }
        }
    }

    /// Spin-then-wait helper matching the C++ `wait_for` + `ipc::sleep` pattern.
    /// Spins/yields up to `SPIN_COUNT` times, then falls back to the condition
    /// variable. Returns `false` on timeout, `true` when `pred` returns `false`.
    fn wait_for<F>(waiter: &Waiter, pred: F, timeout_ms: Option<u64>) -> io::Result<bool>
    where
        F: Fn() -> bool,
    {
        const SPIN_COUNT: u32 = 32;

        if matches!(timeout_ms, Some(0)) {
            return Ok(!pred());
        }

        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        let mut k = 0u32;

        while pred() {
            if k < SPIN_COUNT {
                std::thread::yield_now();
                k += 1;
            } else {
                // Fall back to condition variable
                let tm = deadline
                    .map(|dl| dl.saturating_duration_since(Instant::now()).as_millis() as u64);
                if matches!(tm, Some(0)) {
                    return Ok(false); // deadline passed during spin
                }
                let ok = waiter.wait_if(&pred, tm)?;
                if !ok {
                    return Ok(false); // timeout
                }
                k = 0; // reset spin counter after wakeup, re-check pred
            }
        }
        Ok(true)
    }

    /// Send data. Returns `true` if sent successfully.
    ///
    /// Mirrors C++ push + force_push:
    /// 1. CAS `rc` from (stale or zero) to `epoch | cc` — claims the slot.
    /// 2. Write cc_id + data + size into the claimed slot.
    /// 3. `write_cursor.fetch_add(1, Release)` — "data ready" signal for receivers.
    /// 4. Broadcast rd_waiter per fragment.
    /// On timeout: increment epoch, disconnect stale receivers, retry (force_push).
    fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        if data.is_empty() {
            return Ok(false);
        }
        if self.mode != Mode::Sender {
            return Err(io::Error::new(io::ErrorKind::Other, "not a sender"));
        }

        // Large-message fast path: store in chunk shm, push a single slot with storage_id.
        // Mirrors C++: `if (size > large_msg_limit) { acquire_storage(...) }`
        if data.len() > DATA_LENGTH {
            match self.send_large(data, timeout_ms)? {
                Some(result) => return Ok(result),
                None => {} // storage unavailable — fall through to fragmentation
            }
        }

        let hdr = self.hdr();
        let ring_ptr = self.ring_shm.get();

        let mut offset = 0usize;
        while offset < data.len() {
            let chunk_len = std::cmp::min(DATA_LENGTH, data.len() - offset);
            let is_last = (offset + chunk_len) >= data.len();

            // Spin-then-wait until we can CAS-claim the next slot.
            // On timeout, force_push: bump epoch + disconnect stale receivers.
            let claimed_wt: u32;
            'claim: loop {
                let cc = hdr.connections.load(Ordering::Relaxed) as u64;
                if cc == 0 {
                    return Ok(false); // no receivers
                }

                let epoch = hdr.epoch.load(Ordering::Relaxed);
                let wt = hdr.write_cursor.load(Ordering::Relaxed);
                let slot = unsafe { ring_slot(ring_ptr, wt as u8) };
                let cur_rc = slot.rc.load(Ordering::Acquire);
                let rem_cc = cur_rc & EP_MASK;

                // Slot is busy if remaining readers overlap current connections
                // AND the epoch in rc matches the current epoch (same generation).
                if (cc & rem_cc) != 0 && (cur_rc & !EP_MASK) == epoch {
                    let ok = Self::wait_for(
                        &self.wt_waiter,
                        || {
                            let s = unsafe { ring_slot(ring_ptr, wt as u8) };
                            let rc = s.rc.load(Ordering::Acquire);
                            let ep = hdr.epoch.load(Ordering::Relaxed);
                            (cc & (rc & EP_MASK)) != 0 && (rc & !EP_MASK) == ep
                        },
                        Some(timeout_ms),
                    )?;
                    if ok {
                        continue 'claim;
                    }
                    // Timeout — force_push: bump epoch, disconnect stale receivers.
                    // Mirrors C++ force_push: epoch_ += ep_incr, disconnect_receiver(rem_cc).
                    hdr.epoch.fetch_add(EP_INCR, Ordering::AcqRel);
                    let cur_rc2 = slot.rc.load(Ordering::Acquire);
                    let rem_cc2 = cur_rc2 & EP_MASK;
                    if rem_cc2 != 0 {
                        // Disconnect all receivers still blocking this slot.
                        let new_cc = hdr
                            .connections
                            .fetch_and(!(rem_cc2 as u32), Ordering::AcqRel)
                            & !(rem_cc2 as u32);
                        if new_cc == 0 {
                            return Ok(false); // no receivers left
                        }
                        // Clear stale bits from the slot's rc so we can claim it.
                        slot.rc.fetch_and(!rem_cc2, Ordering::AcqRel);
                    }
                    continue 'claim;
                }

                // Atomically claim the slot: set rc = epoch | cc.
                let new_rc = epoch | cc;
                if slot
                    .rc
                    .compare_exchange_weak(cur_rc, new_rc, Ordering::Release, Ordering::Relaxed)
                    .is_ok()
                {
                    claimed_wt = wt;
                    break 'claim;
                }
                std::thread::yield_now();
            }

            // --- Slot is claimed: write cc_id, data, size, then advance write_cursor ---
            let slot = self.slot(claimed_wt as u8);
            slot.cc_id.store(self.cc_id, Ordering::Relaxed);

            let slot_ptr = &slot.data as *const [u8; DATA_LENGTH] as *mut u8;
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr().add(offset), slot_ptr, chunk_len);
            }

            let size_val = if is_last {
                SIZE_LAST | (chunk_len as u32)
            } else {
                chunk_len as u32
            };
            slot.size.store(size_val, Ordering::Relaxed);

            // Advance write cursor with Release — "data ready" signal for receivers.
            hdr.write_cursor.fetch_add(1, Ordering::Release);

            offset += chunk_len;

            // Wake receivers after each fragment (matches C++ per-fragment broadcast).
            let _ = self.rd_waiter.broadcast();
        }

        Ok(true)
    }

    /// Large-message send path: store `data` in a chunk-storage shm slot and
    /// push a single ring slot containing the `storage_id`.
    ///
    /// Returns `Ok(true)` on success, `Ok(false)` if storage is unavailable
    /// (caller should fall back to fragmentation), or an error.
    ///
    /// Mirrors C++ `acquire_storage` + single `try_push(remain, &dat.first, 0)`.
    fn send_large(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<Option<bool>> {
        let chunk_size = cs::calc_chunk_size(data.len());

        // Open (or reuse) the chunk shm — do this before borrowing hdr.
        let shm: *const ShmHandle = match self.chunk_shm(chunk_size) {
            Some(s) => s as *const ShmHandle,
            None => return Ok(None), // storage unavailable, fall back
        };
        let shm = unsafe { &*shm };

        let hdr = self.hdr();
        let conns = hdr.connections.load(Ordering::Relaxed);

        let (storage_id, payload_ptr) = match cs::acquire_storage(shm, chunk_size, conns) {
            Some(pair) => pair,
            None => return Ok(None), // pool exhausted, fall back to fragmentation
        };

        // Copy payload into the chunk.
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), payload_ptr, data.len());
        }

        // Push a single ring slot: data = storage_id (i32, 4 bytes), size has STORAGE|LAST flags.
        let ring_ptr = self.ring_shm.get();
        let claimed_wt: u32;
        'claim: loop {
            let cc = hdr.connections.load(Ordering::Relaxed) as u64;
            if cc == 0 {
                cs::recycle_storage(shm, chunk_size, storage_id, !0u32);
                return Ok(Some(false));
            }
            let epoch = hdr.epoch.load(Ordering::Relaxed);
            let wt = hdr.write_cursor.load(Ordering::Relaxed);
            let slot = unsafe { ring_slot(ring_ptr, wt as u8) };
            let cur_rc = slot.rc.load(Ordering::Acquire);
            let rem_cc = cur_rc & EP_MASK;

            if (cc & rem_cc) != 0 && (cur_rc & !EP_MASK) == epoch {
                let ok = Self::wait_for(
                    &self.wt_waiter,
                    || {
                        let s = unsafe { ring_slot(ring_ptr, wt as u8) };
                        let rc = s.rc.load(Ordering::Acquire);
                        let ep = hdr.epoch.load(Ordering::Relaxed);
                        (cc & (rc & EP_MASK)) != 0 && (rc & !EP_MASK) == ep
                    },
                    Some(timeout_ms),
                )?;
                if ok {
                    continue 'claim;
                }
                hdr.epoch.fetch_add(EP_INCR, Ordering::AcqRel);
                let cur_rc2 = slot.rc.load(Ordering::Acquire);
                let rem_cc2 = cur_rc2 & EP_MASK;
                if rem_cc2 != 0 {
                    let new_cc = hdr
                        .connections
                        .fetch_and(!(rem_cc2 as u32), Ordering::AcqRel)
                        & !(rem_cc2 as u32);
                    if new_cc == 0 {
                        cs::recycle_storage(shm, chunk_size, storage_id, !0u32);
                        return Ok(Some(false));
                    }
                    slot.rc.fetch_and(!rem_cc2, Ordering::AcqRel);
                }
                continue 'claim;
            }
            let new_rc = epoch | cc;
            if slot
                .rc
                .compare_exchange_weak(cur_rc, new_rc, Ordering::Release, Ordering::Relaxed)
                .is_ok()
            {
                claimed_wt = wt;
                break 'claim;
            }
            std::thread::yield_now();
        }

        let slot = self.slot(claimed_wt as u8);
        slot.cc_id.store(self.cc_id, Ordering::Relaxed);

        // Write storage_id (bytes 0..4) and payload_size (bytes 4..8) into the slot.
        // The receiver uses payload_size to reconstruct chunk_size and find the chunk shm.
        let slot_ptr = &slot.data as *const [u8; DATA_LENGTH] as *mut u8;
        unsafe {
            std::ptr::copy_nonoverlapping(storage_id.to_ne_bytes().as_ptr(), slot_ptr, 4);
            std::ptr::copy_nonoverlapping(
                (data.len() as u32).to_ne_bytes().as_ptr(),
                slot_ptr.add(4),
                4,
            );
        }

        // size = LAST | STORAGE | 8  (8 = sizeof(storage_id) + sizeof(payload_size))
        slot.size
            .store(SIZE_LAST | SIZE_STORAGE | 8, Ordering::Relaxed);

        hdr.write_cursor.fetch_add(1, Ordering::Release);
        let _ = self.rd_waiter.broadcast();

        Ok(Some(true))
    }

    /// Try sending without blocking (timeout = 0).
    fn try_send(&mut self, data: &[u8]) -> io::Result<bool> {
        self.send(data, 0)
    }

    /// Receive a message. Returns empty buffer on timeout.
    ///
    /// Mirrors C++ pop + self-message filtering:
    /// 1. Wait until `write_cursor > read_cursor` (Acquire) — data-ready signal.
    /// 2. Skip slots sent by this endpoint (cc_id match).
    /// 3. Read data + size from the slot.
    /// 4. CAS-clear our bit from rc (low 32 only, preserve epoch in high 32).
    /// 5. Unconditionally broadcast wt_waiter after every pop (matches C++ recv).
    fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        if self.mode != Mode::Receiver {
            return Err(io::Error::new(io::ErrorKind::Other, "not a receiver"));
        }

        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        let mut assembled = Vec::new();
        let conn_mask = self.conn_id as u64;

        loop {
            let hdr = self.hdr();
            let ring_ptr = self.ring_shm.get();

            // Data is ready when write_cursor has advanced past our read_cursor.
            // Mirrors C++: `if (cur == cursor()) return false;`
            if hdr.write_cursor.load(Ordering::Acquire) == self.read_cursor {
                let cur = self.read_cursor;

                let tm = match deadline {
                    Some(dl) => {
                        let remaining = dl.saturating_duration_since(Instant::now());
                        if remaining.is_zero() {
                            return Ok(IpcBuffer::new());
                        }
                        Some(remaining.as_millis() as u64)
                    }
                    None => None,
                };

                let ok = Self::wait_for(
                    &self.rd_waiter,
                    || {
                        let h = unsafe { ring_header(ring_ptr) };
                        h.write_cursor.load(Ordering::Acquire) == cur
                    },
                    tm,
                )?;
                if !ok {
                    return Ok(IpcBuffer::new()); // timeout
                }
                continue; // re-check
            }

            // write_cursor Acquire synchronises with fetch_add Release in send,
            // making cc_id, data, and size writes visible.
            // Use ring_ptr directly (not self.slot()) so there is no &self borrow
            // that would conflict with the &mut self call to chunk_shm() below.
            let idx = self.read_cursor as u8;
            let size_val;
            let chunk_len;
            let is_last;
            let is_storage;
            let is_own;
            let storage_id: cs::StorageId;
            let payload_size: usize;
            let inline_data: Option<Vec<u8>>;
            unsafe {
                let slot = ring_slot(ring_ptr, idx);
                size_val = slot.size.load(Ordering::Relaxed);
                chunk_len = (size_val & SIZE_MASK) as usize;
                is_last = (size_val & SIZE_LAST) != 0;
                is_storage = (size_val & SIZE_STORAGE) != 0;
                is_own = slot.cc_id.load(Ordering::Relaxed) == self.cc_id;

                if is_storage {
                    let slot_ptr = slot.data.as_ptr();
                    let mut id_bytes = [0u8; 4];
                    let mut sz_bytes = [0u8; 4];
                    std::ptr::copy_nonoverlapping(slot_ptr, id_bytes.as_mut_ptr(), 4);
                    std::ptr::copy_nonoverlapping(slot_ptr.add(4), sz_bytes.as_mut_ptr(), 4);
                    storage_id = cs::StorageId::from_ne_bytes(id_bytes);
                    payload_size = u32::from_ne_bytes(sz_bytes) as usize;
                    inline_data = None;
                } else {
                    let chunk = std::slice::from_raw_parts(slot.data.as_ptr(), chunk_len);
                    storage_id = 0;
                    payload_size = 0;
                    inline_data = Some(chunk.to_vec());
                }
            }
            // No &self borrow is live here — safe to call &mut self methods.

            if !is_own {
                if is_storage {
                    let chunk_size = cs::calc_chunk_size(payload_size);
                    let shm_ptr: *const ShmHandle = match self.chunk_shm(chunk_size) {
                        Some(s) => s as *const ShmHandle,
                        None => std::ptr::null(),
                    };
                    if !shm_ptr.is_null() {
                        let shm = unsafe { &*shm_ptr };
                        if let Some(payload_ptr) = cs::find_storage(shm, chunk_size, storage_id) {
                            let payload = unsafe {
                                std::slice::from_raw_parts(payload_ptr as *const u8, payload_size)
                            };
                            assembled.extend_from_slice(payload);
                        }
                        cs::recycle_storage(shm, chunk_size, storage_id, self.conn_id);
                    }
                } else if let Some(data) = inline_data {
                    assembled.extend_from_slice(&data);
                }
            }

            // CAS-clear our bit from the low 32 bits of rc, preserving the epoch.
            // Re-derive the slot pointer from ring_ptr to avoid holding a self borrow.
            let mut k = 0u32;
            loop {
                let slot = unsafe { ring_slot(ring_ptr, idx) };
                let cur_rc = slot.rc.load(Ordering::Acquire);
                let nxt_rc = cur_rc & !conn_mask;
                if slot
                    .rc
                    .compare_exchange_weak(cur_rc, nxt_rc, Ordering::Release, Ordering::Relaxed)
                    .is_ok()
                {
                    break;
                }
                crate::spin_lock::adaptive_yield_pub(&mut k);
            }

            // Unconditionally wake writers after every pop (matches C++ recv behaviour).
            let _ = self.wt_waiter.broadcast();

            self.read_cursor = self.read_cursor.wrapping_add(1);

            if is_last {
                if is_own {
                    assembled.clear();
                    return Ok(IpcBuffer::new());
                }
                return Ok(IpcBuffer::from_vec(assembled));
            }
        }
    }

    /// Try receiving without blocking.
    fn try_recv(&mut self) -> io::Result<IpcBuffer> {
        self.recv(Some(0))
    }
}

impl Drop for ChanInner {
    fn drop(&mut self) {
        let hdr = self.hdr();
        match self.mode {
            Mode::Sender => {
                hdr.sender_count.fetch_sub(1, Ordering::Relaxed);
            }
            Mode::Receiver => {
                hdr.connections.fetch_and(!self.conn_id, Ordering::AcqRel);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Route — single producer, multi consumer (broadcast)
// ---------------------------------------------------------------------------

/// A single-producer, multi-consumer broadcast IPC channel.
///
/// One `Route` in `Sender` mode sends messages that are received by all
/// `Route` instances in `Receiver` mode with the same name.
///
/// Port of `ipc::route` from the C++ library.
pub struct Route {
    inner: ChanInner,
}

impl Route {
    /// Connect to a named route as either sender or receiver.
    pub fn connect(name: &str, mode: Mode) -> io::Result<Self> {
        Self::connect_with_prefix("", name, mode)
    }

    /// Connect with a prefix.
    pub fn connect_with_prefix(prefix: &str, name: &str, mode: Mode) -> io::Result<Self> {
        let inner = ChanInner::open(prefix, name, mode)?;
        Ok(Self { inner })
    }

    /// The channel name.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// Current mode (sender or receiver).
    pub fn mode(&self) -> Mode {
        self.inner.mode
    }

    /// Number of connected receivers.
    pub fn recv_count(&self) -> usize {
        self.inner.recv_count()
    }

    /// Wait until at least `count` receivers are connected.
    pub fn wait_for_recv(&self, count: usize, timeout_ms: Option<u64>) -> io::Result<bool> {
        self.inner.wait_for_recv(count, timeout_ms)
    }

    /// Send data (sender only). Returns `true` on success.
    pub fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(data, timeout_ms)
    }

    /// Send a buffer.
    pub fn send_buf(&mut self, buf: &IpcBuffer, timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Send a string (with null terminator for C++ compat).
    pub fn send_str(&mut self, s: &str, timeout_ms: u64) -> io::Result<bool> {
        let buf = IpcBuffer::from_str(s);
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Try sending without blocking.
    pub fn try_send(&mut self, data: &[u8]) -> io::Result<bool> {
        self.inner.try_send(data)
    }

    /// Receive a message (receiver only). Returns empty buffer on timeout.
    pub fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        self.inner.recv(timeout_ms)
    }

    /// Try receiving without blocking.
    pub fn try_recv(&mut self) -> io::Result<IpcBuffer> {
        self.inner.try_recv()
    }

    /// Remove all backing storage for a named route.
    pub fn clear_storage(name: &str) {
        Self::clear_storage_with_prefix("", name);
    }

    /// Remove all backing storage with a prefix.
    pub fn clear_storage_with_prefix(prefix: &str, name: &str) {
        let full_prefix = if prefix.is_empty() {
            String::new()
        } else {
            format!("{prefix}_")
        };
        ShmHandle::clear_storage(&format!("{full_prefix}QU_CONN__{name}"));
        ShmHandle::clear_storage(&format!("{full_prefix}CA_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}WT_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}RD_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}CC_CONN__{name}"));
        // Remove any chunk-storage shm segments (one per chunk_size that was ever used).
        // We don't know which chunk sizes were used, so we sweep common sizes.
        for &payload_size in &[128usize, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
            cs::clear_chunk_shm(&full_prefix, cs::calc_chunk_size(payload_size));
        }
    }
}

// ---------------------------------------------------------------------------
// Channel — multi producer, multi consumer (broadcast)
// ---------------------------------------------------------------------------

/// A multi-producer, multi-consumer broadcast IPC channel.
///
/// Multiple `Channel` instances in `Sender` mode can send messages to
/// all `Channel` instances in `Receiver` mode with the same name.
///
/// Port of `ipc::channel` from the C++ library.
///
/// Note: internally uses the same ring buffer mechanism as `Route`.
/// The multi-producer safety is achieved via CAS on the write cursor.
pub struct Channel {
    inner: ChanInner,
}

impl Channel {
    /// Connect to a named channel as either sender or receiver.
    pub fn connect(name: &str, mode: Mode) -> io::Result<Self> {
        Self::connect_with_prefix("", name, mode)
    }

    /// Connect with a prefix.
    pub fn connect_with_prefix(prefix: &str, name: &str, mode: Mode) -> io::Result<Self> {
        let inner = ChanInner::open(prefix, name, mode)?;
        Ok(Self { inner })
    }

    /// The channel name.
    pub fn name(&self) -> &str {
        &self.inner.name
    }

    /// Current mode.
    pub fn mode(&self) -> Mode {
        self.inner.mode
    }

    /// Number of connected receivers.
    pub fn recv_count(&self) -> usize {
        self.inner.recv_count()
    }

    /// Wait until at least `count` receivers are connected.
    pub fn wait_for_recv(&self, count: usize, timeout_ms: Option<u64>) -> io::Result<bool> {
        self.inner.wait_for_recv(count, timeout_ms)
    }

    /// Send data (sender only).
    pub fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(data, timeout_ms)
    }

    /// Send a buffer.
    pub fn send_buf(&mut self, buf: &IpcBuffer, timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Send a string.
    pub fn send_str(&mut self, s: &str, timeout_ms: u64) -> io::Result<bool> {
        let buf = IpcBuffer::from_str(s);
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Try sending without blocking.
    pub fn try_send(&mut self, data: &[u8]) -> io::Result<bool> {
        self.inner.try_send(data)
    }

    /// Receive a message (receiver only).
    pub fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        self.inner.recv(timeout_ms)
    }

    /// Try receiving without blocking.
    pub fn try_recv(&mut self) -> io::Result<IpcBuffer> {
        self.inner.try_recv()
    }

    /// Remove all backing storage for a named channel.
    pub fn clear_storage(name: &str) {
        Self::clear_storage_with_prefix("", name);
    }

    /// Remove all backing storage with a prefix.
    pub fn clear_storage_with_prefix(prefix: &str, name: &str) {
        Route::clear_storage_with_prefix(prefix, name);
    }
}
