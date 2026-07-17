// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
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
    std.testing.refAllDecls(@import("transport/channel.zig"));
}
