// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process semaphore via POSIX sem_open (matches the Rust/Swift
// ports). macOS lacks sem_timedwait, so timed waits poll sem_trywait with
// adaptive backoff. The name is makeShmName("<name>_s"); the C++ semaphore uses
// a different backing object, so cpp<->port semaphore interop is a known gap
// (tracked as expected-fail in tools/xlang-ci.toml).

const std = @import("std");
const c = std.c;
const shmname = @import("../platform/shmname.zig");
const layout = @import("../transport/layout.zig");

// SEM_FAILED is ((sem_t*)-1) — an all-ones (misaligned) sentinel that is only
// ever compared, never dereferenced, so we test it as an integer.
const SEM_FAILED_ADDR: usize = std.math.maxInt(usize);
const O_CREAT: c_int = @bitCast(c.O{ .CREAT = true });
const EAGAIN = @intFromEnum(c.E.AGAIN);

// std.c has the sem_* family except sem_unlink (POSIX; no wrapper here).
extern "c" fn sem_unlink(name: [*:0]const u8) c_int;
// sem_open must be called *variadically*: on Apple arm64 variadic args pass on
// the stack, so std.c's non-variadic (fixed mode_t) declaration corrupts the
// mode/value the kernel reads (→ EINVAL). Declare it variadic and pass both
// trailing args as c_uint, matching the Rust/Swift ports.
extern "c" fn sem_open(name: [*:0]const u8, oflag: c_int, ...) *c.sem_t;

pub const Error = error{OpenFailed};

pub const Semaphore = struct {
    handle: *c.sem_t,
    name_buf: [256]u8,
    name_len: usize,

    pub fn open(name: []const u8, count: u32) Error!Semaphore {
        var self: Semaphore = undefined;
        var nbuf: [256]u8 = undefined;
        const logical = std.fmt.bufPrint(&nbuf, "{s}_s", .{name}) catch return Error.OpenFailed;
        const posix = shmname.makeShmName(&self.name_buf, logical);
        self.name_len = posix.len;
        var cbuf: [257]u8 = undefined;
        @memcpy(cbuf[0..posix.len], posix);
        cbuf[posix.len] = 0;
        const h = sem_open(@ptrCast(&cbuf), O_CREAT, @as(c_uint, 0o666), @as(c_uint, count));
        if (@intFromPtr(h) == SEM_FAILED_ADDR) return Error.OpenFailed;
        self.handle = h;
        return self;
    }

    pub fn post(self: *const Semaphore, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) _ = c.sem_post(self.handle);
    }

    pub fn wait(self: *const Semaphore) void {
        _ = c.sem_wait(self.handle);
    }

    /// Wait up to `timeout_ns`. Returns true if a token was acquired.
    pub fn waitTimeout(self: *const Semaphore, timeout_ns: i128) bool {
        const deadline = layout.nowNs() + timeout_ns;
        var k: u32 = 0;
        while (true) {
            if (c.sem_trywait(self.handle) == 0) return true;
            if (c._errno().* != EAGAIN) return false;
            if (layout.nowNs() >= deadline) return false;
            layout.adaptiveYield(&k);
        }
    }

    fn posixName(self: *const Semaphore) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn deinit(self: *Semaphore) void {
        _ = c.sem_close(self.handle);
        var cbuf: [257]u8 = undefined;
        const p = self.posixName();
        @memcpy(cbuf[0..p.len], p);
        cbuf[p.len] = 0;
        _ = sem_unlink(@ptrCast(&cbuf));
    }

    pub fn clearStorage(name: []const u8) void {
        var nbuf: [256]u8 = undefined;
        const logical = std.fmt.bufPrint(&nbuf, "{s}_s", .{name}) catch return;
        var pbuf: [256]u8 = undefined;
        const posix = shmname.makeShmName(&pbuf, logical);
        var cbuf: [257]u8 = undefined;
        @memcpy(cbuf[0..posix.len], posix);
        cbuf[posix.len] = 0;
        _ = sem_unlink(@ptrCast(&cbuf));
    }
};
