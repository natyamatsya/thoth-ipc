// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Apple __ulock syscall bindings (private API, stable since macOS 10.12; used by
// libc++/pthread). These are the futex-equivalent the C++/Rust/Swift sync
// primitives are built on, so they are an unavoidable C dependency — but the
// kernel matches waiters by the *address* of the shared word, so a Zig waker
// wakes a C++/Rust/Swift waiter on the same shm word and vice versa.

const std = @import("std");

pub const UL_COMPARE_AND_WAIT_SHARED: u32 = 3;
pub const ULF_WAKE_ALL: u32 = 0x0000_0100;

extern "c" fn __ulock_wait(operation: u32, addr: *u32, value: u64, timeout_us: u32) c_int;
extern "c" fn __ulock_wake(operation: u32, addr: *u32, wake_value: u64) c_int;

/// Block while `addr.*` == `value`, up to `timeout_us` microseconds (0 = forever).
/// Returns the raw syscall result (<0 on error/timeout; check errno).
pub fn wait(addr: *u32, value: u64, timeout_us: u32) c_int {
    return __ulock_wait(UL_COMPARE_AND_WAIT_SHARED, addr, value, timeout_us);
}

/// Wake one waiter parked on `addr`.
pub fn wake(addr: *u32) void {
    _ = __ulock_wake(UL_COMPARE_AND_WAIT_SHARED, addr, 0);
}

/// Wake every waiter parked on `addr`.
pub fn wakeAll(addr: *u32) void {
    _ = __ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL, addr, 0);
}

pub fn errno() c_int {
    return std.c._errno().*;
}

pub const ETIMEDOUT = @intFromEnum(std.c.E.TIMEDOUT);
pub const EINTR = @intFromEnum(std.c.E.INTR);
