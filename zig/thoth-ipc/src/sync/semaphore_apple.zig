// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process semaphore — Apple ulock-based counting semaphore in shared
// memory, byte-exact with cpp/thoth-ipc apple/semaphore_impl.h and the Rust/Swift
// ports (so cpp<->zig<->rust<->swift semaphores interoperate).
//
// Shared state is a single 32-bit atomic count at offset 0 of the shm user
// region (C++ `struct ulock_sem_t { atomic<u32> count; }`, sizeof 4). ShmHandle
// appends C++'s trailing acc_ ref counter (calcSize(4) = 8).
//
//   post(n): for each: count += 1, then __ulock_wake one waiter.
//   wait(tm): CAS-decrement while count > 0; when count == 0, __ulock_wait on
//             &count (value 0) until it changes, then retry.

const std = @import("std");
const shm = @import("../platform/shm.zig");
const ulock = @import("ulock.zig");
const layout = @import("../transport/layout.zig");

const ShmHandle = shm.ShmHandle;

pub const Error = error{OpenFailed};

pub const Semaphore = struct {
    data: ShmHandle,

    pub fn open(name: []const u8, count: u32) Error!Semaphore {
        // The harness passes the fully-qualified logical name ("<name>_s");
        // ShmHandle.acquire hashes it (makeShmName) to the byte-exact shm object
        // name, matching C++ shm::acquire("<name>_s"). A SINGLE transform — do
        // NOT append another "_s".
        // sizeof(ulock_sem_t) = 4 (atomic<u32> count); ShmHandle appends the C++
        // trailing acc_ ref counter (calcSize(4) = 8).
        const data = ShmHandle.acquire(name, @sizeOf(u32), .create_or_open) catch
            return Error.OpenFailed;
        const self = Semaphore{ .data = data };
        // First opener initialises the count (mirrors C++ `ref() <= 1`).
        if (self.data.refCount() <= 1) {
            @atomicStore(u32, self.countPtr(), count, .release);
        }
        return self;
    }

    inline fn countPtr(self: *const Semaphore) *u32 {
        return @ptrCast(@alignCast(self.data.ptr()));
    }

    pub fn post(self: *const Semaphore, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            _ = @atomicRmw(u32, self.countPtr(), .Add, 1, .release);
            // Wake one waiter per post.
            ulock.wake(self.countPtr());
        }
    }

    /// Block until a token is available (infinite wait).
    pub fn wait(self: *const Semaphore) void {
        while (true) {
            var cur = @atomicLoad(u32, self.countPtr(), .acquire);
            while (cur > 0) {
                if (@cmpxchgWeak(u32, self.countPtr(), cur, cur - 1, .acquire, .monotonic)) |c| {
                    cur = c;
                } else {
                    return;
                }
            }
            // count == 0: sleep until it changes; loop on EINTR/spurious.
            _ = ulock.wait(self.countPtr(), 0, 0);
        }
    }

    /// Wait up to `timeout_ns`. Returns true if a token was acquired.
    pub fn waitTimeout(self: *const Semaphore, timeout_ns: i128) bool {
        const deadline = layout.nowNs() + timeout_ns;
        while (true) {
            // Try to decrement (CAS loop); succeeds while count > 0.
            var cur = @atomicLoad(u32, self.countPtr(), .acquire);
            while (cur > 0) {
                if (@cmpxchgWeak(u32, self.countPtr(), cur, cur - 1, .acquire, .monotonic)) |c| {
                    cur = c;
                } else {
                    return true;
                }
            }
            // count == 0: sleep until it changes (or timeout).
            const now = layout.nowNs();
            if (now >= deadline) return false;
            const timeout_us = usUntil(deadline, now);
            if (timeout_us == 0) return false;
            const ret = ulock.wait(self.countPtr(), 0, timeout_us);
            if (ret < 0 and ulock.errno() == ulock.ETIMEDOUT) return false;
            // Woken, EINTR or spurious: loop back and retry the CAS.
        }
    }

    pub fn deinit(self: *Semaphore) void {
        self.data.release();
    }

    pub fn clearStorage(name: []const u8) void {
        // Same SINGLE name transform as open (makeShmName on "<name>_s").
        ShmHandle.clearStorage(name);
    }
};

/// Microseconds from `now` until `deadline` (both monotonic ns), clamped to u32.
fn usUntil(deadline: i128, now: i128) u32 {
    const us = @divTrunc(deadline - now, 1000);
    if (us <= 0) return 0;
    if (us >= std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(us);
}
