// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language bounded buffer — the classic producer/consumer problem solved
// with the byte-exact named IPC primitives.
//
// Usage (run the consumer first, then one or more producers):
//   demo_bounded_buffer consume <total>
//   demo_bounded_buffer produce <id> <count>
//
// A fixed-capacity ring lives in a shared-memory segment; access is coordinated
// by a named Mutex (so multiple producers can contend for `head`) and two
// counting Semaphores — `empty` (free slots, starts at CAP) and `full` (filled
// slots, starts at 0). Producers and the consumer can be *different languages*:
// the shm layout, the mutex and both semaphores are byte-exact across the C++,
// Rust, Swift and Zig ports.

const std = @import("std");
const ShmHandle = @import("platform/shm.zig").ShmHandle;
const Mutex = @import("sync/mutex.zig").Mutex;
const Semaphore = @import("sync/semaphore.zig").Semaphore;

const alloc = std.heap.c_allocator;

const SHM = "__BBUF__";
const MUTEX = "bbuf_m";
const EMPTY = "bbuf_e";
const FULL = "bbuf_f";
const CAP: u32 = 4;
const SLOT: usize = 48;
const SHM_SIZE: usize = 8 + CAP * SLOT;
const TMO: i128 = 10 * std.time.ns_per_s;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

const Ring = struct {
    shm: ShmHandle,
    fn open() !Ring {
        var shm = try ShmHandle.acquire(SHM, SHM_SIZE, .create_or_open);
        if (shm.refCount() <= 1) { // first opener zeroes the cursors
            headPtr(&shm).* = 0;
            tailPtr(&shm).* = 0;
        }
        return .{ .shm = shm };
    }
    fn headPtr(shm: *ShmHandle) *volatile u32 {
        return @ptrCast(@alignCast(shm.ptr()));
    }
    fn tailPtr(shm: *ShmHandle) *volatile u32 {
        return @ptrCast(@alignCast(shm.ptr() + 4));
    }
    fn slot(self: *Ring, idx: u32) [*]u8 {
        return self.shm.ptr() + 8 + idx * SLOT;
    }
    fn head(self: *Ring) u32 {
        return headPtr(&self.shm).*;
    }
    fn tail(self: *Ring) u32 {
        return tailPtr(&self.shm).*;
    }
    fn setHead(self: *Ring, v: u32) void {
        headPtr(&self.shm).* = v;
    }
    fn setTail(self: *Ring, v: u32) void {
        tailPtr(&self.shm).* = v;
    }
};

fn produce(id: []const u8, count: usize) u8 {
    var ring = Ring.open() catch return 3;
    defer ring.shm.release();
    var mtx = Mutex.open(MUTEX) catch return 3;
    defer mtx.deinit();
    var empty = Semaphore.open(EMPTY, CAP) catch return 3;
    defer empty.deinit();
    var full = Semaphore.open(FULL, 0) catch return 3;
    defer full.deinit();

    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (!empty.waitTimeout(TMO)) {
            err("[producer {s}] no free slot within 10s", .{id});
            return 2;
        }
        mtx.lock();
        const idx = ring.head();
        ring.setHead((idx + 1) % CAP);
        var mbuf: [SLOT]u8 = undefined;
        const body = std.fmt.bufPrint(&mbuf, "{s} #{d}", .{ id, k }) catch mbuf[0..0];
        const dst = ring.slot(idx);
        @memcpy(dst[0..body.len], body);
        dst[body.len] = 0;
        mtx.unlock();
        full.post(1);
    }
    err("[producer {s}] produced {d} items", .{ id, count });
    return 0;
}

fn consume(total: usize) u8 {
    var ring = Ring.open() catch return 3;
    defer ring.shm.release();
    var mtx = Mutex.open(MUTEX) catch return 3;
    defer mtx.deinit();
    var empty = Semaphore.open(EMPTY, CAP) catch return 3;
    defer empty.deinit();
    var full = Semaphore.open(FULL, 0) catch return 3;
    defer full.deinit();
    out("[consumer] ready — draining {d} items through a {d}-slot ring", .{ total, CAP });

    var tally = std.StringHashMap(usize).init(alloc);
    var done: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        if (!full.waitTimeout(TMO)) {
            err("[consumer] no item within 10s after {d}/{d}", .{ i, total });
            break;
        }
        mtx.lock();
        const idx = ring.tail();
        ring.setTail((idx + 1) % CAP);
        const p = ring.slot(idx);
        const len = std.mem.indexOfScalar(u8, p[0..SLOT], 0) orelse SLOT;
        var mbuf: [SLOT]u8 = undefined;
        @memcpy(mbuf[0..len], p[0..len]);
        mtx.unlock();
        empty.post(1);
        const msg = mbuf[0..len];
        const producer = msg[0 .. std.mem.indexOfScalar(u8, msg, ' ') orelse msg.len];
        const gop = tally.getOrPut(producer) catch return 5;
        if (!gop.found_existing) {
            gop.key_ptr.* = alloc.dupe(u8, producer) catch return 5;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        done += 1;
        out("[consumer] {d}/{d}  {s}", .{ i + 1, total, msg });
    }

    out("\n[consumer] summary — {d} items from {d} producer(s):", .{ done, tally.count() });
    var it = tally.iterator();
    while (it.next()) |e| out("    {s}  {d}", .{ e.key_ptr.*, e.value_ptr.* });
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
    const parse = struct {
        fn n(s: []const u8) usize {
            return std.fmt.parseInt(usize, s, 10) catch 0;
        }
    }.n;

    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "consume"))
        std.process.exit(consume(parse(argv[2])));
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "produce"))
        std.process.exit(produce(argv[2], parse(argv[3])));
    err("usage:\n  demo_bounded_buffer consume <total>\n  demo_bounded_buffer produce <id> <count>", .{});
    std.process.exit(1);
}
