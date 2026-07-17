// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
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

use std::cell::UnsafeCell;
use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::time::{Duration, Instant};

use crate::abi_generated as abi;
use crate::buffer::IpcBuffer;
use crate::chunk_storage as cs;
#[cfg(unix)]
use crate::chunk_storage::ChunkShmHandle;
use crate::shm::{ShmHandle, ShmOpenMode};
use crate::waiter::Waiter;

/// Default data length per ring slot (matches C++ `ipc::data_length = 64`).
const DATA_LENGTH: usize = abi::data_length;
/// Ring element alignment folded into the shm name, matching C++'s queue
/// `AlignSize = min(DataSize, alignof(std::max_align_t))`, byte-identical to C++
/// per target: 8 on Apple arm64, 16 on x86-64 / Linux aarch64, and **8 on
/// windows-msvc** (MSVC `alignof(std::max_align_t)` == 8 on x64/arm64, verified
/// against the C++ build — NOT 16). `libc` is unix-only, so Windows uses an
/// explicit constant rather than `libc::max_align_t`.
const RING_ALIGN: usize = {
    #[cfg(unix)]
    let a = std::mem::align_of::<libc::max_align_t>();
    #[cfg(windows)]
    let a = 8usize;
    if DATA_LENGTH < a { DATA_LENGTH } else { a }
};

/// Number of ring slots (matches C++ `elem_max = 256`). The slot index is the
/// write cursor truncated to u8 (wraps at 256); also used directly in the
/// channel `recv_multi` next-lap free-flag arithmetic.
const RING_SIZE: usize = abi::ring_size;

// ---------------------------------------------------------------------------
// Ring slot layout in shared memory
// ---------------------------------------------------------------------------

/// A ring slot — byte-exact with the C++ broadcast `elem_t<DataSize=80,Align=8>`:
/// `{ data_[80]; rc_ }` (88 bytes). `data_` holds a `msg_t<64,8>` (see msg_* below).
///
/// `rc_` mirrors `prod_cons_impl<single,multi,broadcast>::elem_t::rc_`:
///   - low  32 bits (EP_MASK): connection bitmask — which receivers still must read
///   - high 32 bits (~EP_MASK): epoch — generation counter written by the sender
/// A slot is free when `(rc_ & EP_MASK) == 0` OR its epoch differs from the writer's.
///
/// `data_` is an `UnsafeCell` (`#[repr(transparent)]`, so the byte layout is
/// unchanged): a slot lives in shared memory and is written through a shared
/// `&ElemT`, which would be UB against a plain `[u8; N]`. Cross-slot exclusion is
/// enforced by the `rc_` protocol, not the Rust borrow checker.
#[repr(C, align(8))]
struct ElemT {
    data_: UnsafeCell<[u8; MSG_SIZE]>, // holds a msg_t<64,8>
    rc_: AtomicU64,
}

/// Size of `msg_t<64,8>`: 16-byte header + 64-byte payload.
const MSG_SIZE: usize = abi::msg_t_size;
// Field offsets within `ElemT.data_` (a msg_t<64,8>), byte-exact with C++ ipc.cpp.
const MSG_CC_ID: usize = abi::msg_t_cc_id_off; // u32  sender identity (self-message filter)
const MSG_ID: usize = abi::msg_t_id_off; // u32  message id (fragment grouping)
const MSG_REMAIN: usize = abi::msg_t_remain_off; // i32  bytes remaining AFTER this fragment
const MSG_STORAGE: usize = abi::msg_t_storage_off; // u8   payload is a storage_id (large-message path)
const MSG_PAYLOAD: usize = abi::msg_t_payload_off; // [u8; 64] fragment payload

// Compile-time guard: the Rust struct must match the generated ABI layout.
const _: () = {
    assert!(std::mem::size_of::<ElemT>() == abi::route_elem_size);
    assert!(std::mem::align_of::<ElemT>() == 8);
    assert!(std::mem::offset_of!(ElemT, rc_) == abi::route_elem_rc_off);
};

impl ElemT {
    /// Write the msg_t header + payload into this slot's `data_`.
    unsafe fn write_msg(&self, cc_id: u32, id: u32, remain: i32, storage: bool, payload: &[u8]) {
        let p = self.data_.get().cast::<u8>();
        std::ptr::copy_nonoverlapping(cc_id.to_ne_bytes().as_ptr(), p.add(MSG_CC_ID), 4);
        std::ptr::copy_nonoverlapping(id.to_ne_bytes().as_ptr(), p.add(MSG_ID), 4);
        std::ptr::copy_nonoverlapping(remain.to_ne_bytes().as_ptr(), p.add(MSG_REMAIN), 4);
        p.add(MSG_STORAGE).write(if storage { 1 } else { 0 });
        std::ptr::copy_nonoverlapping(payload.as_ptr(), p.add(MSG_PAYLOAD), payload.len());
    }
    /// Read the msg_t header: (cc_id, id, remain, storage).
    unsafe fn read_header(&self) -> (u32, u32, i32, bool) {
        let p = self.data_.get().cast::<u8>();
        let mut b = [0u8; 4];
        std::ptr::copy_nonoverlapping(p.add(MSG_CC_ID), b.as_mut_ptr(), 4);
        let cc_id = u32::from_ne_bytes(b);
        std::ptr::copy_nonoverlapping(p.add(MSG_ID), b.as_mut_ptr(), 4);
        let id = u32::from_ne_bytes(b);
        std::ptr::copy_nonoverlapping(p.add(MSG_REMAIN), b.as_mut_ptr(), 4);
        let remain = i32::from_ne_bytes(b);
        let storage = p.add(MSG_STORAGE).read() != 0;
        (cc_id, id, remain, storage)
    }
    /// Copy `n` payload bytes out of this slot.
    unsafe fn read_payload(&self, n: usize) -> Vec<u8> {
        let p = self.data_.get().cast::<u8>().add(MSG_PAYLOAD);
        std::slice::from_raw_parts(p, n).to_vec()
    }
    /// Read the storage_id (i32) a large-message fragment carries in its payload.
    unsafe fn read_storage_id(&self) -> i32 {
        let p = self.data_.get().cast::<u8>().add(MSG_PAYLOAD);
        let mut b = [0u8; 4];
        std::ptr::copy_nonoverlapping(p, b.as_mut_ptr(), 4);
        i32::from_ne_bytes(b)
    }
}

/// Bitmask for the connection bits in the 64-bit `rc` field (low 32 bits).
const EP_MASK: u64 = abi::route_ep_mask;
/// Increment for the epoch stored in the high 32 bits of `rc`.
const EP_INCR: u64 = abi::route_ep_incr;

// ---------------------------------------------------------------------------
// Multi-writer channel ring (C++ prod_cons_impl<multi,multi,broadcast>)
// ---------------------------------------------------------------------------
// Byte-exact with C++/Zig (context/xlang-channel-multiwriter-rfc.md): a 96-byte
// slot with an `f_ct_` commit flag, a commit index `ct_` (reusing the header's
// write_cursor slot), and a 3-region `rc_` packing. Same shm NAME as route; the
// two are distinguished by layout, so a Channel opens the ring at the larger
// size. Reuses the route header, waiters, liveness, chunk-storage and msg_t
// framing unchanged.

/// Multi-writer channel slot: the route slot plus a per-slot `f_ct_` commit flag.
/// `data_` is an `UnsafeCell` for the same reason as `ElemT` (interior mutation
/// through a shared `&ChannelElemT`); `#[repr(transparent)]` keeps the layout.
#[repr(C, align(8))]
struct ChannelElemT {
    data_: UnsafeCell<[u8; MSG_SIZE]>,
    rc_: AtomicU64,
    f_ct_: AtomicU64,
}
const _: () = {
    assert!(std::mem::size_of::<ChannelElemT>() == abi::channel_elem_size);
    assert!(std::mem::offset_of!(ChannelElemT, rc_) == abi::channel_elem_rc_off);
    assert!(std::mem::offset_of!(ChannelElemT, f_ct_) == abi::channel_elem_f_ct_off);
};

impl ChannelElemT {
    unsafe fn write_msg(&self, cc_id: u32, id: u32, remain: i32, storage: bool, payload: &[u8]) {
        let p = self.data_.get().cast::<u8>();
        std::ptr::copy_nonoverlapping(cc_id.to_ne_bytes().as_ptr(), p.add(MSG_CC_ID), 4);
        std::ptr::copy_nonoverlapping(id.to_ne_bytes().as_ptr(), p.add(MSG_ID), 4);
        std::ptr::copy_nonoverlapping(remain.to_ne_bytes().as_ptr(), p.add(MSG_REMAIN), 4);
        p.add(MSG_STORAGE).write(if storage { 1 } else { 0 });
        std::ptr::copy_nonoverlapping(payload.as_ptr(), p.add(MSG_PAYLOAD), payload.len());
    }
    unsafe fn read_header(&self) -> (u32, u32, i32, bool) {
        let p = self.data_.get().cast::<u8>();
        let mut b = [0u8; 4];
        std::ptr::copy_nonoverlapping(p.add(MSG_CC_ID), b.as_mut_ptr(), 4);
        let cc_id = u32::from_ne_bytes(b);
        std::ptr::copy_nonoverlapping(p.add(MSG_ID), b.as_mut_ptr(), 4);
        let id = u32::from_ne_bytes(b);
        std::ptr::copy_nonoverlapping(p.add(MSG_REMAIN), b.as_mut_ptr(), 4);
        let remain = i32::from_ne_bytes(b);
        let storage = p.add(MSG_STORAGE).read() != 0;
        (cc_id, id, remain, storage)
    }
    unsafe fn read_payload(&self, n: usize) -> Vec<u8> {
        std::slice::from_raw_parts(self.data_.get().cast::<u8>().add(MSG_PAYLOAD), n).to_vec()
    }
    unsafe fn read_storage_id(&self) -> i32 {
        let mut b = [0u8; 4];
        std::ptr::copy_nonoverlapping(self.data_.get().cast::<u8>().add(MSG_PAYLOAD), b.as_mut_ptr(), 4);
        i32::from_ne_bytes(b)
    }
}

/// Total channel ring shm size — sizeof(C++ elem_array<multi,80,8>) on Apple arm64
/// (verified by the abi conformance dumper).
const CHANNEL_RING_SHM_SIZE: usize = abi::channel_ring_size;

// Channel `rc_` 3-region packing (C++ prod_cons.h multi-multi enum).
const RC_MASK: u64 = abi::chan_rc_mask; // low 32: per-reader "needs to read" bitmask
const CH_EP_MASK: u64 = abi::chan_ep_mask; // low 56: rc bits + internal read-generation
const CH_EP_INCR: u64 = abi::chan_ep_incr; // epoch increment (top byte)
const CH_IC_MASK: u64 = abi::chan_ic_mask; // invert-carry mask
const CH_IC_INCR: u64 = abi::chan_ic_incr; // internal read-generation increment (bits 32..)
const _: () = {
    // CH_EP_INCR is documentation of the top-byte epoch step; unused directly here
    // (force_push is not implemented in the matrix's live-reader path).
    assert!(CH_EP_INCR != 0);
};

#[inline]
fn inc_rc(rc: u64) -> u64 {
    (rc & CH_IC_MASK) | (rc.wrapping_add(CH_IC_INCR) & !CH_IC_MASK)
}
#[inline]
fn inc_mask(rc: u64) -> u64 {
    inc_rc(rc) & !RC_MASK
}

/// Get channel slot `idx` (96-byte stride), at C++ `block_` (offset 192).
unsafe fn channel_slot(base: *mut u8, idx: u8) -> &'static ChannelElemT {
    &*((base.add(OFF_BLOCK) as *const ChannelElemT).add(idx as usize))
}

/// Header of the shared ring buffer, byte-exact with the C++ `elem_array` head
/// so C++ and the Rust port share the same shm object (see
/// `context/xlang-channel-abi.md`). Layout on a 64-bit target:
///
/// ```text
///   0  connections  AtomicU32   == C++ conn_head_base::cc_ (connection bitmask)
///   4  lc           os_unfair_lock == C++ conn_head_base::lc_ (Apple spin_lock)
///   8  constructed  AtomicU8    == C++ conn_head_base::constructed_ (DCLP flag)
///  64  write_cursor AtomicU32   == C++ prod_cons head_.wt_  (alignas cache line)
/// 128  epoch        AtomicU64   == C++ prod_cons head_.epoch_ (alignas cache line)
/// 136  sender_count AtomicU32   Rust-internal (lives in C++ padding; C++ ignores)
/// ```
///
/// **Cross-language ABI — do not reorder without changing C++/Swift in lockstep.**
#[repr(C)]
struct RingHeader {
    connections: AtomicU32,        // @0
    #[cfg(target_vendor = "apple")]
    lc: libc::os_unfair_lock,      // @4 (C++ spin_lock = os_unfair_lock on Apple)
    #[cfg(not(target_vendor = "apple"))]
    lc: AtomicU32,                 // @4 (C++ generic spin_lock = atomic<u32> TAS-spin)
    constructed: AtomicU8,         // @8
    _pad_a: [u8; 55],              // @9..64
    write_cursor: AtomicU32,       // @64
    _pad_b: [u8; 60],              // @68..128
    epoch: AtomicU64,              // @128
    sender_count: AtomicU32,       // @136
    _pad_c: [u8; 52],              // @140..192
}

/// Total ring shm size — byte-exact `sizeof(C++ elem_array<broadcast,80,8>)` on
/// Apple arm64 (see spec §2). Includes C++'s trailing sender-flag region so the
/// mapping matches. TODO(xlang): compute per-target from the slot geometry.
const RING_SHM_SIZE: usize = abi::route_ring_size;

/// Total shared memory size for the ring.
const fn ring_shm_size() -> usize {
    RING_SHM_SIZE
}

// Compile-time guard: the header must match the C++ conn_head_base + head_ offsets.
const _: () = {
    assert!(std::mem::size_of::<RingHeader>() == abi::ring_header_size);
    assert!(std::mem::offset_of!(RingHeader, connections) == abi::ring_header_cc_off);
    assert!(std::mem::offset_of!(RingHeader, lc) == abi::ring_header_lc_off);
    assert!(std::mem::offset_of!(RingHeader, constructed) == abi::ring_header_constructed_off);
    assert!(std::mem::offset_of!(RingHeader, write_cursor) == abi::ring_header_cursor_off);
    assert!(std::mem::offset_of!(RingHeader, epoch) == abi::ring_header_epoch_off);
};

/// C++ `conn_head_base::init()` — a double-checked-locking construct via the
/// header's `os_unfair_lock`. Initialises the ring header exactly once across
/// processes/languages; without it a C++ peer that sees `constructed_ == 0`
/// would placement-new (zero) the header, wiping a connection bit this port set.
///
/// # Safety
/// `hdr` must point into a valid, mapped ring shm region.
unsafe fn init_header(hdr: &RingHeader) {
    if hdr.constructed.load(Ordering::Acquire) != 0 {
        return;
    }
    #[cfg(target_vendor = "apple")]
    {
        let lc = &hdr.lc as *const libc::os_unfair_lock as *mut libc::os_unfair_lock;
        libc::os_unfair_lock_lock(lc);
        if hdr.constructed.load(Ordering::Relaxed) == 0 {
            // Fresh shm is zero-filled (cc_ already 0); publish constructed_. (We do
            // not re-zero lc_ while holding it, unlike C++'s placement-new — the
            // resulting bytes are identical: lc_ ends unlocked, constructed_ = 1.)
            hdr.connections.store(0, Ordering::Relaxed);
            hdr.constructed.store(1, Ordering::Release);
        }
        libc::os_unfair_lock_unlock(lc);
    }
    // Non-Apple: DCLP under C++'s generic spin_lock (rw_lock.h) — an atomic<u32>
    // test-and-set spin (1 = locked, 0 = free), byte-exact at lc_ @4 so a C++ peer
    // and this port serialise the first-init critical section identically.
    #[cfg(not(target_vendor = "apple"))]
    {
        let mut k = 0u32;
        while hdr.lc.swap(1, Ordering::Acquire) != 0 {
            crate::spin_lock::adaptive_yield_pub(&mut k);
        }
        if hdr.constructed.load(Ordering::Relaxed) == 0 {
            hdr.connections.store(0, Ordering::Relaxed);
            hdr.constructed.store(1, Ordering::Release);
        }
        hdr.lc.store(0, Ordering::Release);
    }
}

/// Get a pointer to the ring header from the shm base.
unsafe fn ring_header(base: *mut u8) -> &'static RingHeader {
    &*(base as *const RingHeader)
}

/// Get slot `idx`. Slots start at offset 192 (== C++ block_) with an 88-byte
/// stride (`sizeof(ElemT)`), byte-exact with the C++ elem_array.
unsafe fn ring_slot(base: *mut u8, idx: u8) -> &'static ElemT {
    let slots_base = base.add(OFF_BLOCK);
    &*((slots_base as *const ElemT).add(idx as usize))
}

/// Offset of the first ring slot (C++ `block_`): after conn_head_base + head_.
const OFF_BLOCK: usize = abi::ring_header_size;

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
    prefix: String,  // original prefix (before full_prefix expansion)
    _prefix: String, // chunk_prefix = "{full_prefix}{name}_"
    mode: Mode,
    ring_shm: ShmHandle,
    conn_id: u32,          // bitmask for this receiver (0 for senders)
    cc_id: u32,            // unique endpoint identity for self-message filtering
    read_cursor: u32,      // receiver's read position
    send_seq: u32,         // route: per-sender msg_t.id_ counter (fragment grouping)
    multi: bool,           // true = multi-writer channel ring (96B slot, ct_/f_ct_)
    ac_id_shm: Option<ShmHandle>, // channel: shared per-channel AC_CONN__ msg-id counter
    recv_cache: HashMap<u32, (usize, Vec<u8>)>, // id_ -> (fill offset, buffer) reassembly
    wt_waiter: Waiter,     // write-side waiter (senders block here when ring is full)
    rd_waiter: Waiter,     // read-side waiter (receivers block here when ring is empty)
    cc_waiter: Waiter,     // connection waiter (wait_for_recv)
    _cc_id_shm: ShmHandle, // shared atomic counter for cc_id allocation (kept alive for counter lifetime)
    #[cfg(unix)]
    #[allow(dead_code)]
    chunk_shm: HashMap<usize, ChunkShmHandle>, // large-message chunk storage (CH_CONN__), keyed by chunk_size
    #[cfg(not(unix))]
    chunk_shm: HashMap<usize, ShmHandle>, // large-message chunk storage (CH_CONN__), keyed by chunk_size
    disconnected: bool, // true after explicit disconnect()
    // Layer 1 (opt-in `notify` feature): on send, poke the per-channel readiness
    // notifier so an async receiver (e.g. a C++ async_recv reactor) wakes.
    #[cfg(feature = "notify")]
    notify_source: crate::notify::NotifySource,
    // Reader side: a readiness fd woken by any-language sender's notify. Exposed
    // via native_wait_handle() for async integration.
    #[cfg(feature = "notify")]
    notify_sink: crate::notify::NotifySink,
    // Dead-connection reaper owner table (LV_CONN__); kept mapped for the endpoint's
    // lifetime. Receivers record their {pid, start_token} here so a reaper can
    // reclaim the slot if the process dies.
    #[allow(dead_code)]
    liveness_shm: ShmHandle,
}

impl ChanInner {
    fn open(prefix: &str, name: &str, mode: Mode, multi: bool) -> io::Result<Self> {
        // Byte-exact with C++ make_prefix: prefix + "__IPC_SHM__" + TAG + name;
        // the ring additionally carries the __<DataSize>__<AlignSize> geometry.
        let full_prefix = format!("{prefix}__IPC_SHM__");
        // chunk_prefix includes the channel name so each channel has isolated chunk storage.
        let chunk_prefix = format!("{full_prefix}{name}_");
        let ring_name = format!("{full_prefix}QU_CONN__{name}__{DATA_LENGTH}__{RING_ALIGN}");
        let wt_name = format!("{full_prefix}WT_CONN__{name}");
        let rd_name = format!("{full_prefix}RD_CONN__{name}");
        let cc_name = format!("{full_prefix}CC_CONN__{name}");
        // cc_id endpoint-identity counter is PREFIX-GLOBAL (no channel name) —
        // byte-exact with C++ cc_acc(prefix) = "__IPC_SHM__CA_CONN__". A
        // per-channel counter would collide a C++ sender's cc_id with a Rust
        // receiver's and the receiver would drop every message as "self".
        let cc_id_name = format!("{full_prefix}CA_CONN__");
        // Dead-connection reaper owner table (byte-exact with C++ LV_CONN__).
        let lv_name = format!("{full_prefix}LV_CONN__{name}");

        // Channel and route share the ring NAME but not the size/layout: the
        // multi-writer ring has 96-byte slots (24832 B total) vs the route's 88.
        let ring_size = if multi { CHANNEL_RING_SHM_SIZE } else { ring_shm_size() };
        let ring_shm = ShmHandle::acquire(&ring_name, ring_size, ShmOpenMode::CreateOrOpen)?;
        let cc_id_shm = ShmHandle::acquire(
            &cc_id_name,
            std::mem::size_of::<u32>(),
            ShmOpenMode::CreateOrOpen,
        )?;
        // Multi-writer channels draw msg_t.id_ from a SHARED per-channel counter
        // (C++ AC_CONN__<name>) so two concurrent writers never collide in the
        // receiver's reassembly cache. Route uses a process-local send_seq.
        let ac_id_shm = if multi {
            Some(ShmHandle::acquire(
                &format!("{full_prefix}AC_CONN__{name}"),
                std::mem::size_of::<u32>(),
                ShmOpenMode::CreateOrOpen,
            )?)
        } else {
            None
        };
        let liveness_shm =
            ShmHandle::acquire(&lv_name, crate::liveness::LIVENESS_SHM_SIZE, ShmOpenMode::CreateOrOpen)?;
        let liveness_ptr = liveness_shm.get() as *mut crate::liveness::ConnLiveness;

        // Byte-exact DCLP header init (C++ conn_head_base::init), so a C++ peer
        // does not re-zero the header and wipe our connection bit.
        let hdr = unsafe { ring_header(ring_shm.get()) };
        unsafe { init_header(hdr) };

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
                // Reclaim slots held by dead peers before claiming one (byte-exact
                // with C++ reap-on-connect). PID-liveness; a slot whose owner is
                // unknown (pid==0) or alive is left untouched.
                let live = hdr.connections.load(Ordering::Acquire);
                crate::liveness::reap_dead_receivers(liveness_ptr, live, |bit| {
                    hdr.connections.fetch_and(!bit, Ordering::AcqRel);
                });
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
                // Record ownership so a reaper can reclaim this slot if we die.
                crate::liveness::set_owner(liveness_ptr, conn_id);
                read_cursor = hdr.write_cursor.load(Ordering::Acquire);
                // Broadcast that a new receiver connected
                let _ = cc_waiter.broadcast();
            }
        }

        Ok(Self {
            name: name.to_string(),
            prefix: prefix.to_string(),
            _prefix: chunk_prefix,
            mode,
            ring_shm,
            conn_id,
            cc_id,
            read_cursor,
            send_seq: 0,
            multi,
            ac_id_shm,
            recv_cache: HashMap::new(),
            wt_waiter,
            rd_waiter,
            cc_waiter,
            _cc_id_shm: cc_id_shm,
            chunk_shm: HashMap::new(),
            disconnected: false,
            liveness_shm,
            #[cfg(feature = "notify")]
            notify_source: crate::notify::NotifySource::new(),
            // Registered lazily on the first native_wait_handle() call so the
            // connect/recv hot path stays zero-cost for blocking receivers even
            // when the feature is compiled in.
            #[cfg(feature = "notify")]
            notify_sink: crate::notify::NotifySink::new(),
        })
    }

    /// Layer 1: this receiver's readiness fd (or -1), woken on every matching
    /// enqueue. Multiplex it on epoll/kqueue/AsyncFd instead of a blocking recv.
    /// The sink is registered lazily on first call (byte-exact with C++
    /// notify_open_sink(connected_id); conn_id is this receiver's slot bit).
    #[cfg(feature = "notify")]
    fn native_wait_handle(&mut self) -> crate::notify::WaitHandle {
        use crate::notify::INVALID_WAIT_HANDLE;
        if self.mode != Mode::Receiver {
            return INVALID_WAIT_HANDLE;
        }
        if !self.notify_sink.valid() {
            self.notify_sink.open(&self.prefix, &self.name, self.conn_id);
        }
        if self.notify_sink.valid() {
            self.notify_sink.native_handle()
        } else {
            INVALID_WAIT_HANDLE
        }
    }

    /// Drain pending readiness tokens after the fd signalled (level-triggered).
    #[cfg(feature = "notify")]
    fn drain_wait_handle(&self) {
        self.notify_sink.drain();
    }

    /// Open (or return cached) the chunk-storage shm for `chunk_size`-byte chunks.
    /// Returns a raw pointer to the shm base (valid for the lifetime of the handle in the map).
    fn chunk_shm_base(&mut self, chunk_size: usize) -> Option<*mut u8> {
        if !self.chunk_shm.contains_key(&chunk_size) {
            // Prefix-global chunk-shm name (no channel name), byte-exact with
            // C++ make_prefix(prefix, "CHUNK_INFO__", chunk_size).
            let full_prefix = format!("{}__IPC_SHM__", self.prefix);
            let shm = cs::open_chunk_shm(&full_prefix, chunk_size).ok()?;
            self.chunk_shm.insert(chunk_size, shm);
        }
        self.chunk_shm.get(&chunk_size).map(|h| h.get())
    }

    fn hdr(&self) -> &RingHeader {
        unsafe { ring_header(self.ring_shm.get()) }
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

    /// Send `data` (sender only). Fragments into msg_t records, byte-exact with
    /// C++ ipc.cpp send(): each fragment carries `remain_ = size - offset -
    /// data_length` (≤0 on the final fragment, signalling "last").
    ///
    /// NOTE: no chunk-storage fast path yet, so all sizes fragment. C++ uses
    /// storage for >64B, so cross-language interop is currently ≤64B (single
    /// fragment); Rust↔Rust works for all sizes via fragmentation.
    fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        if data.is_empty() {
            return Ok(false);
        }
        if self.mode != Mode::Sender {
            return Err(io::Error::other("not a sender"));
        }
        if self.hdr().connections.load(Ordering::Relaxed) == 0 {
            return Ok(false); // no receivers
        }
        let size = data.len();
        // Multi-writer: shared AC_CONN__ counter; route: process-local send_seq.
        let msg_id = if self.multi {
            let atomic = unsafe { &*(self.ac_id_shm.as_ref().unwrap().get() as *const AtomicU32) };
            atomic.fetch_add(1, Ordering::Relaxed)
        } else {
            let m = self.send_seq;
            self.send_seq = self.send_seq.wrapping_add(1);
            m
        };

        // Full data_length-sized fragments.
        let full = size / DATA_LENGTH;
        let mut offset = 0usize;
        for _ in 0..full {
            let remain = size as i32 - offset as i32 - DATA_LENGTH as i32;
            if !self.push_fragment(msg_id, remain, &data[offset..offset + DATA_LENGTH], timeout_ms)? {
                return Ok(false);
            }
            offset += DATA_LENGTH;
        }
        // Trailing partial fragment (remain_ becomes negative → last).
        let tail = size - offset; // 0..DATA_LENGTH
        if tail > 0 {
            let remain = tail as i32 - DATA_LENGTH as i32;
            if !self.push_fragment(msg_id, remain, &data[offset..], timeout_ms)? {
                return Ok(false);
            }
        }
        // Layer 1: wake any async receiver parked on the readiness fd (byte-exact
        // with C++ notify_signal — a no-op when the `notify` feature is off).
        #[cfg(feature = "notify")]
        {
            let conns = self.hdr().connections.load(Ordering::Relaxed);
            self.notify_source
                .signal(&self.prefix, &self.name, conns, self.conn_id);
        }
        Ok(true)
    }

    /// Claim the next ring slot (C++ prod_cons broadcast push / force_push) and
    /// write one msg_t fragment, then advance wt_ and wake receivers.
    fn push_fragment(&self, msg_id: u32, remain: i32, payload: &[u8], timeout_ms: u64) -> io::Result<bool> {
        if self.multi {
            return self.push_fragment_multi(msg_id, remain, payload, timeout_ms);
        }
        let hdr = self.hdr();
        let ring_ptr = self.ring_shm.get();
        let claimed_wt: u32;
        'claim: loop {
            let cc = hdr.connections.load(Ordering::Relaxed) as u64;
            if cc == 0 {
                return Ok(false); // no receivers
            }
            let epoch = hdr.epoch.load(Ordering::Relaxed);
            let wt = hdr.write_cursor.load(Ordering::Relaxed);
            let slot = unsafe { ring_slot(ring_ptr, wt as u8) };
            let cur_rc = slot.rc_.load(Ordering::Acquire);
            let rem_cc = cur_rc & EP_MASK;
            // Busy if a live reader still owes a read in the current epoch.
            if (cc & rem_cc) != 0 && (cur_rc & !EP_MASK) == epoch {
                let ok = Self::wait_for(
                    &self.wt_waiter,
                    || {
                        let s = unsafe { ring_slot(ring_ptr, wt as u8) };
                        let rc = s.rc_.load(Ordering::Acquire);
                        let ep = hdr.epoch.load(Ordering::Relaxed);
                        (cc & (rc & EP_MASK)) != 0 && (rc & !EP_MASK) == ep
                    },
                    Some(timeout_ms),
                )?;
                if ok {
                    continue 'claim;
                }
                // Timeout → force_push: bump epoch, disconnect stale receivers.
                hdr.epoch.fetch_add(EP_INCR, Ordering::AcqRel);
                let rem2 = slot.rc_.load(Ordering::Acquire) & EP_MASK;
                if rem2 != 0 {
                    let new_cc =
                        hdr.connections.fetch_and(!(rem2 as u32), Ordering::AcqRel) & !(rem2 as u32);
                    if new_cc == 0 {
                        return Ok(false);
                    }
                    slot.rc_.fetch_and(!rem2, Ordering::AcqRel);
                }
                continue 'claim;
            }
            let new_rc = epoch | cc;
            if slot
                .rc_
                .compare_exchange_weak(cur_rc, new_rc, Ordering::Release, Ordering::Relaxed)
                .is_ok()
            {
                claimed_wt = wt;
                break 'claim;
            }
            std::thread::yield_now();
        }
        let slot = unsafe { ring_slot(ring_ptr, claimed_wt as u8) };
        unsafe { slot.write_msg(self.cc_id, msg_id, remain, false, payload) };
        hdr.write_cursor.fetch_add(1, Ordering::Release);
        let _ = self.rd_waiter.broadcast();
        Ok(true)
    }

    /// Try sending without blocking (timeout = 0).
    fn try_send(&mut self, data: &[u8]) -> io::Result<bool> {
        self.send(data, 0)
    }

    /// Clear this receiver's bit from a slot's rc_ (C++ pop's rc CAS), preserving
    /// the epoch in the high bits. Call after reading the payload.
    fn release_slot(&self, ring_ptr: *mut u8, idx: u8) {
        let slot = unsafe { ring_slot(ring_ptr, idx) };
        let mut k = 0u32;
        loop {
            let cur_rc = slot.rc_.load(Ordering::Acquire);
            if (cur_rc & EP_MASK) == 0 {
                return; // already fully read
            }
            let nxt = cur_rc & !(self.conn_id as u64);
            if slot
                .rc_
                .compare_exchange_weak(cur_rc, nxt, Ordering::Release, Ordering::Relaxed)
                .is_ok()
            {
                return;
            }
            crate::spin_lock::adaptive_yield_pub(&mut k);
        }
    }

    /// Receive one message (receiver only). Reassembles msg_t fragments by id_,
    /// byte-exact with C++ ipc.cpp recv(). No chunk-storage path yet.
    fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        if self.multi {
            return self.recv_multi(timeout_ms);
        }
        if self.mode != Mode::Receiver {
            return Err(io::Error::other("not a receiver"));
        }
        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        let ring_ptr = self.ring_shm.get();
        loop {
            let hdr = unsafe { ring_header(ring_ptr) };

            // Data ready when the write cursor has advanced past our read cursor.
            if hdr.write_cursor.load(Ordering::Acquire) == self.read_cursor {
                let cur = self.read_cursor;
                let tm = match deadline {
                    Some(dl) => {
                        let rem = dl.saturating_duration_since(Instant::now());
                        if rem.is_zero() {
                            return Ok(IpcBuffer::default());
                        }
                        Some(rem.as_millis() as u64)
                    }
                    None => None,
                };
                let ok = Self::wait_for(
                    &self.rd_waiter,
                    || unsafe { ring_header(ring_ptr) }.write_cursor.load(Ordering::Acquire) == cur,
                    tm,
                )?;
                if !ok {
                    return Ok(IpcBuffer::default()); // timeout
                }
                continue;
            }

            let idx = self.read_cursor as u8;
            let slot = unsafe { ring_slot(ring_ptr, idx) };
            let (cc_id, id, remain, storage) = unsafe { slot.read_header() };
            let is_self = cc_id == self.cc_id;
            let r_size = DATA_LENGTH as i32 + remain;
            let keep = !is_self && r_size > 0;

            // Read out of the slot BEFORE releasing it. A large-message fragment
            // carries a storage_id (into chunk shm); an inline fragment carries
            // its payload bytes directly.
            let storage_id: Option<i32> = if keep && storage {
                Some(unsafe { slot.read_storage_id() })
            } else {
                None
            };
            let frag: Option<Vec<u8>> = if keep && !storage {
                let n = if remain <= 0 { r_size as usize } else { DATA_LENGTH };
                Some(unsafe { slot.read_payload(n) })
            } else {
                None
            };

            // Release our rc_ bit, advance, and wake senders — for every slot
            // (including self / malformed) so the ring can be reused.
            self.release_slot(ring_ptr, idx);
            self.read_cursor = self.read_cursor.wrapping_add(1);
            let _ = self.wt_waiter.broadcast();

            if let Some(buf) = self.assemble_message(keep, id, remain, r_size, storage_id, frag) {
                return Ok(buf);
            }
        }
    }

    /// Shared tail of `recv` / `recv_multi`: after a slot has been decoded and
    /// released, either read a large message from chunk storage or reassemble
    /// inline fragments by `id_`. Returns `Some(buf)` when a full message
    /// completes, `None` to keep reading (self / malformed slot, unavailable
    /// chunk shm, or a still-incomplete multi-fragment message). Byte-exact with
    /// C++ ipc.cpp recv() regardless of the single- or multi-writer ring.
    fn assemble_message(
        &mut self,
        keep: bool,
        id: u32,
        remain: i32,
        r_size: i32,
        storage_id: Option<i32>,
        frag: Option<Vec<u8>>,
    ) -> Option<IpcBuffer> {
        if !keep {
            return None; // self-message / malformed — slot already released
        }
        // Large message: a single msg_t carrying a storage_id into chunk shm.
        if let Some(sid) = storage_id {
            let msg_size = r_size as usize;
            let chunk_size = cs::calc_chunk_size(msg_size);
            let buf = self.chunk_shm_base(chunk_size).and_then(|base| {
                let out = cs::find_storage(base, chunk_size, sid)
                    .map(|ptr| unsafe { std::slice::from_raw_parts(ptr, msg_size).to_vec() });
                cs::recycle_storage(base, chunk_size, sid, self.conn_id);
                out
            });
            return buf.map(IpcBuffer::from_vec); // None -> chunk shm unavailable
        }
        // Inline fragment; reassemble by id_.
        let frag = frag.unwrap();
        if let Some((off, mut buf)) = self.recv_cache.remove(&id) {
            let n = frag.len();
            buf[off..off + n].copy_from_slice(&frag);
            if remain <= 0 {
                return Some(IpcBuffer::from_vec(buf)); // last fragment
            }
            self.recv_cache.insert(id, (off + n, buf));
            None
        } else if remain <= 0 {
            Some(IpcBuffer::from_vec(frag)) // single fragment
        } else {
            // First fragment of a multi-fragment message; r_size is the total.
            let mut buf = vec![0u8; r_size as usize];
            buf[..frag.len()].copy_from_slice(&frag);
            self.recv_cache.insert(id, (frag.len(), buf));
            None
        }
    }

    /// Multi-writer push (C++ prod_cons_impl<multi,multi,broadcast>): claim the
    /// `ct_` commit slot via a CAS on `rc_` + an epoch re-validate, advance `ct_`,
    /// write the fragment, then publish `f_ct_ = !ct` for readers. Busy-polls with
    /// a deadline while the target slot is still owed a read / not yet drained (the
    /// matrix keeps every reader live, so force_push eviction is not needed).
    fn push_fragment_multi(&self, msg_id: u32, remain: i32, payload: &[u8], timeout_ms: u64) -> io::Result<bool> {
        let hdr = self.hdr();
        let ring_ptr = self.ring_shm.get();
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let mut epoch = hdr.epoch.load(Ordering::Acquire);
        let claimed_ct: u32;
        let mut k = 0u32;
        'claim: loop {
            let cc = hdr.connections.load(Ordering::Relaxed) as u64;
            if cc == 0 {
                return Ok(false); // no receivers
            }
            let cur_ct = hdr.write_cursor.load(Ordering::Relaxed); // commit index (ct_)
            let slot = unsafe { channel_slot(ring_ptr, cur_ct as u8) };
            let cur_rc = slot.rc_.load(Ordering::Relaxed);
            let rem_cc = cur_rc & RC_MASK;
            if (cc & rem_cc) != 0 && (cur_rc & !CH_EP_MASK) == epoch {
                // Slot still held by a live reader in the current epoch.
                if Instant::now() >= deadline {
                    return Ok(false);
                }
                crate::spin_lock::adaptive_yield_pub(&mut k);
                continue 'claim;
            } else if rem_cc == 0 {
                let cur_fl = slot.f_ct_.load(Ordering::Acquire);
                if cur_fl != cur_ct as u64 && cur_fl != 0 {
                    // Previous lap's data not yet drained by the reader.
                    if Instant::now() >= deadline {
                        return Ok(false);
                    }
                    crate::spin_lock::adaptive_yield_pub(&mut k);
                    continue 'claim;
                }
            }
            let desired = inc_mask(epoch | (cur_rc & CH_EP_MASK)) | cc;
            if slot
                .rc_
                .compare_exchange_weak(cur_rc, desired, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
            {
                // Won the slot; re-validate the epoch has not moved. An acquire
                // load is equivalent to the old self-CAS (a no-op store publishes
                // nothing new) and avoids the weak-CAS spurious-failure retry.
                let now = hdr.epoch.load(Ordering::Acquire);
                if now == epoch {
                    claimed_ct = cur_ct;
                    break 'claim;
                }
                epoch = now;
            }
            crate::spin_lock::adaptive_yield_pub(&mut k);
        }
        hdr.write_cursor.store(claimed_ct.wrapping_add(1), Ordering::Release); // advance ct_
        let slot = unsafe { channel_slot(ring_ptr, claimed_ct as u8) };
        unsafe { slot.write_msg(self.cc_id, msg_id, remain, false, payload) };
        slot.f_ct_.store(!(claimed_ct as u64), Ordering::Release); // publish commit flag
        let _ = self.rd_waiter.broadcast();
        Ok(true)
    }

    /// Multi-writer recv: emptiness via `f_ct_ == !cur`, the channel `rc_`/`f_ct_`
    /// slot-free protocol, then the same fragment reassembly / chunk-storage decode
    /// as route `recv()`.
    fn recv_multi(&mut self, timeout_ms: Option<u64>) -> io::Result<IpcBuffer> {
        if self.mode != Mode::Receiver {
            return Err(io::Error::other("not a receiver"));
        }
        let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
        let ring_ptr = self.ring_shm.get();
        let mut k = 0u32;
        loop {
            let cur = self.read_cursor;
            let slot = unsafe { channel_slot(ring_ptr, cur as u8) };
            if slot.f_ct_.load(Ordering::Acquire) != !(cur as u64) {
                // Empty — the sender has not published this cursor's commit flag.
                if let Some(dl) = deadline {
                    if Instant::now() >= dl {
                        return Ok(IpcBuffer::default());
                    }
                }
                crate::spin_lock::adaptive_yield_pub(&mut k);
                continue;
            }
            k = 0;

            let (cc_id, id, remain, storage) = unsafe { slot.read_header() };
            let is_self = cc_id == self.cc_id;
            let r_size = DATA_LENGTH as i32 + remain;
            let keep = !is_self && r_size > 0;
            let storage_id: Option<i32> = if keep && storage {
                Some(unsafe { slot.read_storage_id() })
            } else {
                None
            };
            let frag: Option<Vec<u8>> = if keep && !storage {
                let n = if remain <= 0 { r_size as usize } else { DATA_LENGTH };
                Some(unsafe { slot.read_payload(n) })
            } else {
                None
            };

            // Clear our rc_ bit (channel inc_rc protocol); the last reader frees the
            // slot by setting f_ct_ to the next-lap ct value (cur + RING_SIZE).
            let cur_post = cur.wrapping_add(1);
            let free_flag = cur_post as u64 + (RING_SIZE as u64 - 1);
            let mut j = 0u32;
            loop {
                let cur_rc = slot.rc_.load(Ordering::Acquire);
                if (cur_rc & RC_MASK) == 0 {
                    slot.f_ct_.store(free_flag, Ordering::Release);
                    break;
                }
                let nxt = inc_rc(cur_rc) & !(self.conn_id as u64);
                if (nxt & RC_MASK) == 0 {
                    slot.f_ct_.store(free_flag, Ordering::Release);
                }
                if slot
                    .rc_
                    .compare_exchange_weak(cur_rc, nxt, Ordering::Release, Ordering::Relaxed)
                    .is_ok()
                {
                    break;
                }
                crate::spin_lock::adaptive_yield_pub(&mut j);
            }
            self.read_cursor = cur_post;
            let _ = self.wt_waiter.broadcast();

            if let Some(buf) = self.assemble_message(keep, id, remain, r_size, storage_id, frag) {
                return Ok(buf);
            }
        }
    }

    /// Try receiving without blocking.
    fn try_recv(&mut self) -> io::Result<IpcBuffer> {
        self.recv(Some(0))
    }
}

impl ChanInner {
    /// Whether this endpoint is still connected (not explicitly disconnected).
    fn valid(&self) -> bool {
        !self.disconnected
    }

    /// Disconnect this endpoint: clear connection bits and mark as disconnected.
    /// Mirrors C++ `detail_impl::disconnect` — shuts sending and clears receiver bit.
    fn disconnect(&mut self) {
        if self.disconnected {
            return;
        }
        let hdr = self.hdr();
        match self.mode {
            Mode::Sender => {
                hdr.sender_count.fetch_sub(1, Ordering::Relaxed);
            }
            Mode::Receiver => {
                hdr.connections.fetch_and(!self.conn_id, Ordering::AcqRel);
                // Release our owner-table slot so a reaper never touches it.
                let lv = self.liveness_shm.get() as *mut crate::liveness::ConnLiveness;
                crate::liveness::clear_owner(lv, self.conn_id);
                // Wake any senders waiting for this receiver to drain.
                let _ = self.wt_waiter.broadcast();
            }
        }
        self.disconnected = true;
    }

    /// Reconnect with a (possibly different) mode.
    /// Disconnects the current connection, then re-opens with the new mode.
    /// Returns an error if the underlying SHM cannot be opened.
    fn reconnect(&mut self, mode: Mode) -> io::Result<()> {
        self.disconnect();
        let new_inner = ChanInner::open(&self.prefix, &self.name, mode, self.multi)?;
        *self = new_inner;
        Ok(())
    }

    /// Open a new independent endpoint with the same name, prefix, and mode.
    fn clone_inner(&self) -> io::Result<ChanInner> {
        ChanInner::open(&self.prefix, &self.name, self.mode, self.multi)
    }
}

impl Drop for ChanInner {
    fn drop(&mut self) {
        // disconnect() is idempotent — safe to call even if already disconnected.
        self.disconnect();
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
        let inner = ChanInner::open(prefix, name, mode, false)?;
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

    /// Whether this endpoint is still connected (not explicitly disconnected).
    /// Mirrors C++ `chan_wrapper::valid()`.
    pub fn valid(&self) -> bool {
        self.inner.valid()
    }

    /// Disconnect this endpoint. Clears connection bits; the backing SHM is not removed.
    /// After calling this, `valid()` returns `false`.
    /// Mirrors C++ `chan_wrapper::disconnect()`.
    pub fn disconnect(&mut self) {
        self.inner.disconnect();
    }

    /// Disconnect and reconnect with a (possibly different) mode.
    /// Mirrors C++ `chan_wrapper::reconnect(mode)`.
    pub fn reconnect(&mut self, mode: Mode) -> io::Result<()> {
        self.inner.reconnect(mode)
    }

    /// Open a new independent endpoint with the same name, prefix, and mode.
    /// Mirrors C++ `chan_wrapper::clone()`.
    pub fn clone(&self) -> io::Result<Self> {
        Ok(Self {
            inner: self.inner.clone_inner()?,
        })
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

    /// Layer 1 (`notify` feature): this receiver's readiness fd, or -1 if none.
    /// Woken on every matching enqueue (including from a C++/Swift sender), so it
    /// can be multiplexed on epoll/kqueue/`AsyncFd` instead of a blocking recv.
    /// Byte-exact with C++ `native_wait_handle()`. On Windows this is a waitable
    /// auto-reset Event HANDLE (as `isize`); on unix a readiness fd.
    #[cfg(feature = "notify")]
    pub fn native_wait_handle(&mut self) -> crate::notify::WaitHandle {
        self.inner.native_wait_handle()
    }

    /// Drain pending readiness tokens after the handle signalled (level-triggered
    /// on unix; a no-op on Windows where the auto-reset event self-resets). Call
    /// before/after a `try_recv()` in a reactor loop.
    #[cfg(feature = "notify")]
    pub fn drain_wait_handle(&self) {
        self.inner.drain_wait_handle();
    }

    /// Disconnect and remove all backing SHM under the currently-open handle.
    /// Equivalent to `disconnect()` followed by `clear_storage(name)`.
    /// Mirrors C++ `chan_wrapper::clear()`.
    pub fn clear(&mut self) {
        let name = self.inner.name.clone();
        let prefix = self.inner.prefix.clone();
        self.inner.disconnect();
        Self::clear_storage_with_prefix(&prefix, &name);
    }

    /// Release the local connection without waiting for remote peers to disconnect.
    /// The backing SHM is NOT removed; other processes continue to use it.
    /// Mirrors C++ `chan_wrapper::release()`.
    pub fn release(&mut self) {
        self.inner.disconnect();
    }

    /// Static convenience: connect a temporary sender, wait for `count` receivers,
    /// then drop it. Mirrors C++ `chan_wrapper::wait_for_recv(name, count, tm)`.
    pub fn wait_for_recv_on(name: &str, count: usize, timeout_ms: Option<u64>) -> io::Result<bool> {
        let rt = Self::connect(name, Mode::Sender)?;
        rt.inner.wait_for_recv(count, timeout_ms)
    }

    /// Remove all backing storage for a named route.
    pub fn clear_storage(name: &str) {
        Self::clear_storage_with_prefix("", name);
    }

    /// Remove all backing storage with a prefix.
    pub fn clear_storage_with_prefix(prefix: &str, name: &str) {
        let full_prefix = format!("{prefix}__IPC_SHM__");
        ShmHandle::clear_storage(&format!("{full_prefix}QU_CONN__{name}__{DATA_LENGTH}__{RING_ALIGN}"));
        // NB: the cc_id counter CA_CONN__ is prefix-global (no channel name) and
        // intentionally persistent, like C++ cc_acc — never cleared here. The
        // per-channel multi-writer msg-id counter AC_CONN__<name> IS cleared,
        // byte-exact with C++ channel::clear_storage.
        ShmHandle::clear_storage(&format!("{full_prefix}AC_CONN__{name}"));
        ShmHandle::clear_storage(&format!("{full_prefix}LV_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}WT_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}RD_CONN__{name}"));
        Waiter::clear_storage(&format!("{full_prefix}CC_CONN__{name}"));
        // Remove any chunk-storage shm segments. chunk_prefix matches the _prefix field:
        // {full_prefix}{name}_ so each channel's chunk SHMs are isolated.
        let chunk_prefix = format!("{full_prefix}{name}_");
        for &payload_size in &[128usize, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
            cs::clear_chunk_shm(&chunk_prefix, cs::calc_chunk_size(payload_size));
        }
        // Remove any Layer-1 FIFO notify nodes (no-op for the macOS libnotify backend).
        #[cfg(feature = "notify")]
        crate::notify::clear_storage(prefix, name);
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
        let inner = ChanInner::open(prefix, name, mode, true)?;
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

    /// Whether this endpoint is still connected (not explicitly disconnected).
    /// Mirrors C++ `chan_wrapper::valid()`.
    pub fn valid(&self) -> bool {
        self.inner.valid()
    }

    /// Disconnect this endpoint. Clears connection bits; the backing SHM is not removed.
    /// After calling this, `valid()` returns `false`.
    /// Mirrors C++ `chan_wrapper::disconnect()`.
    pub fn disconnect(&mut self) {
        self.inner.disconnect();
    }

    /// Disconnect and reconnect with a (possibly different) mode.
    /// Mirrors C++ `chan_wrapper::reconnect(mode)`.
    pub fn reconnect(&mut self, mode: Mode) -> io::Result<()> {
        self.inner.reconnect(mode)
    }

    /// Open a new independent endpoint with the same name, prefix, and mode.
    /// Mirrors C++ `chan_wrapper::clone()`.
    pub fn clone(&self) -> io::Result<Self> {
        Ok(Self {
            inner: self.inner.clone_inner()?,
        })
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

    /// Layer 1 (`notify` feature): this receiver's readiness handle, or the
    /// invalid sentinel if none. Byte-exact with C++ `native_wait_handle()`;
    /// multiplexable on epoll/kqueue (unix) or a wait registration (Windows).
    #[cfg(feature = "notify")]
    pub fn native_wait_handle(&mut self) -> crate::notify::WaitHandle {
        self.inner.native_wait_handle()
    }

    /// Drain pending readiness tokens after the fd signalled (level-triggered).
    #[cfg(feature = "notify")]
    pub fn drain_wait_handle(&self) {
        self.inner.drain_wait_handle();
    }

    /// Disconnect and remove all backing SHM under the currently-open handle.
    /// Mirrors C++ `chan_wrapper::clear()`.
    pub fn clear(&mut self) {
        let name = self.inner.name.clone();
        let prefix = self.inner.prefix.clone();
        self.inner.disconnect();
        Self::clear_storage_with_prefix(&prefix, &name);
    }

    /// Release the local connection without removing backing SHM.
    /// Mirrors C++ `chan_wrapper::release()`.
    pub fn release(&mut self) {
        self.inner.disconnect();
    }

    /// Static convenience: wait for `count` receivers on a named channel.
    /// Mirrors C++ `chan_wrapper::wait_for_recv(name, count, tm)`.
    pub fn wait_for_recv_on(name: &str, count: usize, timeout_ms: Option<u64>) -> io::Result<bool> {
        let ch = Self::connect(name, Mode::Sender)?;
        ch.inner.wait_for_recv(count, timeout_ms)
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
