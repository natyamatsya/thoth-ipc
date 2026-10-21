// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Signal-only port of cpp-ipc/src/libipc/waiter.h. The route's RD/WT/CC
// waiters are named condition variables (+ a mutex) in shared memory. This
// port's own endpoints busy-poll the ring, so we never need to *wait* — but a
// C++/Rust/Swift peer parks on the condition when the ring looks empty
// (reader) or full (sender), so we must *signal* the matching waiter or the
// peer never wakes.
//
//   macOS: the apple_ulock seq-counter condition (8 bytes, no guard sidecar
//          needed to signal):
//            @0 seq     atomic<u32>  incremented on every notify/broadcast
//            @4 waiters atomic<i32>  count of threads currently in __ulock_wait
//   Linux: the linux_a0 condition `..._WAITER_COND_` and its mutex
//          `..._WAITER_LOCK_`. a0 sleepers wait requeued onto the mutex, so a
//          wake must lock/unlock it (the C++ waiter's barrier) and then requeue
//          onto it.

const std = @import("std");
const builtin = @import("builtin");
const shm = @import("../platform/shm.zig");
const guard = @import("../sync/abi_guard.zig");

pub const Error = guard.Error || error{WakeFailed};

/// One route waiter (RD/WT/CC), signal side only.
pub const Waiter = switch (builtin.os.tag) {
    .linux => LinuxWaiter,
    .macos => AppleWaiter,
    else => @compileError("thoth-ipc: no waiter backend for " ++ @tagName(builtin.os.tag)),
};

/// `<prefix>__THOTH_SHM__<tag><name>_WAITER_<kind>_`, `tag` being "RD_CONN__" /
/// "WT_CONN__" / "CC_CONN__" and `kind` "COND" or "LOCK".
fn waiterName(buf: []u8, prefix: []const u8, name: []const u8, tag: []const u8, kind: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__THOTH_SHM__{s}{s}_WAITER_{s}_", .{ prefix, tag, name, kind }) catch unreachable;
}

const AppleWaiter = struct {
    cond: shm.ShmHandle,

    pub fn open(prefix: []const u8, name: []const u8, tag: []const u8) Error!AppleWaiter {
        var buf: [256]u8 = undefined;
        return .{ .cond = try shm.ShmHandle.acquire(waiterName(&buf, prefix, name, tag, "COND"), 8, .create_or_open) };
    }

    /// Wake every parked waiter (C++ condition::broadcast): bump seq, then
    /// __ulock_wake(WAKE_ALL) if anyone is waiting.
    pub fn broadcast(self: *const AppleWaiter) Error!void {
        const ulock = @import("../sync/ulock.zig");
        const base = self.cond.ptr();
        const seq: *u32 = @ptrCast(@alignCast(base));
        const waiters: *i32 = @ptrCast(@alignCast(base + 4));
        _ = @atomicRmw(u32, seq, .Add, 1, .acq_rel);
        if (@atomicLoad(i32, waiters, .acquire) > 0) {
            ulock.wakeAll(seq);
        }
    }

    pub fn release(self: *AppleWaiter) void {
        self.cond.release();
    }
};

const LinuxWaiter = struct {
    const Mutex = @import("../sync/mutex.zig").Mutex;
    const Condition = @import("../sync/condition.zig").Condition;

    cond: Condition,
    lock: Mutex,

    pub fn open(prefix: []const u8, name: []const u8, tag: []const u8) Error!LinuxWaiter {
        var buf: [256]u8 = undefined;
        var cond = try Condition.open(waiterName(&buf, prefix, name, tag, "COND"));
        errdefer cond.deinit();
        return .{ .cond = cond, .lock = try Mutex.open(waiterName(&buf, prefix, name, tag, "LOCK")) };
    }

    /// Wake every parked waiter (C++ `waiter::broadcast`). Taking the lock once
    /// first means a waiter between its predicate check and its sleep has
    /// gone to sleep, so the wake cannot slip past it.
    pub fn broadcast(self: *const LinuxWaiter) Error!void {
        self.lock.lock() catch return error.WakeFailed;
        self.lock.unlock();
        self.cond.broadcast(&self.lock) catch return error.WakeFailed;
    }

    pub fn release(self: *LinuxWaiter) void {
        self.lock.deinit();
        self.cond.deinit();
    }
};
