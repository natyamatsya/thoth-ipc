// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Zig port of demo/send_recv/main.cpp and the Rust demo_send_recv.
//
// Usage:
//   demo_send_recv send <size> <interval_ms> [count]
//   demo_send_recv recv <interval_ms> [count]
//   demo_send_recv clear
//
// Two processes share a multi-writer thoth::channel named "ipc".
// The sender fills a buffer of <size> bytes with 'A' (raw, no trailing NUL)
// and sends it every <interval_ms> milliseconds. The receiver prints the size
// of every message it receives.
//
// Without <count> both run until killed, like the Rust port: the sender
// clears the channel, waits for a receiver and sends forever; the receiver
// polls with an <interval_ms> timeout. With <count> the run is bounded: the
// receiver prints "recv ready" and exits 0 after <count> messages (exit 5 if
// one does not arrive within 10 s); the sender waits up to 5 s for a receiver
// (else exit 2), sends <count> messages with a 2 s send timeout (exit 4 on
// failure) and exits 0. `clear` removes the channel's storage. Wire-identical
// with the C++, Rust and Swift ports, so the roles mix across languages.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;

const alloc = std.heap.c_allocator;
const channel_name = "ipc";

fn deadlineMs(ms: u64) i128 {
    return channel.nowNs() + @as(i128, ms) * std.time.ns_per_ms;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Sends `size` bytes of 'A' every `interval_ms`: `count` times, or forever
/// when `count` is null.
fn send(size: usize, interval_ms: u64, count: ?usize) u8 {
    if (count == null) channel.clearStorage("", channel_name); // as the Rust port does
    var ch = ChannelInner.open(alloc, "", channel_name, .sender) catch {
        err("send: connect failed", .{});
        return 3;
    };
    defer ch.deinit();
    const buffer = alloc.alloc(u8, size) catch {
        err("send: out of memory", .{});
        return 3;
    };
    defer alloc.free(buffer);
    @memset(buffer, 'A');

    const n = count orelse {
        out("send: waiting for receiver...", .{});
        _ = ch.waitForRecv(1, std.math.maxInt(i128));
        out("send: receiver connected, starting", .{});
        while (true) {
            out("send size: {d}", .{buffer.len});
            _ = ch.send(buffer, channel.nowNs()) catch false;
            channel.sleepNs(interval_ms * std.time.ns_per_ms);
        }
    };

    if (!ch.waitForRecv(1, deadlineMs(5000))) {
        err("send: no receiver within 5s -- start the receiver first", .{});
        return 2;
    }
    for (0..n) |k| {
        out("send size: {d}", .{buffer.len});
        if (!(ch.send(buffer, deadlineMs(2000)) catch false)) {
            err("send: failed to send message {d}", .{k});
            return 4;
        }
        channel.sleepNs(interval_ms * std.time.ns_per_ms);
    }
    return 0;
}

/// Prints the size of every received message: `count` of them (10 s timeout
/// each), or forever (polling every `interval_ms`) when `count` is null.
fn recv(interval_ms: u64, count: ?usize) u8 {
    var ch = ChannelInner.open(alloc, "", channel_name, .receiver) catch {
        err("recv: connect failed", .{});
        return 3;
    };
    defer ch.deinit();

    const n = count orelse {
        var k: usize = 1;
        while (true) {
            out("recv waiting... {d}", .{k});
            const buf = (ch.recv(deadlineMs(interval_ms)) catch null) orelse {
                k += 1;
                continue;
            };
            defer alloc.free(buf);
            out("recv size: {d}", .{buf.len});
            k = 1;
        }
    };

    out("recv ready", .{});
    for (0..n) |k| {
        const buf = (ch.recv(deadlineMs(10_000)) catch null) orelse {
            err("recv: timed out waiting for message {d}", .{k});
            return 5;
        };
        defer alloc.free(buf);
        out("recv size: {d}", .{buf.len});
    }
    return 0;
}

fn usage() noreturn {
    err("usage:\n  demo_send_recv send <size> <interval_ms> [count]\n  demo_send_recv recv <interval_ms> [count]\n  demo_send_recv clear", .{});
    std.process.exit(1);
}

fn parse(comptime T: type, s: []const u8) T {
    return std.fmt.parseInt(T, s, 10) catch usage();
}

pub fn main(m: std.process.Init.Minimal) void {
    var storage: [8][:0]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(m.args);
    while (it.next()) |a| {
        if (argc >= storage.len) break;
        storage[argc] = a;
        argc += 1;
    }
    const argv = storage[0..argc];
    const verb: []const u8 = if (argv.len > 1) argv[1] else "";

    if (std.mem.eql(u8, verb, "clear")) {
        channel.clearStorage("", channel_name);
        std.process.exit(0);
    }
    if (std.mem.eql(u8, verb, "send") and argv.len >= 4) {
        const count: ?usize = if (argv.len >= 5) parse(usize, argv[4]) else null;
        std.process.exit(send(parse(usize, argv[2]), parse(u64, argv[3]), count));
    }
    if (std.mem.eql(u8, verb, "recv") and argv.len >= 3) {
        const count: ?usize = if (argv.len >= 4) parse(usize, argv[3]) else null;
        std.process.exit(recv(parse(u64, argv[2]), count));
    }
    usage();
}
