// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Polyglot pipeline stage — one hop of a multi-language ipc::route pipeline.
//
// Usage:
//   demo_pipeline source <out> <count> <tag>
//   demo_pipeline stage  <in> <out> <count> <tag>
//   demo_pipeline sink   <in> <count> <tag>
//
// A pipeline is a chain of single-writer->single-reader ipc::route hops, each hop
// a separate process — and, because the wire format is byte-exact across the C++,
// Rust, Swift and Zig ports, each stage can be a *different language*. The source
// seeds items, every stage appends its tag, and the sink prints the fully-
// transformed item. See demo/pipeline/run.sh and the repo README.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChanInner = channel.ChanInner;

const alloc = std.heap.c_allocator;

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
/// Strip the trailing NUL the other ports append.
fn strip(raw: []const u8) []const u8 {
    return if (raw.len > 0 and raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
}

fn source(out_name: []const u8, count: usize, tag: []const u8) u8 {
    var tx = ChanInner.open(alloc, "", out_name, .sender) catch return 3;
    defer tx.deinit();
    if (!tx.waitForRecv(1, deadline(5))) {
        err("[source {s}] no downstream on '{s}' within 5s", .{ tag, out_name });
        return 2;
    }
    var k: usize = 0;
    while (k < count) : (k += 1) {
        var mbuf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&mbuf, "item-{d} [{s}]", .{ k, tag }) catch return 4;
        mbuf[body.len] = 0;
        while (!(tx.send(mbuf[0 .. body.len + 1], deadline(2)) catch false)) {}
    }
    err("[source {s}] emitted {d} items -> '{s}'", .{ tag, count, out_name });
    return 0;
}

fn stage(in_name: []const u8, out_name: []const u8, count: usize, tag: []const u8) u8 {
    var rx = ChanInner.open(alloc, "", in_name, .receiver) catch return 3;
    defer rx.deinit();
    var tx = ChanInner.open(alloc, "", out_name, .sender) catch return 3;
    defer tx.deinit();
    if (!tx.waitForRecv(1, deadline(5))) {
        err("[stage {s}] no downstream on '{s}' within 5s", .{ tag, out_name });
        return 2;
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const raw = (rx.recv(deadline(10)) catch return 5) orelse {
            err("[stage {s}] upstream stalled", .{tag});
            return 5;
        };
        defer alloc.free(raw);
        var mbuf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&mbuf, "{s} -> {s}", .{ strip(raw), tag }) catch return 4;
        mbuf[body.len] = 0;
        while (!(tx.send(mbuf[0 .. body.len + 1], deadline(2)) catch false)) {}
    }
    err("[stage {s}] forwarded {d} items '{s}' -> '{s}'", .{ tag, count, in_name, out_name });
    return 0;
}

fn sink(in_name: []const u8, count: usize, tag: []const u8) u8 {
    var rx = ChanInner.open(alloc, "", in_name, .receiver) catch return 3;
    defer rx.deinit();
    err("[sink {s}] ready on '{s}', expecting {d} items", .{ tag, in_name, count });
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const raw = (rx.recv(deadline(10)) catch return 5) orelse {
            err("[sink {s}] upstream stalled after {d}/{d}", .{ tag, i, count });
            break;
        };
        defer alloc.free(raw);
        out("{s} -> [{s} sink]", .{ strip(raw), tag });
    }
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
    const n = struct {
        fn p(s: []const u8) usize {
            return std.fmt.parseInt(usize, s, 10) catch 0;
        }
    }.p;

    if (argv.len >= 5 and std.mem.eql(u8, argv[1], "source"))
        std.process.exit(source(argv[2], n(argv[3]), argv[4]));
    if (argv.len >= 6 and std.mem.eql(u8, argv[1], "stage"))
        std.process.exit(stage(argv[2], argv[3], n(argv[4]), argv[5]));
    if (argv.len >= 5 and std.mem.eql(u8, argv[1], "sink"))
        std.process.exit(sink(argv[2], n(argv[3]), argv[4]));
    err("usage:\n  demo_pipeline source <out> <count> <tag>\n  demo_pipeline stage <in> <out> <count> <tag>\n  demo_pipeline sink <in> <count> <tag>", .{});
    std.process.exit(1);
}
