// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-language round-trip harness (Zig endpoint). Shares the CLI contract of
// the C++ (xlang_ipc), Rust (xlang) and Swift (xlang-harness) harnesses so the
// matrix driver (tools/xlang-runner) can pair Zig with any other language on the
// ipc::route wire. See tools/xlang-runner/README.md.
//
// v1 verbs: write / read (route), clear, caps. `caps` reports an empty set, so
// the runner joins only the sync and fanout scenarios and plans around the rest.
// Payload pattern: byte[i] = 'A' + (i % 26). Exit codes match the other ports:
//   0 ok · 1 usage/unknown · 2 too few receivers in 5s · 3 connect fail
//   4 send fail · 5 recv error/timeout · 6 wrong size · 7 payload mismatch

const std = @import("std");
const channel = @import("transport/channel.zig");

const ChanInner = channel.ChanInner;
const alloc = std.heap.c_allocator;

fn deadline(secs: i128) i128 {
    return channel.nowNs() + secs * std.time.ns_per_s;
}

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @intCast(65 + (i % 26));
}

fn perr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// Print a line to stdout (the runner compares trimmed stdout for reaper verbs).
fn pout(comptime fmt: []const u8, args: anytype) void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

// --- Reaper verbs (scenario: reap) -----------------------------------------
// hold: connect a receiver, print READY, hold the slot (SIGKILL target).
// probe: connect as a SENDER (no reap, no slot claim), report recv count.
// count: connect as a RECEIVER (reap-on-connect runs), report recv count.

fn doHold(name: []const u8, secs: u64) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig] connect(receiver) failed", .{});
        return 3;
    };
    // Note: no deinit — a `hold` process is SIGKILLed by the reap test, so the
    // slot must stay owned (dead) until a peer reaps it. On a clean timeout exit
    // we also leak deliberately so behaviour matches the SIGKILL path.
    pout("READY", .{});
    channel.sleepNs(secs * std.time.ns_per_s);
    _ = &ch;
    return 0;
}

fn doProbe(name: []const u8) u8 {
    var ch = ChanInner.open(alloc, "", name, .sender) catch {
        perr("[zig] connect(sender) failed", .{});
        return 3;
    };
    defer ch.deinit();
    pout("{d}", .{ch.recvCount()});
    return 0;
}

fn doCount(name: []const u8) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();
    pout("{d}", .{ch.recvCount()});
    return 0;
}

fn doWrite(name: []const u8, count: usize, size: usize, minrecv: usize) u8 {
    var ch = ChanInner.open(alloc, "", name, .sender) catch {
        perr("[zig] connect(sender) failed", .{});
        return 3;
    };
    defer ch.deinit();

    if (!ch.waitForRecv(minrecv, deadline(5))) {
        perr("[zig] fewer than {d} receivers within 5s", .{minrecv});
        return 2;
    }
    const msg = alloc.alloc(u8, size) catch return 4;
    defer alloc.free(msg);
    fillPattern(msg);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ok = ch.send(msg, deadline(8)) catch false;
        if (!ok) {
            perr("[zig] send {d} failed", .{i});
            return 4;
        }
    }
    perr("[zig] wrote {d} x {d}B on '{s}'", .{ count, size, name });
    return 0;
}

fn doRead(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();

    const want = alloc.alloc(u8, size) catch return 5;
    defer alloc.free(want);
    fillPattern(want);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const got = (ch.recv(deadline(8)) catch {
            perr("[zig] recv {d} error", .{i});
            return 5;
        }) orelse {
            perr("[zig] recv {d} timed out", .{i});
            return 5;
        };
        defer alloc.free(got);
        if (got.len != size) {
            perr("[zig] recv {d} wrong size: got {d} want {d}", .{ i, got.len, size });
            return 6;
        }
        if (!std.mem.eql(u8, got, want)) {
            perr("[zig] recv {d} payload mismatch", .{i});
            return 7;
        }
    }
    perr("[zig] read {d} x {d}B on '{s}' OK", .{ count, size, name });
    return 0;
}

pub fn main(m: std.process.Init.Minimal) void {
    // Collect argv (Zig 0.16 Args iterator) into a small fixed array.
    var storage: [8][:0]const u8 = undefined;
    var argc: usize = 0;
    var it = std.process.Args.Iterator.init(m.args);
    while (it.next()) |a| {
        if (argc >= storage.len) break;
        storage[argc] = a;
        argc += 1;
    }
    const argv = storage[0..argc];

    if (argv.len < 3) {
        perr("usage: xlang <write|read|clear|caps> <name> [count] [size] [minrecv]", .{});
        std.process.exit(1);
    }
    const verb = argv[1];
    const name = argv[2];

    if (std.mem.eql(u8, verb, "clear")) {
        channel.clearStorage("", name);
        std.process.exit(0);
    }
    if (std.mem.eql(u8, verb, "caps")) {
        // No capabilities advertised (empty set) — the runner joins the
        // scenarios this port's modes list (sync/fanout/reap) and skips the
        // cap-gated ones (primitives/typed/secure/async/channel).
        _ = std.c.write(1, "\n", 1);
        std.process.exit(0);
    }

    // Reaper verbs (scenario: reap) — hold takes an optional seconds arg.
    if (std.mem.eql(u8, verb, "hold")) {
        const secs: u64 = if (argv.len > 3) (std.fmt.parseInt(u64, argv[3], 10) catch 30) else 30;
        std.process.exit(doHold(name, secs));
    }
    if (std.mem.eql(u8, verb, "probe")) std.process.exit(doProbe(name));
    if (std.mem.eql(u8, verb, "count")) std.process.exit(doCount(name));

    if (argv.len < 5) {
        perr("write/read need <count> <size>", .{});
        std.process.exit(1);
    }
    const count = std.fmt.parseInt(usize, argv[3], 10) catch 0;
    const size = std.fmt.parseInt(usize, argv[4], 10) catch 0;

    const code: u8 = blk: {
        if (std.mem.eql(u8, verb, "write")) {
            const minrecv: usize = if (argv.len > 5)
                @max(std.fmt.parseInt(usize, argv[5], 10) catch 1, 1)
            else
                1;
            break :blk doWrite(name, count, size, minrecv);
        } else if (std.mem.eql(u8, verb, "read")) {
            break :blk doRead(name, count, size);
        } else {
            perr("unknown verb '{s}'", .{verb});
            break :blk 1;
        }
    };
    std.process.exit(code);
}
