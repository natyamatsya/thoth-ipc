// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Aggregates the byte-exact ABI unit tests. `zig build test`.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("platform/shmname.zig"));
    std.testing.refAllDecls(@import("platform/shm.zig"));
    std.testing.refAllDecls(@import("transport/layout.zig"));
    std.testing.refAllDecls(@import("transport/chunk.zig"));
    std.testing.refAllDecls(@import("transport/waiter.zig"));
    std.testing.refAllDecls(@import("transport/liveness.zig"));
    std.testing.refAllDecls(@import("transport/notify.zig"));
    std.testing.refAllDecls(@import("transport/channel.zig"));
    std.testing.refAllDecls(@import("sync/ulock.zig"));
    std.testing.refAllDecls(@import("sync/abi_guard.zig"));
    std.testing.refAllDecls(@import("sync/mutex.zig"));
    std.testing.refAllDecls(@import("sync/condition.zig"));
    std.testing.refAllDecls(@import("sync/semaphore.zig"));
    std.testing.refAllDecls(@import("secure/secure.zig"));
}
