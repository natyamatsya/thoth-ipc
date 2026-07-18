// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Signal-only port of cpp-ipc/src/libipc/waiter.h + apple condition.h. The
// route's RD/WT/CC waiters are ulock seq-counter condition variables in shared
// memory (byte-exact with the C++/Rust/Swift ports). This port's own endpoints
// busy-poll the ring, so we never need to *wait* — but a C++/Rust/Swift peer
// parks in __ulock_wait when the ring looks empty (reader) or full (sender), so
// we must *signal* the matching waiter or the peer never wakes.
//
// Condition shm layout (8 bytes, context/xlang-channel-abi.md sync ABI):
//   @0 seq     atomic<u32>  incremented on every notify/broadcast
//   @4 waiters atomic<i32>  count of threads currently in __ulock_wait

const std = @import("std");
const shm = @import("../platform/shm.zig");
const shmname = @import("../platform/shmname.zig");
const ulock = @import("../sync/ulock.zig");

const ShmHandle = shm.ShmHandle;

/// One route waiter (RD/WT/CC), signal side only.
pub const Waiter = struct {
    cond: ShmHandle,

    /// Open the condition shm named `<prefix>__IPC_SHM__<tag><name>_WAITER_COND_`
    /// (create-or-open, zeroed). `tag` is "RD_CONN__" / "WT_CONN__" / "CC_CONN__".
    pub fn open(prefix: []const u8, name: []const u8, tag: []const u8) shm.ShmError!Waiter {
        var buf: [256]u8 = undefined;
        const cond_name = std.fmt.bufPrint(&buf, "{s}__IPC_SHM__{s}{s}_WAITER_COND_", .{ prefix, tag, name }) catch unreachable;
        return .{ .cond = try ShmHandle.acquire(cond_name, 8, .create_or_open) };
    }

    /// Wake every parked waiter (C++ condition::broadcast): bump seq, then
    /// __ulock_wake(WAKE_ALL) if anyone is waiting.
    pub fn broadcast(self: *const Waiter) void {
        const base = self.cond.ptr();
        const seq: *u32 = @ptrCast(@alignCast(base));
        const waiters: *i32 = @ptrCast(@alignCast(base + 4));
        _ = @atomicRmw(u32, seq, .Add, 1, .acq_rel);
        if (@atomicLoad(i32, waiters, .acquire) > 0) {
            ulock.wakeAll(seq);
        }
    }

    pub fn release(self: *Waiter) void {
        self.cond.release();
    }
};
