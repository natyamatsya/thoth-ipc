// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp/thoth-ipc/demo/chat and the Rust demo_chat: a multi-party chat
// over ONE multi-writer thoth::channel ("ipc-chat").
//
// Usage:
//   demo_chat                      interactive (run several in separate terminals)
//   demo_chat bot <lines> <peers>  scripted: wait for <peers> chatters (itself
//                                  included), send "cN> line-<i>" <lines> times
//                                  and exit once it has <lines> lines from every
//                                  other one
//   demo_chat clear                remove the channel and the id counter
//
// Each instance draws its id cN from a shared 8-byte atomic counter in the shm
// segment "__CHAT_ACC_STORAGE__" (C++ std::atomic<size_t>, Rust AtomicU64),
// then sends and receives on the channel at the same time. Type a message and
// press Enter to broadcast it; "q", an empty line or EOF quits. The wire format
// ("cN> text" plus a trailing NUL, "cN> q" to quit) is byte-exact with the C++,
// Rust and Swift ports, so chatters can be any mix of languages.

const std = @import("std");
const channel = @import("transport/channel.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;
const ShmHandle = @import("platform/shm.zig").ShmHandle;

const alloc = std.heap.c_allocator;
const channel_name = "ipc-chat";
const acc_storage = "__CHAT_ACC_STORAGE__";
const quit = "q";

fn deadline(ms: i128) i128 {
    return channel.nowNs() + ms * std.time.ns_per_ms;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4352]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// The id counter: the handle must stay mapped while the chatter runs, or the
/// segment is unlinked and the next instance restarts numbering at 0.
const IdCounter = struct {
    shm: ShmHandle,
    id: u64,

    fn acquire() ?IdCounter {
        const shm = ShmHandle.acquire(acc_storage, @sizeOf(u64), .create_or_open) catch return null;
        const counter: *u64 = @ptrCast(@alignCast(shm.ptr()));
        return .{ .shm = shm, .id = @atomicRmw(u64, counter, .Add, 1, .monotonic) };
    }
};

/// A received payload with the other ports' trailing NUL stripped.
fn text(raw: []const u8) []const u8 {
    return if (raw.len > 0 and raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
}

/// "cN> msg" -> { "cN", "msg" }, or null for anything else.
fn parse(msg: []const u8) ?struct { from: []const u8, body: []const u8 } {
    const sep = std.mem.indexOf(u8, msg, "> ") orelse return null;
    return .{ .from = msg[0..sep], .body = msg[sep + 2 ..] };
}

/// Send "<id>> <body>" with the trailing NUL the C++ receivers expect.
fn sendLine(ch: *ChannelInner, id: []const u8, body: []const u8) bool {
    var buf: [4160]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}> {s}", .{ id, body }) catch return false;
    if (s.len >= buf.len) return false;
    buf[s.len] = 0;
    return ch.send(buf[0 .. s.len + 1], deadline(2000)) catch false;
}

// --- Interactive mode -------------------------------------------------------

/// Buffered line reader over stdin (fd 0), no std.Io dependency.
const LineReader = struct {
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// The next line without its '\n', or null at EOF with nothing pending.
    fn next(self: *LineReader) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], '\n')) |i| {
                const line = self.buf[self.start .. self.start + i];
                self.start += i + 1;
                return line;
            }
            if (self.start > 0) { // compact the partial line to the front
                std.mem.copyForwards(u8, &self.buf, self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            }
            if (self.end == self.buf.len) { // over-long line: hand it out as is
                self.start = self.end;
                return self.buf[0..self.end];
            }
            const n = std.c.read(0, self.buf[self.end..].ptr, self.buf.len - self.end);
            if (n <= 0) {
                if (self.end == 0) return null;
                self.start = self.end;
                return self.buf[0..self.end];
            }
            self.end += @intCast(n);
        }
    }
};

const RecvCtx = struct {
    ch: *ChannelInner,
    id: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
};

/// Print every foreign message until our own quit marker comes back (or the
/// main thread gives up on it and sets `stop`).
fn recvLoop(ctx: *RecvCtx) void {
    out("{s} is ready.", .{ctx.id});
    while (!ctx.stop.load(.acquire)) {
        const raw = (ctx.ch.recv(deadline(200)) catch break) orelse continue;
        defer alloc.free(raw);
        const msg = text(raw);
        if (parse(msg)) |m| {
            if (std.mem.eql(u8, m.from, ctx.id)) {
                if (std.mem.eql(u8, m.body, quit)) break;
                continue; // skip own messages
            }
        }
        out("{s}", .{msg});
    }
    out("{s} receiver is quit...", .{ctx.id});
}

fn interactive() u8 {
    var counter = IdCounter.acquire() orelse {
        err("shm acquire failed", .{});
        return 3;
    };
    defer counter.shm.release();
    var idbuf: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idbuf, "c{d}", .{counter.id}) catch unreachable;

    var sender = ChannelInner.open(alloc, "", channel_name, .sender) catch {
        err("{s}: connect failed", .{id});
        return 3;
    };
    defer sender.deinit();
    var receiver = ChannelInner.open(alloc, "", channel_name, .receiver) catch {
        err("{s}: connect failed", .{id});
        return 3;
    };
    defer receiver.deinit();

    var ctx = RecvCtx{ .ch = &receiver, .id = id };
    const thread = std.Thread.spawn(.{}, recvLoop, .{&ctx}) catch {
        err("{s}: cannot spawn the receive thread", .{id});
        return 3;
    };

    var lines = LineReader{};
    while (true) {
        _ = std.c.write(1, "> ", 2);
        const line = std.mem.trim(u8, lines.next() orelse break, " \t\r\n");
        if (line.len == 0 or std.mem.eql(u8, line, quit)) break;
        _ = sendLine(&sender, id, line);
    }

    // The quit marker lets the receive thread drain and exit; without it
    // (send failed), stop it directly.
    if (!sendLine(&sender, id, quit)) ctx.stop.store(true, .release);
    thread.join();
    out("{s} sender is quit...", .{id});
    return 0;
}

// --- Scripted bot mode ------------------------------------------------------

/// Rendezvous with `peers` receivers, send `lines` lines, then read until
/// every other chatter's `lines` lines have arrived.
fn bot(lines: usize, peers: usize) u8 {
    var counter = IdCounter.acquire() orelse {
        err("shm acquire failed", .{});
        return 3;
    };
    defer counter.shm.release();
    var idbuf: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&idbuf, "c{d}", .{counter.id}) catch unreachable;

    var sender = ChannelInner.open(alloc, "", channel_name, .sender) catch {
        err("{s}: connect failed", .{id});
        return 3;
    };
    defer sender.deinit();
    var receiver = ChannelInner.open(alloc, "", channel_name, .receiver) catch {
        err("{s}: connect failed", .{id});
        return 3;
    };
    defer receiver.deinit();
    out("{s} is ready.", .{id});

    if (!sender.waitForRecv(peers, deadline(10_000))) {
        err("{s}: {d} chatters did not show up within 10s", .{ id, peers });
        return 2;
    }
    var i: usize = 0;
    while (i < lines) : (i += 1) {
        var lbuf: [32]u8 = undefined;
        if (!sendLine(&sender, id, std.fmt.bufPrint(&lbuf, "line-{d}", .{i}) catch unreachable)) {
            err("{s}: send failed", .{id});
            return 4;
        }
    }

    var got = std.StringHashMap(usize).init(alloc); // foreign id -> lines
    defer {
        var it = got.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        got.deinit();
    }
    var done: usize = 0; // foreign ids with all `lines` lines
    while (lines > 0 and done + 1 < peers) {
        const raw = (receiver.recv(deadline(10_000)) catch null) orelse {
            err("{s}: timed out waiting for chat lines", .{id});
            return 5;
        };
        defer alloc.free(raw);
        const msg = text(raw);
        if (parse(msg)) |m| {
            if (std.mem.eql(u8, m.from, id) or std.mem.eql(u8, m.body, quit)) continue;
            const gop = got.getOrPut(m.from) catch return 5;
            if (!gop.found_existing) {
                gop.key_ptr.* = alloc.dupe(u8, m.from) catch return 5;
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* == lines) done += 1;
        }
        out("{s}", .{msg});
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

    if (argv.len < 2) std.process.exit(interactive());
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "bot")) {
        const lines = std.fmt.parseInt(usize, argv[2], 10) catch 0;
        std.process.exit(bot(lines, std.fmt.parseInt(usize, argv[3], 10) catch 0));
    }
    if (std.mem.eql(u8, argv[1], "clear")) {
        channel.clearStorage("", channel_name);
        ShmHandle.clearStorage(acc_storage);
        std.process.exit(0);
    }
    err("usage:\n  demo_chat\n  demo_chat bot <lines> <peers>\n  demo_chat clear", .{});
    std.process.exit(1);
}

test "parse splits the sender id from the body" {
    const m = parse("c12> hello > world").?;
    try std.testing.expectEqualStrings("c12", m.from);
    try std.testing.expectEqualStrings("hello > world", m.body);
    try std.testing.expect(parse("no separator") == null);
    try std.testing.expectEqualStrings("c0> q", text("c0> q\x00"));
}
