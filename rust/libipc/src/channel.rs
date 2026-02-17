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
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use crate::buffer::IpcBuffer;
use crate::shm::{ShmHandle, ShmOpenMode};
use crate::waiter::Waiter;

/// Default data length per ring slot (matches C++ `ipc::data_length = 64`).
const DATA_LENGTH: usize = 64;

/// Number of ring slots (matches C++ `elem_max = 256`).
const RING_SIZE: usize = 256;

// ---------------------------------------------------------------------------
// Ring slot layout in shared memory
// ---------------------------------------------------------------------------

/// A single slot in the circular ring buffer.
/// Each slot holds a fixed-size payload and metadata for tracking reads.
#[repr(C)]
struct RingSlot {
    /// Message payload (up to DATA_LENGTH bytes).
    data: [u8; DATA_LENGTH],
    /// Actual size of data in this slot.
    size: AtomicU32,
    /// Read-counter: tracks which receivers have consumed this slot.
    /// In broadcast mode, each receiver clears its bit after reading.
    rc: AtomicU32,
}

/// Header of the shared ring buffer, followed by RING_SIZE `RingSlot`s.
#[repr(C)]
struct RingHeader {
    /// Connection bitmask: each receiver has one bit.
    connections: AtomicU32,
    /// Write cursor (only writer(s) advance this).
    write_cursor: AtomicU32,
    /// Number of connected senders (for multi-producer).
    sender_count: AtomicU32,
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
    conn_id: u32,      // bitmask for this receiver (0 for senders)
    read_cursor: u32,  // receiver's read position
    wt_waiter: Waiter, // write-side waiter (senders block here when ring is full)
    rd_waiter: Waiter, // read-side waiter (receivers block here when ring is empty)
    cc_waiter: Waiter, // connection waiter (wait_for_recv)
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

        let ring_shm = ShmHandle::acquire(&ring_name, ring_shm_size(), ShmOpenMode::CreateOrOpen)?;

        // No explicit init needed: fresh shm from shm_open is zero-filled,
        // and all header fields (write_cursor, connections, sender_count)
        // have correct initial value of 0.
        let hdr = unsafe { ring_header(ring_shm.get()) };

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
            read_cursor,
            wt_waiter,
            rd_waiter,
            cc_waiter,
        })
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
    /// Protocol:
    /// 1. CAS write_cursor to claim a slot index
    /// 2. Write payload + size into the claimed slot
    /// 3. Store rc = conns (Release) — signals receivers that data is ready
    fn send(&self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        if data.is_empty() {
            return Ok(false);
        }
        if self.mode != Mode::Sender {
            return Err(io::Error::new(io::ErrorKind::Other, "not a sender"));
        }

        let hdr = self.hdr();
        let conns = hdr.connections.load(Ordering::Acquire);
        if conns == 0 {
            return Ok(false); // no receivers
        }

        let mut offset = 0usize;
        while offset < data.len() {
            let chunk_len = std::cmp::min(DATA_LENGTH, data.len() - offset);
            let is_last = (offset + chunk_len) >= data.len();

            // Wait for a free slot using spin-then-wait
            let ring_ptr = self.ring_shm.get();
            let claimed_wt;
            loop {
                let wt = hdr.write_cursor.load(Ordering::Acquire);
                let idx = wt as u8;

                // Slot must be free (rc == 0) before we can reuse it.
                let slot = self.slot(idx);
                if slot.rc.load(Ordering::Acquire) != 0 {
                    let ok = Self::wait_for(
                        &self.wt_waiter,
                        || {
                            let s = unsafe { ring_slot(ring_ptr, wt as u8) };
                            s.rc.load(Ordering::Acquire) != 0
                        },
                        Some(timeout_ms),
                    )?;
                    if !ok {
                        return Ok(false); // timeout
                    }
                    continue; // re-read write_cursor
                }

                // Claim this slot (multi-producer safe via CAS).
                if hdr
                    .write_cursor
                    .compare_exchange_weak(
                        wt,
                        wt.wrapping_add(1),
                        Ordering::AcqRel,
                        Ordering::Relaxed,
                    )
                    .is_err()
                {
                    continue;
                }

                claimed_wt = wt;
                break;
            }

            // --- Slot is ours, write data ---
            let slot = self.slot(claimed_wt as u8);
            let slot_ptr = &slot.data as *const [u8; DATA_LENGTH] as *mut u8;
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr().add(offset), slot_ptr, chunk_len);
            }

            let size_val = if is_last {
                0x8000_0000 | (chunk_len as u32)
            } else {
                chunk_len as u32
            };
            slot.size.store(size_val, Ordering::Relaxed);

            // Publish: set rc = connection bitmask (Release barrier).
            // All writes above are visible to any thread that loads rc with Acquire.
            let current_conns = hdr.connections.load(Ordering::Relaxed);
            slot.rc.store(current_conns, Ordering::Release);

            offset += chunk_len;
        }

        let _ = self.rd_waiter.broadcast();
        Ok(true)
    }

    /// Try sending without blocking (timeout = 0).
    fn try_send(&self, data: &[u8]) -> io::Result<bool> {
        self.send(data, 0)
    }

    /// Receive a message. Returns empty buffer on timeout.
    ///
    /// Protocol:
    /// 1. Spin-then-wait until slot[read_cursor].rc & my_bit is set (Acquire)
    /// 2. Read size + payload
    /// 3. Clear my bit from rc; if last reader, slot becomes free
    fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        if self.mode != Mode::Receiver {
            return Err(io::Error::new(io::ErrorKind::Other, "not a receiver"));
        }

        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        let mut assembled = Vec::new();

        loop {
            let idx = self.read_cursor as u8;
            let slot = self.slot(idx);

            // Check if this slot has data for us (our bit is set in rc).
            if (slot.rc.load(Ordering::Acquire) & self.conn_id) == 0 {
                // Spin-then-wait for data
                let conn_id = self.conn_id;
                let ring_ptr = self.ring_shm.get();
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
                        let s = unsafe { ring_slot(ring_ptr, cur as u8) };
                        (s.rc.load(Ordering::Acquire) & conn_id) == 0
                    },
                    tm,
                )?;
                if !ok {
                    return Ok(IpcBuffer::new()); // timeout
                }
                continue; // re-check slot
            }

            // rc load above was Acquire, so data + size written by sender are visible.
            let size_val = slot.size.load(Ordering::Relaxed);
            let chunk_len = (size_val & 0x7FFF_FFFF) as usize;
            let is_last = (size_val & 0x8000_0000) != 0;

            let slot_ptr = &slot.data as *const [u8; DATA_LENGTH] as *const u8;
            let chunk = unsafe { std::slice::from_raw_parts(slot_ptr, chunk_len) };
            assembled.extend_from_slice(chunk);

            // Clear our bit from rc.
            let old_rc = slot.rc.fetch_and(!self.conn_id, Ordering::AcqRel);
            if (old_rc & !self.conn_id) == 0 {
                // Last reader — slot is now free, wake writers.
                let _ = self.wt_waiter.broadcast();
            }

            self.read_cursor = self.read_cursor.wrapping_add(1);

            if is_last {
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
    pub fn send(&self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(data, timeout_ms)
    }

    /// Send a buffer.
    pub fn send_buf(&self, buf: &IpcBuffer, timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Send a string (with null terminator for C++ compat).
    pub fn send_str(&self, s: &str, timeout_ms: u64) -> io::Result<bool> {
        let buf = IpcBuffer::from_str(s);
        self.send_buf(&buf, timeout_ms)
    }

    /// Try sending without blocking.
    pub fn try_send(&self, data: &[u8]) -> io::Result<bool> {
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
        Waiter::clear_storage(&format!("{full_prefix}WT_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}RD_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}CC_CONN__{name}"));
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
    pub fn send(&self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(data, timeout_ms)
    }

    /// Send a buffer.
    pub fn send_buf(&self, buf: &IpcBuffer, timeout_ms: u64) -> io::Result<bool> {
        self.inner.send(buf.data(), timeout_ms)
    }

    /// Send a string.
    pub fn send_str(&self, s: &str, timeout_ms: u64) -> io::Result<bool> {
        let buf = IpcBuffer::from_str(s);
        self.send_buf(&buf, timeout_ms)
    }

    /// Try sending without blocking.
    pub fn try_send(&self, data: &[u8]) -> io::Result<bool> {
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
