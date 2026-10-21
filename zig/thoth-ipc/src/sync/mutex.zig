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
