// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Named inter-process condition variable — Apple ulock seq-counter condvar in
// shared memory, byte-exact with cpp/libipc apple/condition.h and the ports.
//   @0 seq     atomic<u32>  bumped on every notify/broadcast
//   @4 waiters atomic<i32>  count of threads currently in __ulock_wait
// Paired with a SyncAbi guard sidecar and driven against an external Mutex.

const std = @import("std");
const shm = @import("../platform/shm.zig");
const ulock = @import("ulock.zig");
const guard = @import("abi_guard.zig");
const Mutex = @import("mutex.zig").Mutex;
const usUntil = @import("mutex.zig").usUntil;
const nowNs = @import("../transport/layout.zig").nowNs;

const ShmHandle = shm.ShmHandle;

pub const Error = guard.Error;

pub const Condition = struct {
    data: ShmHandle,
    g: guard.Guard,

    pub fn open(name: []const u8) Error!Condition {
        var g = try guard.ensure(name, .condition);
        errdefer g.release();
        const data = try ShmHandle.acquire(name, 8, .create_or_open);
        return .{ .data = data, .g = g };
    }

    pub fn deinit(self: *Condition) void {
        self.data.release();
        self.g.release();
    }

    inline fn seqPtr(self: *const Condition) *u32 {
        return @ptrCast(@alignCast(self.data.ptr()));
    }
    inline fn waitersPtr(self: *const Condition) *i32 {
        return @ptrCast(@alignCast(self.data.ptr() + 4));
    }

    /// Wait until signalled or `timeout_ns` elapses. Caller holds `mutex`; it is
    /// released around the wait and re-acquired before returning. Returns true if
    /// signalled, false on timeout.
    pub fn wait(self: *const Condition, mutex: *const Mutex, timeout_ns: i128) bool {
        const expected = @atomicLoad(u32, self.seqPtr(), .acquire);
        _ = @atomicRmw(i32, self.waitersPtr(), .Add, 1, .monotonic);
        mutex.unlock();
        const deadline = nowNs() + timeout_ns;
        var notified = false;
        while (true) {
            if (@atomicLoad(u32, self.seqPtr(), .acquire) != expected) {
                notified = true;
                break;
            }
            const now = nowNs();
            if (now >= deadline) break;
            const ret = ulock.wait(self.seqPtr(), expected, usUntil(deadline, now));
            if (ret >= 0) continue;
            const err = ulock.errno();
            if (err == ulock.EINTR) continue;
            if (err == ulock.ETIMEDOUT) break;
            break;
        }
        if (@atomicLoad(u32, self.seqPtr(), .acquire) != expected) notified = true;
        _ = @atomicRmw(i32, self.waitersPtr(), .Sub, 1, .monotonic);
        mutex.lock();
        return notified;
    }

    pub fn notify(self: *const Condition) void {
        _ = @atomicRmw(u32, self.seqPtr(), .Add, 1, .acq_rel);
        if (@atomicLoad(i32, self.waitersPtr(), .acquire) > 0) ulock.wake(self.seqPtr());
    }

    pub fn broadcast(self: *const Condition) void {
        _ = @atomicRmw(u32, self.seqPtr(), .Add, 1, .acq_rel);
        if (@atomicLoad(i32, self.waitersPtr(), .acquire) > 0) ulock.wakeAll(self.seqPtr());
    }

    pub fn clearStorage(name: []const u8) void {
        guard.clearStorage(name, .condition);
        ShmHandle.clearStorage(name);
    }
};
