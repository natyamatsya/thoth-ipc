// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Async receive demo: a device gateway multiplexing many routes on ONE thread
// (Zig port of rust/thoth-ipc/src/bin/demo_async_gateway.rs).
//
// Domain: supervisors, gateways and GUI apps cannot afford a blocking recv
// thread per channel. The Layer-1 notify readiness fd (transport/notify.zig)
// turns each route into a pollable fd, so one thread waits on every device at
// once with poll(2), alongside its own timers. Rust does the same with tokio;
// this port needs no runtime at all: open a receiver per device, open each
// one's readiness Sink, poll all fds together, and on a wake drain the sink and
// recv non-blocking on that route until it is empty.
//
// Usage (wire- and output-identical with the Rust port — mix languages):
//   demo_async_gateway gateway <devices> <readings>  the multiplexing loop
//   demo_async_gateway agent <id> <readings>         one device agent
//   demo_async_gateway clear <devices>               remove gw-dev-0 .. gw-dev-<devices-1>
//
// Device <id> sends on the route "gw-dev-<id>" the payloads
// `dev-<id> reading <n> temp <v>C` (no trailing NUL), v = 20 + id + n * 0.1.
// The gateway gives its whole run a 20 s deadline (stderr + exit 5).

const std = @import("std");
const channel = @import("transport/channel.zig");
const notify = @import("transport/notify.zig");
const ChanInner = channel.ChanInner;

const alloc = std.heap.c_allocator;

/// The whole gateway run must finish within this, or it exits 5.
const gateway_deadline_s = 20;
/// Period of the stats line (Rust: a 500 ms tokio interval).
const stats_period_ns: i128 = 500 * std.time.ns_per_ms;

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

fn chanName(buf: []u8, id: usize) []const u8 {
    return std.fmt.bufPrint(buf, "gw-dev-{d}", .{id}) catch unreachable;
}

/// A fake sensor reading; the payload format is the demo's, not the library's.
fn reading(buf: []u8, id: usize, n: usize) []const u8 {
    const value = 20.0 + @as(f64, @floatFromInt(id)) + @as(f64, @floatFromInt(n)) * 0.1;
    return std.fmt.bufPrint(buf, "dev-{d} reading {d} temp {d:.1}C", .{ id, n, value }) catch unreachable;
}

/// One device agent: an ordinary route sender in its own process. Every send
/// also posts the readiness signal that wakes the gateway's poll loop.
fn agent(id: usize, readings: usize) u8 {
    var nbuf: [32]u8 = undefined;
    var tx = ChanInner.open(alloc, "", chanName(&nbuf, id), .sender) catch return 3;
    defer tx.deinit();
    if (!tx.waitForRecv(1, deadline(10))) {
        err("[agent {d}] gateway never subscribed", .{id});
        return 1;
    }
    var n: usize = 0;
    while (n < readings) : (n += 1) {
        var mbuf: [96]u8 = undefined;
        if (!(tx.send(reading(&mbuf, id, n), deadline(5)) catch false)) {
            err("[agent {d}] send of reading {d} failed", .{ id, n });
            return 4;
        }
        channel.sleepNs((150 + (id % 3) * 70) * std.time.ns_per_ms);
    }
    return 0;
}

/// One device route on the gateway: its receiver, its readiness fd, and how
/// many of its readings are still due.
const Device = struct {
    name_buf: [32]u8 = undefined,
    rx: ChanInner,
    sink: notify.Sink,
    left: usize,

    /// The pollable readiness fd (a FIFO on Linux, a libnotify fd on macOS).
    fn fd(self: *const Device) c_int {
        return if (@hasField(notify.Sink, "rfd")) self.sink.rfd else self.sink.fd;
    }

    /// Non-blocking: take every reading already in the ring. Returns how many.
    fn drain(self: *Device) channel.Error!usize {
        var got: usize = 0;
        while (self.left > 0) {
            const buf = (try self.rx.recv(channel.nowNs())) orelse break;
            defer alloc.free(buf);
            out("[gateway] {s}", .{buf});
            self.left -= 1;
            got += 1;
        }
        return got;
    }
};

/// The gateway: one thread, one poll set over every device's readiness fd,
/// plus a stats timer sharing the same loop — exactly like the network I/O
/// would in a real bridge.
fn gateway(devices: usize, per_device: usize) u8 {
    const total = devices * per_device;
    const devs = alloc.alloc(Device, devices) catch return 3;
    defer alloc.free(devs);
    const pfds = alloc.alloc(std.c.pollfd, devices) catch return 3;
    defer alloc.free(pfds);

    var opened: usize = 0;
    defer for (devs[0..opened]) |*d| {
        d.sink.close();
        d.rx.deinit();
    };
    for (devs, 0..) |*d, id| {
        d.* = .{ .rx = undefined, .sink = undefined, .left = per_device };
        // ChanInner keeps the name slice: it lives in the Device itself.
        const name = chanName(&d.name_buf, id);
        d.rx = ChanInner.open(alloc, "", name, .receiver) catch |e| {
            err("[gateway] connect dev-{d} failed: {s}", .{ id, @errorName(e) });
            return 3;
        };
        d.sink = notify.Sink.open("", name, d.rx.conn_id);
        opened += 1;
    }

    var received: usize = 0;
    const end = deadline(gateway_deadline_s);
    var next_stats = channel.nowNs(); // the first tick fires at once, as tokio's
    while (true) {
        // Readings that landed before the sinks were open, or while we slept.
        for (devs) |*d| received += d.drain() catch return 5;

        const now = channel.nowNs();
        if (now >= end) {
            err("[gateway] timed out after {d}s: {d}/{d} readings", .{ gateway_deadline_s, received, total });
            return 5;
        }
        if (now >= next_stats) {
            out("[gateway] -- stats: {d}/{d} readings --", .{ received, total });
            if (received >= total) break;
            next_stats += stats_period_ns;
            continue;
        }

        // Park until a sender posts on any route, or the next timer is due.
        // Without a readiness fd (notify unavailable) poll just paces a recv sweep.
        var all_valid = true;
        for (devs, pfds) |*d, *p| {
            const live = d.left > 0 and d.sink.valid;
            if (d.left > 0 and !d.sink.valid) all_valid = false;
            p.* = .{ .fd = if (live) d.fd() else -1, .events = std.c.POLL.IN, .revents = 0 };
        }
        var wait_ns = @min(next_stats, end) - now;
        if (!all_valid) wait_ns = @min(wait_ns, 10 * std.time.ns_per_ms);
        const wait_ms: c_int = @intCast(@max(1, @divTrunc(wait_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        if (std.c.poll(pfds.ptr, @intCast(pfds.len), wait_ms) <= 0) continue;
        for (devs, pfds) |*d, p| {
            // Drain the sink BEFORE the recv sweep (top of the loop): a reading
            // pushed after the sweep then re-arms the fd, so no wake is lost.
            if (p.revents & std.c.POLL.IN != 0) d.sink.drain();
        }
    }
    out("[gateway] done: {d} readings from {d} devices on ONE thread.", .{ received, devices });
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
    const arg = struct {
        fn get(v: []const [:0]const u8, i: usize, default: usize) usize {
            if (i >= v.len) return default;
            return std.fmt.parseInt(usize, v[i], 10) catch default;
        }
    }.get;
    const role: []const u8 = if (argv.len > 1) argv[1] else "";

    if (std.mem.eql(u8, role, "gateway")) std.process.exit(gateway(arg(argv, 2, 4), arg(argv, 3, 10)));
    if (std.mem.eql(u8, role, "agent")) std.process.exit(agent(arg(argv, 2, 0), arg(argv, 3, 10)));
    if (std.mem.eql(u8, role, "clear")) {
        var id: usize = 0;
        while (id < arg(argv, 2, 4)) : (id += 1) {
            var nbuf: [32]u8 = undefined;
            channel.clearStorage("", chanName(&nbuf, id));
        }
        std.process.exit(0);
    }
    err("usage: demo_async_gateway <gateway|agent|clear> [args]", .{});
    std.process.exit(2);
}

test "readings format like Rust's {:.1}" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("dev-0 reading 0 temp 20.0C", reading(&buf, 0, 0));
    try std.testing.expectEqualStrings("dev-2 reading 7 temp 22.7C", reading(&buf, 2, 7));
    try std.testing.expectEqualStrings("dev-1 reading 13 temp 22.3C", reading(&buf, 1, 13));
}
