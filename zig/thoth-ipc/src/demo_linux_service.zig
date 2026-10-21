// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Zig port of demo/linux_service/service/main.cpp
//
// Usage (start the client first, then the service):
//   demo_linux_service            send "Hello, World!" every 3 s, forever
//   demo_linux_service <count>    exchange <count> messages with the client, then exit
//   demo_linux_service clear      remove both channels, so the next run starts fresh
//
// The service sends on "service ipc r" and receives the client's "Copy." reply
// on "service ipc w" (both multi-writer thoth::channel). Strings go on the wire
// with an explicit trailing NUL, byte-exact with the C++ and Rust ports, so the
// service and the client can be any mix of languages.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;

const alloc = std.heap.c_allocator;
const name_r = "service ipc r";
const name_w = "service ipc w";
const hello = "Hello, World!\x00"; // with the NUL the other ports send

fn deadlineMs(ms: i128) i128 {
    return channel.nowNs() + ms * std.time.ns_per_ms;
}

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

fn runForever(ipc_r: *ChannelInner, ipc_w: *ChannelInner) noreturn {
    while (true) {
        if (!(ipc_r.send(hello, deadlineMs(100)) catch false)) {
            out("My Sample Service: send failed.", .{});
        } else {
            out("My Sample Service: send [Hello, World!]", .{});
            if (ipc_w.recv(deadlineMs(1000)) catch null) |raw| {
                defer alloc.free(raw);
                out("My Sample Service: recv [{s}]", .{text(raw)});
            } else {
                out("My Sample Service: recv error", .{});
            }
        }
        channel.sleepNs(3 * std.time.ns_per_s);
    }
}

fn runCount(ipc_r: *ChannelInner, ipc_w: *ChannelInner, count: u64) u8 {
    if (!ipc_r.waitForRecv(1, deadlineMs(5000))) {
        err("My Sample Service: no client within 5s - start the client first", .{});
        return 2;
    }
    var k: u64 = 0;
    while (k < count) : (k += 1) {
        if (!(ipc_r.send(hello, deadlineMs(100)) catch false)) {
            err("My Sample Service: send failed.", .{});
            return 4;
        }
        out("My Sample Service: send [Hello, World!]", .{});
        const raw = (ipc_w.recv(deadlineMs(5000)) catch null) orelse {
            err("My Sample Service: recv timed out", .{});
            return 5;
        };
        defer alloc.free(raw);
        const reply = text(raw);
        if (!std.mem.eql(u8, reply, "Copy.")) {
            err("My Sample Service: unexpected reply [{s}]", .{reply});
            return 6;
        }
        out("My Sample Service: recv [{s}]", .{reply});
        channel.sleepNs(100 * std.time.ns_per_ms);
    }
    return 0;
}

fn usage() noreturn {
    err("usage:\n  demo_linux_service\n  demo_linux_service <count>\n  demo_linux_service clear", .{});
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
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "clear")) {
        channel.clearStorage("", name_r); // so the next run starts fresh
        channel.clearStorage("", name_w);
        std.process.exit(0);
    }
    const count: ?u64 = if (argv.len == 2) std.fmt.parseInt(u64, argv[1], 10) catch usage() else null;

    out("My Sample Service: Main: Entry", .{});
    var ipc_r = ChannelInner.open(alloc, "", name_r, .sender) catch {
        err("My Sample Service: connect failed", .{});
        std.process.exit(3);
    };
    defer ipc_r.deinit();
    var ipc_w = ChannelInner.open(alloc, "", name_w, .receiver) catch {
        err("My Sample Service: connect failed", .{});
        std.process.exit(3);
    };
    defer ipc_w.deinit();

    const n = count orelse runForever(&ipc_r, &ipc_w);
    const rc = runCount(&ipc_r, &ipc_w, n);
    if (rc != 0) std.process.exit(rc);
    out("My Sample Service: Main: Exit", .{});
}

test "the payload loses exactly one trailing NUL" {
    try std.testing.expectEqualStrings("Hello, World!", text(hello));
    try std.testing.expectEqualStrings("Copy.", text("Copy."));
    try std.testing.expectEqual(@as(usize, 14), hello.len);
}
