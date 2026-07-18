// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Layer 1 notify readiness (ABI §8, macOS libnotify backend). A sender posts on
// enqueue; an async receiver registers a readiness fd and wakes on the post. The
// service key is byte-exact across languages so a Zig sender wakes a C++/Rust/
// Swift async receiver and vice versa:
//   key = "thoth.ntf." + 16-hex(fnv1a_64("{prefix}__THOTH_SHM__NOTIFY__{name}"))
// Golden: ("","xchan") -> 098e889ce378ae04 (unit-tested in shmname.zig).

const std = @import("std");
const shmname = @import("../platform/shmname.zig");

const NOTIFY_STATUS_OK: u32 = 0;
const POLLIN: i16 = 0x0001;
const O_NONBLOCK: c_int = 0x0004; // Darwin

// libnotify (libSystem) — private-but-stable notification service.
extern "c" fn notify_post(name: [*:0]const u8) u32;
extern "c" fn notify_register_file_descriptor(name: [*:0]const u8, notify_fd: *c_int, flags: c_int, out_token: *c_int) u32;
extern "c" fn notify_cancel(token: c_int) u32;

/// Build the libnotify service key for (prefix, name) into `buf`, NUL-terminated.
fn serviceKey(buf: []u8, prefix: []const u8, name: []const u8) [:0]const u8 {
    var sbuf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&sbuf, "{s}__THOTH_SHM__NOTIFY__{s}", .{ prefix, name }) catch unreachable;
    const hash = shmname.fnv1a64(s);
    const key = std.fmt.bufPrint(buf, "thoth.ntf.{x:0>16}\x00", .{hash}) catch unreachable;
    return key[0 .. key.len - 1 :0];
}

/// Post the readiness signal (multicast — one post wakes every registered
/// reader). A no-op if nobody is listening, so it is cheap to call on every send.
pub fn post(prefix: []const u8, name: []const u8) void {
    var buf: [64]u8 = undefined;
    _ = notify_post(serviceKey(&buf, prefix, name).ptr);
}

/// A receiver's readiness fd — signalled (a 4-byte token per post) whenever any
/// language's sender posts. Level-triggered: drain the queued tokens after a wake.
pub const Sink = struct {
    fd: c_int = -1,
    token: c_int = 0,
    valid: bool = false,

    pub fn open(prefix: []const u8, name: []const u8) Sink {
        var buf: [64]u8 = undefined;
        const key = serviceKey(&buf, prefix, name);
        var self = Sink{};
        if (notify_register_file_descriptor(key.ptr, &self.fd, 0, &self.token) != NOTIFY_STATUS_OK) return self;
        // Non-blocking so drain() can read tokens until they run out.
        const fl = std.c.fcntl(self.fd, std.c.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(self.fd, std.c.F.SETFL, fl | O_NONBLOCK);
        self.valid = true;
        return self;
    }

    /// Block until the fd signals or `timeout_ms` elapses. Returns true on signal.
    pub fn wait(self: *const Sink, timeout_ms: i32) bool {
        var pfd = std.c.pollfd{ .fd = self.fd, .events = POLLIN, .revents = 0 };
        const n = std.c.poll(@ptrCast(&pfd), 1, timeout_ms);
        return n > 0 and (pfd.revents & POLLIN) != 0;
    }

    /// Drain queued readiness tokens (4-byte ints) until the fd would block.
    pub fn drain(self: *const Sink) void {
        var scratch: [64]u8 = undefined;
        while (std.c.read(self.fd, &scratch, scratch.len) > 0) {}
    }

    pub fn close(self: *Sink) void {
        if (!self.valid) return;
        _ = notify_cancel(self.token);
        _ = std.c.close(self.fd);
        self.valid = false;
    }
};

test "service key matches the golden notify hash" {
    var buf: [64]u8 = undefined;
    const key = serviceKey(&buf, "", "xchan");
    try std.testing.expectEqualStrings("thoth.ntf.098e889ce378ae04", key);
}
