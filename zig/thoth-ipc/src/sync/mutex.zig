// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process mutex, byte-exact with the C++ `thoth::sync::mutex` of
// the same platform: the apple_ulock word-lock on macOS (mutex_apple.zig), the
// linux_a0 robust PI futex mutex on Linux (mutex_linux.zig). Both backends
// expose the same API:
//
//   open(name) Error!Mutex             deinit()
//   lock() LockError!void              unlock()
//   tryLock() LockError!bool           lockTimeout(ns) LockError!bool
//   clearStorage(name)
//
// A lock whose holder died is recovered and taken, as C++ `robust_mutex` does.

const builtin = @import("builtin");
const guard = @import("abi_guard.zig");

pub const Mutex = switch (builtin.os.tag) {
    .linux => @import("mutex_linux.zig").Mutex,
    .macos => @import("mutex_apple.zig").Mutex,
    else => @compileError("thoth-ipc: no mutex backend for " ++ @tagName(builtin.os.tag)),
};

/// Opening fails on a sync-ABI mismatch with an existing peer, or in shm.
pub const Error = guard.Error;

/// Locking can fail only on Linux, where the kernel tracks ownership.
pub const LockError = error{
    /// A holder died and the mutex was released without being recovered.
    NotRecoverable,
    /// The calling thread already holds the mutex.
    Deadlock,
    Unexpected,
};

// A holder that exited holding the lock and was not reaped (a zombie: its parent
// cannot wait for it, e.g. while a debugger traces it) holds nothing, though
// kill(pid, 0) still finds it: the next locker recovers the lock.
test "a zombie holder's lock is recovered" {
    const std = @import("std");
    const isZombie = @import("../transport/liveness.zig").isZombie;
    const name = "zig.mutex.zombie-holder";
    Mutex.clearStorage(name);
    var m = try Mutex.open(name);
    defer {
        m.deinit();
        Mutex.clearStorage(name);
    }
    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        m.lock() catch {};
        std.c._exit(0); // dies holding the lock
    }
    var zombie = false;
    var i: usize = 0;
    while (i < 300 and !zombie) : (i += 1) {
        zombie = isZombie(pid);
        if (!zombie) {
            const ts = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }
    const acquired = try m.lockTimeout(2 * std.time.ns_per_s);
    if (acquired) m.unlock();
    _ = std.c.waitpid(pid, null, 0);
    try std.testing.expect(zombie);
    try std.testing.expect(acquired);
}
