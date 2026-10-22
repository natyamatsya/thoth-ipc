// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp/thoth-ipc/src/thoth-ipc/waiter.h. The route's RD/WT/CC waiters are
// a named condition variable `<tag><name>_WAITER_COND_` and its mutex
// `<tag><name>_WAITER_LOCK_` in shared memory: the apple_ulock seq-counter
// condition on macOS, the linux_a0 requeue-PI condition on Linux (sync/). A
// reader parks on RD while the ring is empty, a sender on WT while its slot is
// still unread and on CC until enough receivers are connected; every port
// broadcasts the matching waiter after the change, so a peer of any language
// wakes.
//
// A wake takes the lock once before broadcasting (the C++ waiter's barrier): a
// waiter between its predicate check and its sleep holds the lock, so the wake
// cannot slip past it.

const std = @import("std");
const layout = @import("layout.zig");
const guard = @import("../sync/abi_guard.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;
const Condition = @import("../sync/condition.zig").Condition;

pub const Error = guard.Error || error{ WakeFailed, WaitFailed };

/// Back-off rounds spent spinning and yielding (layout.adaptiveYield) before a
/// wait parks on the waiter, as C++ `wait_for` does through `thoth::sleep`.
const spin_rounds = 64;

/// Longest single park. Every port wakes the waiter, so this only bounds the
/// cost of a wake that never comes (a peer killed mid-push).
const max_park_ns = 100 * std.time.ns_per_ms;

/// `<prefix>__THOTH_SHM__<tag><name>_WAITER_<kind>_`, `tag` being "RD_CONN__" /
/// "WT_CONN__" / "CC_CONN__" and `kind` "COND" or "LOCK".
fn waiterName(buf: []u8, prefix: []const u8, name: []const u8, tag: []const u8, kind: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__THOTH_SHM__{s}{s}_WAITER_{s}_", .{ prefix, tag, name, kind }) catch unreachable;
}

/// Remove one waiter's condition and mutex, guard sidecars included (C++
/// `waiter::clear_storage`).
pub fn clearStorage(prefix: []const u8, name: []const u8, tag: []const u8) void {
    var buf: [256]u8 = undefined;
    Condition.clearStorage(waiterName(&buf, prefix, name, tag, "COND"));
    Mutex.clearStorage(waiterName(&buf, prefix, name, tag, "LOCK"));
}

/// One route waiter (RD/WT/CC).
pub const Waiter = struct {
    cond: Condition,
    lock: Mutex,

    pub fn open(prefix: []const u8, name: []const u8, tag: []const u8) Error!Waiter {
        var buf: [256]u8 = undefined;
        var cond = try Condition.open(waiterName(&buf, prefix, name, tag, "COND"));
        errdefer cond.deinit();
        return .{ .cond = cond, .lock = try Mutex.open(waiterName(&buf, prefix, name, tag, "LOCK")) };
    }

    /// Wake every parked waiter (C++ `waiter::broadcast`).
    pub fn broadcast(self: *const Waiter) Error!void {
        self.lock.lock() catch return error.WakeFailed;
        self.lock.unlock();
        self.cond.broadcast(&self.lock) catch return error.WakeFailed;
    }

    /// One step of a wait loop whose caller found `ctx.blocked()` true and its
    /// deadline not yet passed. The first rounds spin and yield; later ones park
    /// on the waiter until `ctx.blocked()` turns false, a wake comes or the
    /// deadline passes. The caller re-checks its condition and deadline after.
    pub fn backoff(self: *const Waiter, k: *u32, deadline_ns: i128, ctx: anytype) Error!void {
        if (k.* < spin_rounds) return layout.adaptiveYield(k);
        k.* = 0;
        self.lock.lock() catch return error.WaitFailed;
        defer self.lock.unlock();
        while (ctx.blocked()) {
            const now = layout.nowNs();
            if (now >= deadline_ns) return;
            _ = self.cond.wait(&self.lock, @min(deadline_ns - now, max_park_ns)) catch return error.WaitFailed;
        }
    }

    pub fn release(self: *Waiter) void {
        self.lock.deinit();
        self.cond.deinit();
    }
};
