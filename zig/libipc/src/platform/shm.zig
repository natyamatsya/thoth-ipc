// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/shm_posix.cpp — a named,
// inter-process shared memory handle binary-compatible with ipc::shm::handle.
// The mapped region ends with a trailing atomic<int32> reference counter shared
// between all processes mapping the same segment (C++ calc_size/get_mem).
//
// Uses std.posix for mmap/munmap and std.c for the POSIX shm-specific calls
// (shm_open/shm_unlink have no std.posix wrapper). No hand-rolled externs.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const shmname = @import("shmname.zig");

comptime {
    // macOS-first port: the ftruncate-once-on-create quirk below is Darwin.
    std.debug.assert(builtin.os.tag == .macos);
}

const perms: c.mode_t = 0o666;
const o_create: c_int = @bitCast(c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
const o_open: c_int = @bitCast(c.O{ .ACCMODE = .RDWR });

pub const ShmError = error{ InvalidArgument, OsError };

pub const OpenMode = enum { create, open, create_or_open };

/// Total mapped size including the trailing atomic<int32> ref-counter.
/// Mirrors C++ calc_size(user_size): align(user_size,4) + sizeof(int32).
pub fn calcSize(user_size: usize) usize {
    const a = ((user_size - 1) / 4 + 1) * 4;
    return a + 4;
}

pub const ShmHandle = struct {
    mem: []align(std.heap.page_size_min) u8,
    user_size: usize,
    posix_name_buf: [256]u8,
    posix_name_len: usize,

    /// Acquire a named shared memory region of `size` user bytes.
    pub fn acquire(name: []const u8, size: usize, mode: OpenMode) ShmError!ShmHandle {
        if (name.len == 0) return ShmError.InvalidArgument;
        if (size == 0) return ShmError.InvalidArgument;

        var self: ShmHandle = undefined;
        self.user_size = size;
        const total = calcSize(size);

        const posix_name = shmname.makeShmName(&self.posix_name_buf, name);
        self.posix_name_len = posix_name.len;
        var cbuf: [257]u8 = undefined;
        @memcpy(cbuf[0..posix_name.len], posix_name);
        cbuf[posix_name.len] = 0;
        const cname: [*:0]const u8 = @ptrCast(&cbuf);

        var fd: c_int = -1;
        var need_truncate = false;
        switch (mode) {
            .create => {
                fd = c.shm_open(cname, o_create, perms);
                if (fd == -1) return ShmError.OsError;
                need_truncate = true;
            },
            .open => {
                fd = c.shm_open(cname, o_open, perms);
                if (fd == -1) return ShmError.OsError;
            },
            .create_or_open => {
                fd = c.shm_open(cname, o_create, perms);
                if (fd != -1) {
                    need_truncate = true;
                } else {
                    if (posix.errno(fd) != .EXIST) return ShmError.OsError;
                    fd = c.shm_open(cname, o_open, perms);
                    if (fd == -1) return ShmError.OsError;
                }
            },
        }
        defer _ = c.close(fd);

        _ = c.fchmod(fd, perms);

        // macOS: ftruncate only on first creation — it errors on an
        // already-sized shm object.
        if (need_truncate) {
            if (c.ftruncate(fd, @intCast(total)) != 0) return ShmError.OsError;
        }

        self.mem = posix.mmap(
            null,
            total,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return ShmError.OsError;

        // Increment the trailing ref-counter (mirrors C++ get_mem).
        _ = @atomicRmw(i32, self.refCountPtr(), .Add, 1, .acq_rel);
        return self;
    }

    pub inline fn ptr(self: *const ShmHandle) [*]u8 {
        return self.mem.ptr;
    }

    fn refCountPtr(self: *const ShmHandle) *i32 {
        return @ptrCast(@alignCast(self.mem.ptr + self.mem.len - 4));
    }

    fn posixName(self: *const ShmHandle) []const u8 {
        return self.posix_name_buf[0..self.posix_name_len];
    }

    /// Decrement the ref-counter, unmap, and unlink when we were the last.
    pub fn release(self: *ShmHandle) void {
        const prev = @atomicRmw(i32, self.refCountPtr(), .Sub, 1, .acq_rel);
        posix.munmap(self.mem);
        if (prev <= 1) unlinkName(self.posixName());
    }

    /// Remove the backing storage for a named shm segment without a handle.
    pub fn clearStorage(name: []const u8) void {
        var buf: [256]u8 = undefined;
        unlinkName(shmname.makeShmName(&buf, name));
    }
};

fn unlinkName(posix_name: []const u8) void {
    var cbuf: [257]u8 = undefined;
    @memcpy(cbuf[0..posix_name.len], posix_name);
    cbuf[posix_name.len] = 0;
    _ = c.shm_unlink(@ptrCast(&cbuf));
}

test "calcSize matches C++ calc_size" {
    try std.testing.expectEqual(@as(usize, 22788), calcSize(22784));
    try std.testing.expectEqual(@as(usize, 8), calcSize(4));
    try std.testing.expectEqual(@as(usize, 8), calcSize(1));
}
