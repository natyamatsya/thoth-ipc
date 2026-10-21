// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Zig port of demo/msg_que/main.cpp (count mode), over thoth::route "ipc-msg-que"
// (single-producer, multi-consumer broadcast).
//
// Usage:
//   demo_msg_que s <count>   sender
//   demo_msg_que r <count>   receiver
//   demo_msg_que clear       remove the route's IPC objects
//
// Count mode is bounded and verifiable, wire- and output-identical with the C++,
// Rust and Swift ports: the sender waits up to 5 s for a receiver (else exit 2),
// then sends <count> messages, the k-th being size_k bytes all equal to k % 251,
// size_k = 128 + (k * 7919) % 16257 (2 s send timeout, else exit 4), and prints
// `do_send: sent <count> messages, <bytes> bytes`. The receiver prints
// `do_recv: ready`, checks every message (10 s recv timeout: exit 5; wrong size or
// bytes: exit 6) and prints `do_recv: received <count> messages, <bytes> bytes`.
// Messages up to 16 KB span many 64 B ring fragments (or, from C++/Rust/Swift,
// a chunk-storage slot); the route reassembles them. The run-until-signal
// throughput modes (`s` / `r` without a count) are not ported.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChanInner = channel.ChanInner;

const alloc = std.heap.c_allocator;

const name = "ipc-msg-que";
const min_sz: usize = 128;
const max_sz: usize = 1024 * 16;

fn deadline(secs: i128) i128 {
    return channel.nowNs() + secs * std.time.ns_per_s;
}
fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Size of the k-th message: 128 B .. 16 KB, spread by a prime stride.
fn sizeOf(k: usize) usize {
    return min_sz + (k * 7919) % (max_sz - min_sz + 1);
}
/// Fill byte of the k-th message.
fn byteOf(k: usize) u8 {
    return @intCast(k % 251);
}

fn doSend(count: usize) u8 {
    var tx = ChanInner.open(alloc, "", name, .sender) catch |e| {
        err("do_send: connect failed: {s}", .{@errorName(e)});
        return 3;
    };
    defer tx.deinit();
    if (!tx.waitForRecv(1, deadline(5))) {
        err("do_send: no receiver within 5 s.", .{});
        return 2;
    }
    var buf: [max_sz]u8 = undefined;
    var total: usize = 0;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const sz = sizeOf(k);
        @memset(buf[0..sz], byteOf(k));
        const ok = tx.send(buf[0..sz], deadline(2)) catch false;
        if (!ok) {
            err("do_send: send of message {d} failed.", .{k});
            return 4;
        }
        total += sz;
    }
    out("do_send: sent {d} messages, {d} bytes", .{ count, total });
    return 0;
}

fn doRecv(count: usize) u8 {
    var rx = ChanInner.open(alloc, "", name, .receiver) catch |e| {
        err("do_recv: connect failed: {s}", .{@errorName(e)});
        return 3;
    };
    defer rx.deinit();
    out("do_recv: ready", .{});
    var total: usize = 0;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const msg = (rx.recv(deadline(10)) catch null) orelse {
            err("do_recv: timed out after {d}/{d} messages.", .{ k, count });
            return 5;
        };
        defer alloc.free(msg);
        const ok = msg.len >= min_sz and msg.len <= max_sz and
            msg.len == sizeOf(k) and msg[0] == byteOf(k) and
            std.mem.allEqual(u8, msg, msg[0]);
        if (!ok) {
            err("do_recv: message {d} is corrupt ({d} bytes, expected {d} bytes of {d}).", .{ k, msg.len, sizeOf(k), byteOf(k) });
            return 6;
        }
        total += msg.len;
    }
    out("do_recv: received {d} messages, {d} bytes", .{ count, total });
    return 0;
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

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "clear")) {
        channel.clearStorage("", name);
        std.process.exit(0);
    }
    if (argv.len >= 3 and (std.mem.eql(u8, argv[1], "s") or std.mem.eql(u8, argv[1], "r"))) {
        const count = std.fmt.parseInt(usize, argv[2], 10) catch {
            err("invalid count: {s}", .{argv[2]});
            std.process.exit(1);
        };
        std.process.exit(if (argv[1][0] == 's') doSend(count) else doRecv(count));
    }
    err("usage: demo_msg_que s <count> | r <count> | clear", .{});
    std.process.exit(1);
}

test "message sizes and bytes match the other ports" {
    try std.testing.expectEqual(@as(usize, 128), sizeOf(0));
    try std.testing.expectEqual(@as(usize, 128 + 7919), sizeOf(1));
    try std.testing.expectEqual(@as(usize, 128 + (2 * 7919) % 16257), sizeOf(2));
    var k: usize = 0;
    while (k < 1000) : (k += 1) {
        try std.testing.expect(sizeOf(k) >= min_sz and sizeOf(k) <= max_sz);
    }
    try std.testing.expectEqual(@as(u8, 0), byteOf(251));
    try std.testing.expectEqual(@as(u8, 250), byteOf(250));
}
