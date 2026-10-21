// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process condition variable — the linux_a0 requeue-PI condition
// (a0.zig) in shared memory, byte-exact with the C++ `condition`
// (platform/linux/condition.h) and Rust's `PlatformCondition`. The shm object
// `<name>` holds one a0_cnd_t (a u32 sequence word) plus the trailing ref
// counter, zero-filled by its first opener. Paired with a SyncAbi guard sidecar
// and driven against an external Mutex.

const shm = @import("../platform/shm.zig");
const a0 = @import("a0.zig");
const guard = @import("abi_guard.zig");
const abi = @import("../abi_generated.zig");
const Mutex = @import("mutex_linux.zig").Mutex;
const LockError = @import("mutex.zig").LockError;
const WakeError = @import("condition.zig").WakeError;

const ShmHandle = shm.ShmHandle;

pub const Error = guard.Error;

pub const Condition = struct {
    data: ShmHandle,
    g: guard.Guard,

    pub fn open(name: []const u8) Error!Condition {
        var g = try guard.ensure(name, .condition);
        errdefer g.release();
        const data = try ShmHandle.acquire(name, abi.a0_cnd_size, .create_or_open);
        if (data.refCount() <= 1) @memset(data.ptr()[0..abi.a0_cnd_size], 0);
        return .{ .data = data, .g = g };
    }

    pub fn deinit(self: *Condition) void {
        self.data.release();
        self.g.release();
    }

    fn seq(self: *const Condition) *a0.Cnd {
        return @ptrCast(@alignCast(self.data.ptr()));
    }

    /// Wait until signalled or `timeout_ns` elapses. Caller holds `mutex`; it is
    /// released around the wait and held again on return. True if signalled.
    ///
    /// A mutex that comes back from a dead holder is made consistent and the
    /// wait reports a wake-up (callers re-check their predicate), as Rust does.
    pub fn wait(self: *const Condition, mutex: *const Mutex, timeout_ns: i128) LockError!bool {
        const deadline = a0.deadlineIn(@intCast(@max(timeout_ns, 0)));
        const woke = a0.wait(self.seq(), mutex.raw(), deadline) catch |err| return switch (err) {
            error.NotRecoverable => error.NotRecoverable,
            else => error.Unexpected,
        };
        switch (woke) {
            .signalled => return true,
            .timed_out => return false,
            .owner_died => {
                a0.consistent(mutex.raw()) catch unreachable; // held by this thread
                return true;
            },
        }
    }

    /// Wake one waiter, requeued onto `mutex`.
    pub fn notify(self: *const Condition, mutex: *const Mutex) WakeError!void {
        a0.signal(self.seq(), mutex.raw()) catch return error.Unexpected;
    }

    /// Wake every waiter, requeued onto `mutex`.
    pub fn broadcast(self: *const Condition, mutex: *const Mutex) WakeError!void {
        a0.broadcast(self.seq(), mutex.raw()) catch return error.Unexpected;
    }

    pub fn clearStorage(name: []const u8) void {
        guard.clearStorage(name, .condition);
        ShmHandle.clearStorage(name);
    }
};
