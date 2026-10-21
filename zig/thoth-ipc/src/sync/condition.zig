// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process condition variable, byte-exact with the C++
// `thoth::sync::condition` of the same platform: the apple_ulock seq-counter
// condvar on macOS (condition_apple.zig), the linux_a0 requeue-PI condition on
// Linux (condition_linux.zig). Both backends expose the same API:
//
//   open(name) Error!Condition                   deinit()
//   wait(mutex, ns) LockError!bool               (true = signalled)
//   notify(mutex) WakeError!void                 broadcast(mutex) WakeError!void
//   clearStorage(name)
//
// Waking takes the paired mutex: Linux waiters sleep requeued onto it.

const builtin = @import("builtin");

pub const Condition = switch (builtin.os.tag) {
    .linux => @import("condition_linux.zig").Condition,
    .macos => @import("condition_apple.zig").Condition,
    else => @compileError("thoth-ipc: no condition backend for " ++ @tagName(builtin.os.tag)),
};

pub const Error = @import("mutex.zig").Error;
pub const LockError = @import("mutex.zig").LockError;
pub const WakeError = error{Unexpected};
