// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Byte-exact ABI layout for the C++ `ipc::route` broadcast ring
// (elem_array<broadcast, DataSize=80, AlignSize=8>) on Apple arm64.
// See context/xlang-channel-abi.md §2/§3/§4. All offsets/sizes are verified
// against the real C++ types and the Swift/Rust ports; comptime asserts guard
// against drift.

const std = @import("std");
const builtin = @import("builtin");

// --- Ring dimensions (ABI §2/§3/§4) ----------------------------------------

pub const data_length: usize = 64; // msg_t payload fragment size
pub const ring_size: usize = 256; // block_[256]
// AlignSize = min(64, alignof(max_align_t)). 8 on Apple arm64, 16 on x86-64 /
// Linux aarch64. Computed, not hard-coded, so a later Linux phase is correct.
pub const align_size: usize = @min(@as(usize, 64), @alignOf(std.c.max_align_t));

// rc_ epoch packing (ABI §3): low 32 bits = connection bitmask, high 32 = epoch.
pub const ep_mask: u64 = 0x0000_0000_FFFF_FFFF;
pub const ep_incr: u64 = 0x0000_0001_0000_0000;

// --- Ring header offsets (ABI §2) ------------------------------------------
// conn_head_base { cc_(u32)@0, lc_(spin_lock)@4, constructed_(bool)@8 }, then the
// cache-line-aligned prod_cons head_ { wt_(u32)@64, epoch_(u64)@128 }. block_@192.

pub const off_cc: usize = 0; // connections bitmask (atomic u32)
pub const off_lc: usize = 4; // header lock (os_unfair_lock on Apple)
pub const off_constructed: usize = 8; // DCLP init flag (atomic bool/u8)
pub const off_wt: usize = 64; // write cursor (atomic u32)
pub const off_epoch: usize = 128; // writer epoch (u64)
pub const off_block: usize = 192; // block_[256] of elem_t

// --- Slot (elem_t) layout (ABI §3) -----------------------------------------

pub const elem_stride: usize = 88; // sizeof(elem_t) = data_[80] + rc_(u64)
pub const elem_rc_off: usize = 80; // rc_ within a slot (atomic u64)

// --- Message framing (msg_t<64,8>, lives inside elem_t.data_) (ABI §4) ------

pub const msg_cc_id: usize = 0; // sender identity (self-message filter), u32
pub const msg_id: usize = 4; // message id (fragments share it), u32
pub const msg_remain: usize = 8; // bytes remaining after this fragment, i32
pub const msg_storage: usize = 12; // payload is a storage_id (large-msg path), bool
pub const msg_payload: usize = 16; // payload fragment (or storage_id), 64 bytes

// --- Total ring shm size ----------------------------------------------------
// sizeof(elem_array<broadcast,80,8>) on Apple arm64. block_ ends at
// 192 + 88*256 = 22720; the trailing sender_checker/receiver_checker flags plus
// align-64 padding round the type up to 22784. Ports must ftruncate to the full
// size so the sender flag maps.
pub const ring_user_size: usize = 22784;

comptime {
    std.debug.assert(off_block + elem_stride * ring_size == 22720);
    std.debug.assert(align_size == 8); // Apple arm64 (this port is macOS-first)
    std.debug.assert(msg_payload + data_length == 80); // sizeof(msg_t<64,8>)
}

// --- os_unfair_lock (Apple header lock) ------------------------------------
//
// The header `lc_` field (offset 4) is an os_unfair_lock in the C++ ABI, and a
// C++ peer takes that same in-shm lock during DCLP init — so we must drive the
// real Apple primitive, not a look-alike. This is the one place a C dependency
// is unavoidable; std.c exposes the primitive and its lock/unlock functions.

pub const os_unfair_lock = std.c.os_unfair_lock;
pub const os_unfair_lock_lock = std.c.os_unfair_lock_lock;
pub const os_unfair_lock_unlock = std.c.os_unfair_lock_unlock;

// --- Typed pointers into the mapped ring -----------------------------------

pub inline fn u8ptr(base: [*]u8, off: usize) *u8 {
    return @ptrCast(base + off);
}
pub inline fn u32ptr(base: [*]u8, off: usize) *u32 {
    return @ptrCast(@alignCast(base + off));
}
pub inline fn i32ptr(base: [*]u8, off: usize) *i32 {
    return @ptrCast(@alignCast(base + off));
}
pub inline fn u64ptr(base: [*]u8, off: usize) *u64 {
    return @ptrCast(@alignCast(base + off));
}
pub inline fn lockPtr(base: [*]u8) *os_unfair_lock {
    return @ptrCast(@alignCast(base + off_lc));
}

pub inline fn slotBase(base: [*]u8, idx: usize) [*]u8 {
    return base + off_block + idx * elem_stride;
}
pub inline fn slotRc(sb: [*]u8) *u64 {
    return @ptrCast(@alignCast(sb + elem_rc_off));
}

pub const MsgHeader = struct {
    cc_id: u32,
    id: u32,
    remain: i32,
    storage: bool,
};

pub inline fn writeMsgHeader(sb: [*]u8, h: MsgHeader) void {
    u32ptr(sb, msg_cc_id).* = h.cc_id;
    u32ptr(sb, msg_id).* = h.id;
    i32ptr(sb, msg_remain).* = h.remain;
    u8ptr(sb, msg_storage).* = @intFromBool(h.storage);
}

pub inline fn readMsgHeader(sb: [*]u8) MsgHeader {
    return .{
        .cc_id = u32ptr(sb, msg_cc_id).*,
        .id = u32ptr(sb, msg_id).*,
        .remain = i32ptr(sb, msg_remain).*,
        .storage = u8ptr(sb, msg_storage).* != 0,
    };
}

// --- DCLP header init (ABI §5) ---------------------------------------------
// Byte-exact with C++ conn_head_base::init() so a C++ peer that sees
// constructed_==0 does not re-zero the header and wipe our connection bit.
pub fn initHeader(base: [*]u8) void {
    if (@atomicLoad(u8, u8ptr(base, off_constructed), .acquire) != 0) return;
    const lock = lockPtr(base);
    os_unfair_lock_lock(lock);
    defer os_unfair_lock_unlock(lock);
    if (@atomicLoad(u8, u8ptr(base, off_constructed), .acquire) == 0) {
        @atomicStore(u32, u32ptr(base, off_cc), 0, .release);
        @atomicStore(u8, u8ptr(base, off_constructed), 1, .release);
    }
}

// --- Monotonic clock + sleep -----------------------------------------------
// std.time dropped nanoTimestamp/sleep in the 0.16 Io rework; go through std.c
// (the standard library's own libc declarations) rather than hand-rolled externs.

/// Monotonic nanoseconds since an arbitrary epoch (deadline arithmetic).
pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleepNs(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

// --- Adaptive yield (spin → yield → sleep) ---------------------------------

pub fn adaptiveYield(k: *u32) void {
    k.* +%= 1;
    if (k.* < 16) {
        std.atomic.spinLoopHint();
    } else if (k.* < 64) {
        std.Thread.yield() catch {};
    } else {
        sleepNs(std.time.ns_per_ms);
    }
}
