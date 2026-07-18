// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-writer thoth::channel fan-in aggregator.
//
// Usage (run the collector first, then one or more producers):
//   demo_channel_aggregator collect <total>
//   demo_channel_aggregator produce <id> <count>
//
// N producer processes each send() into ONE shared channel; a single collector
// recv()s the merged, correctly-reassembled stream and tallies it by producer.
// This is the pattern a single-writer route cannot express — a channel has
// multiple committing writers. The wire format is byte-exact across the C++,
// Rust, Swift and Zig ports, so producers and the collector can be any mix of
// languages (see the repo README).

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;

const alloc = std.heap.c_allocator;
const channel_name = "ipc-aggregator";

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

/// The single reader: drains `total` messages from every producer and tallies.
fn collect(total: usize) u8 {
    var ch = ChannelInner.open(alloc, "", channel_name, .receiver) catch {
        err("[collector] connect failed", .{});
        return 3;
    };
    defer ch.deinit();
    out("[collector] ready on '{s}', expecting {d} messages from any number of producers", .{ channel_name, total });

    var tally = std.StringHashMap(usize).init(alloc);
    var got: usize = 0;
    while (got < total) {
        const raw = (ch.recv(deadline(10)) catch {
            err("[collector] recv error", .{});
            return 5;
        }) orelse {
            err("[collector] timed out with {d}/{d} received", .{ got, total });
            break;
        };
        defer alloc.free(raw);
        // Strip the trailing NUL the other ports append.
        const msg = if (raw.len > 0 and raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
        const producer = msg[0 .. std.mem.indexOfScalar(u8, msg, ' ') orelse msg.len];
        const gop = tally.getOrPut(producer) catch return 5;
        if (!gop.found_existing) {
            gop.key_ptr.* = alloc.dupe(u8, producer) catch return 5;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        got += 1;
        out("[collector] {d}/{d}  {s}", .{ got, total, msg });
    }

    out("\n[collector] summary — {d} messages from {d} producer(s):", .{ got, tally.count() });
    var it = tally.iterator();
    while (it.next()) |e| out("    {s}  {d}", .{ e.key_ptr.*, e.value_ptr.* });
    return 0;
}

/// One of N concurrent writers: sends `count` tagged messages into the channel.
fn produce(id: []const u8, count: usize) u8 {
    var ch = ChannelInner.open(alloc, "", channel_name, .sender) catch {
        err("[producer {s}] connect failed", .{id});
        return 3;
    };
    defer ch.deinit();
    // A channel send reaches no one without a receiver — wait for the collector.
    if (!ch.waitForRecv(1, deadline(5))) {
        err("[producer {s}] no collector within 5s — start the collector first", .{id});
        return 2;
    }
    var k: usize = 0;
    while (k < count) : (k += 1) {
        var mbuf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&mbuf, "{s} #{d}", .{ id, k }) catch return 4;
        mbuf[body.len] = 0; // trailing NUL, byte-exact with the other ports
        const msg = mbuf[0 .. body.len + 1];
        // send returns false only if the ring is momentarily full; retry.
        while (!(ch.send(msg, deadline(2)) catch false)) {}
    }
    out("[producer {s}] sent {d} messages into '{s}'", .{ id, count, channel_name });
    return 0;
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

    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "collect")) {
        std.process.exit(collect(std.fmt.parseInt(usize, argv[2], 10) catch 0));
    }
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "produce")) {
        std.process.exit(produce(argv[2], std.fmt.parseInt(usize, argv[3], 10) catch 0));
    }
    err("usage:\n  demo_channel_aggregator collect <total>\n  demo_channel_aggregator produce <id> <count>", .{});
    std.process.exit(1);
}
