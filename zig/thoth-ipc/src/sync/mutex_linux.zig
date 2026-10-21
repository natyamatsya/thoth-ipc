// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process mutex — the linux_a0 robust PI futex mutex (a0.zig) in
// shared memory, byte-exact with the C++ `robust_mutex` (platform/linux/mutex.h)
// and Rust's `PlatformMutex` (platform/linux.rs). The shm object `<name>` holds
// one a0_mtx_t (24 B) plus the trailing ref counter; its first opener
// zero-fills it, as C++ does (`*h_ = A0_EMPTY` when `ref() <= 1`). The mutex is
// paired with a SyncAbi guard sidecar.
//
// The kernel links a held mutex into the holder's robust list by address, so a
// process must map each name once and unlock before `deinit`.

const std = @import("std");
const shm = @import("../platform/shm.zig");
const a0 = @import("a0.zig");
const guard = @import("abi_guard.zig");
const abi = @import("../abi_generated.zig");
const LockError = @import("mutex.zig").LockError;

const ShmHandle = shm.ShmHandle;

pub const Error = guard.Error;

pub const Mutex = struct {
    data: ShmHandle,
    g: guard.Guard,

    pub fn open(name: []const u8) Error!Mutex {
        var g = try guard.ensure(name, .mutex);
        errdefer g.release();
        const data = try ShmHandle.acquire(name, abi.a0_mtx_size, .create_or_open);
        if (data.refCount() <= 1) @memset(data.ptr()[0..abi.a0_mtx_size], 0);
        return .{ .data = data, .g = g };
    }

    pub fn deinit(self: *Mutex) void {
        self.data.release();
        self.g.release();
    }

    /// The shared a0_mtx_t (also the requeue target of a paired Condition).
    pub fn raw(self: *const Mutex) *a0.Mtx {
        return @ptrCast(@alignCast(self.data.ptr()));
    }

    /// C++ `robust_mutex::lock(tm)`: true once held, false on timeout. A dead
    /// holder's lock is made consistent, released and taken again.
    fn lockUntil(self: *const Mutex, deadline: ?std.os.linux.timespec) LockError!bool {
        while (true) {
            const how = a0.lock(self.raw(), deadline) catch |err| return switch (err) {
                error.Timeout => false,
                error.NotRecoverable => error.NotRecoverable,
                error.Deadlock => error.Deadlock,
                else => error.Unexpected,
            };
            switch (how) {
                .clean => return true,
                .owner_died => {
                    // This thread owns it, so neither call can fail.
                    a0.consistent(self.raw()) catch unreachable;
                    a0.unlock(self.raw()) catch unreachable;
                },
            }
        }
    }

    pub fn lock(self: *const Mutex) LockError!void {
        std.debug.assert(try self.lockUntil(null));
    }

    /// A timed lock with deadline "now", as C++ does. A mutex the calling
    /// thread already holds is busy, as with `pthread_mutex_trylock`.
    pub fn tryLock(self: *const Mutex) LockError!bool {
        return self.lockUntil(a0.deadlineIn(0)) catch |err| switch (err) {
            error.Deadlock => false,
            else => err,
        };
    }

    /// Timed lock (robust). True if acquired within `timeout_ns`.
    pub fn lockTimeout(self: *const Mutex, timeout_ns: i128) LockError!bool {
        return self.lockUntil(a0.deadlineIn(@intCast(@max(timeout_ns, 0))));
    }

    /// Unlock a mutex the calling thread holds.
    pub fn unlock(self: *const Mutex) void {
        a0.unlock(self.raw()) catch |err| std.debug.panic("thoth-ipc: unlocking a mutex this thread does not hold ({t})", .{err});
    }

    pub fn clearStorage(name: []const u8) void {
        guard.clearStorage(name, .mutex);
        ShmHandle.clearStorage(name);
    }
};
