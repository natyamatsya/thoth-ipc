// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process mutex — Apple ulock word-lock in shared memory, byte-exact
// with cpp/thoth-ipc apple/mutex.h and the Rust/Swift ports.
//   @0 state  atomic<u32>  0=UNLOCKED, 1=LOCKED, 2=LOCKED+waiters
//   @4 holder atomic<u32>  PID of the current owner, 0 when unlocked
// The holder PID drives robust dead-holder recovery (a crashed owner's lock is
// reclaimable). The mutex is paired with a SyncAbi guard sidecar.

const std = @import("std");
const shm = @import("../platform/shm.zig");
const ulock = @import("ulock.zig");
const guard = @import("abi_guard.zig");
const nowNs = @import("../transport/layout.zig").nowNs;

const ShmHandle = shm.ShmHandle;
const SPIN: usize = 40; // kMutexSpinCount

pub const Error = guard.Error;

pub const Mutex = struct {
    data: ShmHandle,
    g: guard.Guard,

    pub fn open(name: []const u8) Error!Mutex {
        var g = try guard.ensure(name, .mutex);
        errdefer g.release();
        const data = try ShmHandle.acquire(name, 8, .create_or_open);
        return .{ .data = data, .g = g };
    }

    pub fn deinit(self: *Mutex) void {
        self.data.release();
        self.g.release();
    }

    inline fn statePtr(self: *const Mutex) *u32 {
        return @ptrCast(@alignCast(self.data.ptr()));
    }
    inline fn holderPtr(self: *const Mutex) *u32 {
        return @ptrCast(@alignCast(self.data.ptr() + 4));
    }

    fn selfPid() u32 {
        return @bitCast(std.c.getpid());
    }

    fn isAlive(pid: u32) bool {
        if (pid == 0) return false;
        const rc = std.c.kill(@bitCast(pid), @enumFromInt(0));
        return rc == 0 or std.c._errno().* != @intFromEnum(std.c.E.SRCH);
    }

    fn tryRecoverDeadHolder(self: *const Mutex) bool {
        const holder = @atomicLoad(u32, self.holderPtr(), .acquire);
        if (holder == 0 or isAlive(holder)) return false;
        const old = @atomicRmw(u32, self.statePtr(), .Xchg, 0, .acq_rel);
        @atomicStore(u32, self.holderPtr(), 0, .release);
        if (old == 2) ulock.wakeAll(self.statePtr());
        return true;
    }

    pub fn lock(self: *const Mutex) void {
        var contended = false;
        while (true) {
            var i: usize = 0;
            while (i < SPIN) : (i += 1) {
                const desired: u32 = if (contended) 2 else 1;
                if (@cmpxchgWeak(u32, self.statePtr(), 0, desired, .acquire, .monotonic) == null) {
                    @atomicStore(u32, self.holderPtr(), selfPid(), .release);
                    return;
                }
            }
            const s = @atomicLoad(u32, self.statePtr(), .monotonic);
            if (s == 0) continue;
            if (s == 1 and @cmpxchgWeak(u32, self.statePtr(), 1, 2, .monotonic, .monotonic) != null) continue;
            _ = ulock.wait(self.statePtr(), 2, 0);
            contended = true;
        }
    }

    pub fn tryLock(self: *const Mutex) bool {
        if (@cmpxchgWeak(u32, self.statePtr(), 0, 1, .acquire, .monotonic) == null) {
            @atomicStore(u32, self.holderPtr(), selfPid(), .release);
            return true;
        }
        if (self.tryRecoverDeadHolder()) {
            if (@cmpxchgWeak(u32, self.statePtr(), 0, 1, .acquire, .monotonic) == null) {
                @atomicStore(u32, self.holderPtr(), selfPid(), .release);
                return true;
            }
        }
        return false;
    }

    /// Timed lock (robust). Returns true if acquired within `timeout_ns`.
    pub fn lockTimeout(self: *const Mutex, timeout_ns: i128) bool {
        const deadline = nowNs() + timeout_ns;
        var tried_recovery = false;
        var contended = false;
        while (true) {
            var i: usize = 0;
            while (i < SPIN) : (i += 1) {
                const desired: u32 = if (contended) 2 else 1;
                if (@cmpxchgWeak(u32, self.statePtr(), 0, desired, .acquire, .monotonic) == null) {
                    @atomicStore(u32, self.holderPtr(), selfPid(), .release);
                    return true;
                }
            }
            const s = @atomicLoad(u32, self.statePtr(), .monotonic);
            if (s == 0) continue;
            if (s == 1 and @cmpxchgWeak(u32, self.statePtr(), 1, 2, .monotonic, .monotonic) != null) continue;

            const now = nowNs();
            if (now >= deadline) {
                if (!tried_recovery) {
                    tried_recovery = true;
                    if (self.tryRecoverDeadHolder()) continue;
                }
                return false;
            }
            const ret = ulock.wait(self.statePtr(), 2, usUntil(deadline, now));
            contended = true;
            if (ret < 0 and ulock.errno() == ulock.ETIMEDOUT) {
                if (!tried_recovery) {
                    tried_recovery = true;
                    if (self.tryRecoverDeadHolder()) continue;
                }
                return false;
            }
        }
    }

    pub fn unlock(self: *const Mutex) void {
        @atomicStore(u32, self.holderPtr(), 0, .release);
        const prev = @atomicRmw(u32, self.statePtr(), .Xchg, 0, .release);
        if (prev == 2) ulock.wake(self.statePtr());
    }

    /// The 8-byte state block base — used by Condition's wait/relock.
    pub inline fn base(self: *const Mutex) [*]u8 {
        return self.data.ptr();
    }

    pub fn clearStorage(name: []const u8) void {
        guard.clearStorage(name, .mutex);
        ShmHandle.clearStorage(name);
    }
};

/// Microseconds from `now` until `deadline` (both monotonic ns), clamped to u32.
pub fn usUntil(deadline: i128, now: i128) u32 {
    const us = @divTrunc(deadline - now, 1000);
    if (us <= 0) return 0;
    if (us >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(us);
}
