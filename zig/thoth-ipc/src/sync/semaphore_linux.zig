// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Named inter-process semaphore — a POSIX named semaphore, interoperable with
// the C++ `semaphore` (platform/posix/semaphore_impl.h) and Rust's
// `PosixSemaphore`. Two kernel-visible names per semaphore, as in C++:
//   * the semaphore itself: sem_open(make_shm_name("<name>_s")) — C++ appends
//     "_s" so the hash differs from the shm namespace;
//   * a 1-byte shm segment `<name>` whose trailing ref counter counts the
//     process handles, so the last one to close unlinks the semaphore.

const std = @import("std");
const c = std.c;
const shm = @import("../platform/shm.zig");
const shmname = @import("../platform/shmname.zig");
const Error = @import("semaphore.zig").Error;

const ShmHandle = shm.ShmHandle;

// std.c types sem_open's result as non-null, but glibc's SEM_FAILED is NULL.
extern "c" fn sem_open(name: [*:0]const u8, oflag: c_int, mode: c.mode_t, value: c_uint) ?*c.sem_t;
extern "c" fn sem_unlink(name: [*:0]const u8) c_int;

const o_creat: c_int = @bitCast(c.O{ .CREAT = true });

/// Writes the NUL-terminated semaphore name for logical `name` into `buf`.
fn semName(buf: *[257]u8, name: []const u8) [:0]const u8 {
    var raw: [256]u8 = undefined;
    const suffixed = std.fmt.bufPrint(&raw, "{s}_s", .{name}) catch unreachable;
    var nbuf: [256]u8 = undefined;
    const posix_name = shmname.makeShmName(&nbuf, suffixed);
    return std.fmt.bufPrintSentinel(buf, "{s}", .{posix_name}, 0) catch unreachable;
}

pub const Semaphore = struct {
    handle: *c.sem_t,
    refs: ShmHandle,
    name_buf: [257]u8,
    name_len: usize,

    pub fn open(name: []const u8, count: u32) Error!Semaphore {
        var refs = ShmHandle.acquire(name, 1, .create_or_open) catch return error.OpenFailed;
        errdefer refs.release();
        var self: Semaphore = .{ .handle = undefined, .refs = refs, .name_buf = undefined, .name_len = 0 };
        const sem_name = semName(&self.name_buf, name);
        self.name_len = sem_name.len;
        self.handle = sem_open(sem_name.ptr, o_creat, 0o666, count) orelse return error.OpenFailed;
        return self;
    }

    fn semNameZ(self: *const Semaphore) [*:0]const u8 {
        return self.name_buf[0..self.name_len :0];
    }

    /// Close this handle; the last one in any process unlinks the semaphore.
    pub fn deinit(self: *Semaphore) void {
        _ = c.sem_close(self.handle);
        if (self.refs.releaseRef() <= 1) _ = sem_unlink(self.semNameZ());
    }

    pub fn post(self: *const Semaphore, count: u32) void {
        // sem_post fails only on EOVERFLOW (count beyond SEM_VALUE_MAX).
        for (0..count) |_| std.debug.assert(c.sem_post(self.handle) == 0);
    }

    /// Block until a token is available (infinite wait).
    pub fn wait(self: *const Semaphore) void {
        while (c.sem_wait(self.handle) != 0) {
            std.debug.assert(std.posix.errno(-1) == .INTR);
        }
    }

    /// Wait up to `timeout_ns`. True if a token was acquired.
    pub fn waitTimeout(self: *const Semaphore, timeout_ns: i128) bool {
        // sem_timedwait takes an absolute CLOCK_REALTIME deadline.
        var now: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &now);
        const at = @as(i128, now.sec) * std.time.ns_per_s + now.nsec + @max(timeout_ns, 0);
        const deadline: c.timespec = .{
            .sec = @intCast(@divFloor(at, std.time.ns_per_s)),
            .nsec = @intCast(@mod(at, std.time.ns_per_s)),
        };
        while (c.sem_timedwait(self.handle, &deadline) != 0) {
            switch (std.posix.errno(-1)) {
                .INTR => continue,
                .TIMEDOUT => return false,
                else => |e| std.debug.panic("thoth-ipc: sem_timedwait failed ({t})", .{e}),
            }
        }
        return true;
    }

    pub fn clearStorage(name: []const u8) void {
        var buf: [257]u8 = undefined;
        _ = sem_unlink(semName(&buf, name).ptr);
        ShmHandle.clearStorage(name);
    }
};
