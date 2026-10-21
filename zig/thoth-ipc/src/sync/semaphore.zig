// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process counting semaphore, interoperable with the C++
// `thoth::sync::semaphore` of the same platform: a shm-ulock counter on macOS
// (semaphore_apple.zig), a POSIX named `sem_open` semaphore on Linux
// (semaphore_linux.zig). Both backends expose the same API:
//
//   open(name, count) Error!Semaphore      deinit()
//   post(n)   wait()   waitTimeout(ns) bool
//   clearStorage(name)
//
// `name` is the fully-qualified logical name (the xlang harnesses pass
// "<name>_s"), exactly what C++ is constructed with.

const builtin = @import("builtin");

pub const Semaphore = switch (builtin.os.tag) {
    .linux => @import("semaphore_linux.zig").Semaphore,
    .macos => @import("semaphore_apple.zig").Semaphore,
    else => @compileError("thoth-ipc: no semaphore backend for " ++ @tagName(builtin.os.tag)),
};

pub const Error = error{OpenFailed};
