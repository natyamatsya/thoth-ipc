// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Zig port of demo/linux_service/client/main.cpp
//
// Usage (start the client first, then the service):
//   demo_linux_client            answer every "Hello, World!" with "Copy.", forever
//   demo_linux_client <count>    answer <count> messages, then exit
//
// The client receives on "service ipc r" and replies on "service ipc w" (both
// multi-writer thoth::channel). Strings go on the wire with an explicit
// trailing NUL, byte-exact with the C++ and Rust ports, so the client and the
// service can be any mix of languages. `demo_linux_service clear` removes both
// channels.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;

const alloc = std.heap.c_allocator;
const copy = "Copy.\x00"; // with the NUL the other ports send

fn deadlineMs(ms: i128) i128 {
    return channel.nowNs() + ms * std.time.ns_per_ms;
}
const forever: i128 = std.math.maxInt(i128);

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// The payload without the trailing NUL the senders append.
fn text(raw: []const u8) []const u8 {
    return if (raw.len > 0 and raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
}

fn runForever(ipc_r: *ChannelInner, ipc_w: *ChannelInner) u8 {
    while (true) {
        const raw = (ipc_r.recv(forever) catch null) orelse {
            out("My Sample Client: message recv error", .{});
            return 255;
        };
        defer alloc.free(raw);
        out("My Sample Client: message recv: [{s}]", .{text(raw)});
        while (!(ipc_w.send(copy, deadlineMs(100)) catch false)) {
            out("My Sample Client: message send error", .{});
            channel.sleepNs(std.time.ns_per_s);
        }
        out("My Sample Client: message send [Copy]", .{});
    }
}

fn runCount(ipc_r: *ChannelInner, ipc_w: *ChannelInner, count: u64) u8 {
    var k: u64 = 0;
    while (k < count) : (k += 1) {
        const raw = (ipc_r.recv(deadlineMs(10_000)) catch null) orelse {
            err("My Sample Client: message recv timed out", .{});
            return 5;
        };
        defer alloc.free(raw);
        out("My Sample Client: message recv: [{s}]", .{text(raw)});
        // The service's receiver must be there before the first reply.
        if (k == 0 and !ipc_w.waitForRecv(1, deadlineMs(5000))) {
            err("My Sample Client: no service receiver within 5s", .{});
            return 2;
        }
        if (!(ipc_w.send(copy, deadlineMs(100)) catch false)) {
            err("My Sample Client: message send error", .{});
            return 4;
        }
        out("My Sample Client: message send [Copy]", .{});
    }
    return 0;
}

fn usage() noreturn {
    err("usage:\n  demo_linux_client\n  demo_linux_client <count>", .{});
    std.process.exit(1);
}

pub fn main(m: std.process.Init.Minimal) void {
    var storage: [4][:0]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(m.args);
    while (it.next()) |a| {
        if (argc >= storage.len) break;
        storage[argc] = a;
        argc += 1;
    }
    const argv = storage[0..argc];
    if (argv.len > 2) usage();
    const count: ?u64 = if (argv.len == 2) std.fmt.parseInt(u64, argv[1], 10) catch usage() else null;

    out("My Sample Client: Entry", .{});
    var ipc_r = ChannelInner.open(alloc, "", "service ipc r", .receiver) catch {
        err("My Sample Client: connect failed", .{});
        std.process.exit(3);
    };
    defer ipc_r.deinit();
    var ipc_w = ChannelInner.open(alloc, "", "service ipc w", .sender) catch {
        err("My Sample Client: connect failed", .{});
        std.process.exit(3);
    };
    defer ipc_w.deinit();

    const rc = if (count) |n| runCount(&ipc_r, &ipc_w, n) else runForever(&ipc_r, &ipc_w);
    if (rc != 0) std.process.exit(rc);
    out("My Sample Client: Exit", .{});
}

test "the reply carries the trailing NUL" {
    try std.testing.expectEqual(@as(usize, 6), copy.len);
    try std.testing.expectEqualStrings("Copy.", text(copy));
}
