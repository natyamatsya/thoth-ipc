// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
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
const notify = @import("transport/notify.zig");
const ChannelInner = @import("transport/channel_multi.zig").ChannelInner;
const Mutex = @import("sync/mutex.zig").Mutex;
const Condition = @import("sync/condition.zig").Condition;
const Semaphore = @import("sync/semaphore.zig").Semaphore;
const secure = @import("secure/secure.zig");

const ChanInner = channel.ChanInner;
const alloc = std.heap.c_allocator;

/// Format one of the derived sync-object names (`<name>_m` / `_s` / `_c`).
fn derived(buf: []u8, name: []const u8, suffix: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}_{c}", .{ name, suffix }) catch unreachable;
}

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

// --- Typed codec verbs (scenario: typed) -----------------------------------
// The typed layer is a thin codec wrapper over the route (no extra on-wire
// framing): the message is a hand-rolled protobuf record — field 1 (0x08) varint
// `seq`, field 2 (0x12) length-delimited `payload` — byte-identical across ports,
// so no protobuf library is needed.

fn varintLen(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

fn putVarint(buf: []u8, i: *usize, v: u64) void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) {
        buf[i.*] = @as(u8, @intCast(x & 0x7F)) | 0x80;
        i.* += 1;
    }
    buf[i.*] = @intCast(x);
    i.* += 1;
}

fn getVarint(bytes: []const u8, pos: *usize) ?u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < bytes.len) {
        const b = bytes[pos.*];
        pos.* += 1;
        v |= @as(u64, b & 0x7F) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 63) return null;
        shift += 7;
    }
    return null;
}

fn encodeMsg(seq: u32, payload: []const u8) ![]u8 {
    const total = 1 + varintLen(seq) + 1 + varintLen(payload.len) + payload.len;
    const buf = try alloc.alloc(u8, total);
    var i: usize = 0;
    buf[i] = 0x08;
    i += 1;
    putVarint(buf, &i, seq);
    buf[i] = 0x12;
    i += 1;
    putVarint(buf, &i, payload.len);
    @memcpy(buf[i .. i + payload.len], payload);
    return buf;
}

const Decoded = struct { seq: u32, payload: []const u8 };

fn decodeMsg(bytes: []const u8) ?Decoded {
    var pos: usize = 0;
    if (bytes.len == 0 or bytes[0] != 0x08) return null;
    pos = 1;
    const seq64 = getVarint(bytes, &pos) orelse return null;
    if (seq64 > std.math.maxInt(u32)) return null;
    if (pos >= bytes.len or bytes[pos] != 0x12) return null;
    pos += 1;
    const len = getVarint(bytes, &pos) orelse return null;
    if (bytes.len - pos != len) return null;
    return .{ .seq = @intCast(seq64), .payload = bytes[pos..] };
}

fn doTwrite(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChanInner.open(alloc, "", name, .sender) catch {
        perr("[zig-typed] connect(sender) failed", .{});
        return 3;
    };
    defer ch.deinit();
    if (!ch.waitForRecv(1, deadline(5))) {
        perr("[zig-typed] no receiver within 5s", .{});
        return 2;
    }
    const payload = alloc.alloc(u8, size) catch return 4;
    defer alloc.free(payload);
    fillPattern(payload);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const enc = encodeMsg(@intCast(i), payload) catch return 4;
        defer alloc.free(enc);
        if (!(ch.send(enc, deadline(8)) catch false)) {
            perr("[zig-typed] send {d} failed", .{i});
            return 4;
        }
    }
    perr("[zig-typed] wrote {d} x {d}B typed on '{s}'", .{ count, size, name });
    return 0;
}

fn doTread(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig-typed] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();
    const want = alloc.alloc(u8, size) catch return 5;
    defer alloc.free(want);
    fillPattern(want);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const got = (ch.recv(deadline(8)) catch {
            perr("[zig-typed] recv {d} error", .{i});
            return 5;
        }) orelse {
            perr("[zig-typed] recv {d} timed out", .{i});
            return 5;
        };
        defer alloc.free(got);
        const dec = decodeMsg(got) orelse {
            perr("[zig-typed] recv {d} undecodable", .{i});
            return 8;
        };
        if (dec.seq != i) {
            perr("[zig-typed] recv {d} wrong seq {d}", .{ i, dec.seq });
            return 6;
        }
        if (!std.mem.eql(u8, dec.payload, want)) {
            perr("[zig-typed] recv {d} payload mismatch", .{i});
            return 7;
        }
    }
    perr("[zig-typed] read {d} x {d}B typed on '{s}' OK", .{ count, size, name });
    return 0;
}

// --- Secure verbs (scenario: secure / secure-badkey / secure-negative) -----
// AEAD envelope v1 over a raw (identity) inner codec, so the pairing proves
// envelope framing + AEAD interop only. swrite seals with the shared xlang test
// key; the sread variants prove fail-closed behaviour on tamper, wrong key
// material, wrong key id and algorithm mismatch.

fn doSwrite(name: []const u8, count: usize, size: usize, tamper: bool, alg: secure.Alg) u8 {
    var ch = ChanInner.open(alloc, "", name, .sender) catch {
        perr("[zig-secure] connect(sender) failed", .{});
        return 3;
    };
    defer ch.deinit();
    if (!ch.waitForRecv(1, deadline(5))) {
        perr("[zig-secure] no receiver within 5s", .{});
        return 2;
    }
    const plain = alloc.alloc(u8, size) catch return 9;
    defer alloc.free(plain);
    fillPattern(plain);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const env = secure.sealMessage(alloc, alg, secure.test_key, plain) catch {
            perr("[zig-secure] seal {d} failed", .{i});
            return 9;
        };
        defer alloc.free(env);
        if (tamper) env[env.len - 1] ^= 0x7F; // flip a tag bit → open must fail
        if (!(ch.send(env, deadline(8)) catch false)) {
            perr("[zig-secure] send {d} failed", .{i});
            return 4;
        }
    }
    perr("[zig-secure] wrote {d} x {d}B sealed on '{s}'", .{ count, size, name });
    return 0;
}

fn doSread(name: []const u8, count: usize, size: usize, key: secure.Key, expect_open: bool, alg: secure.Alg) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig-secure] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();
    const want = alloc.alloc(u8, size) catch return 5;
    defer alloc.free(want);
    fillPattern(want);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const got = (ch.recv(deadline(8)) catch {
            perr("[zig-secure] recv {d} error", .{i});
            return 5;
        }) orelse {
            perr("[zig-secure] recv {d} timed out", .{i});
            return 5;
        };
        defer alloc.free(got);
        if (std.mem.eql(u8, got, want)) {
            perr("[zig-secure] recv {d} arrived as plaintext", .{i});
            return 10;
        }
        const opened = secure.openMessage(alloc, alg, key, got);
        if (!expect_open) {
            if (opened) |p| {
                alloc.free(p);
                perr("[zig-secure] recv {d} opened under the WRONG key", .{i});
                return 11;
            }
            continue;
        }
        const p = opened orelse {
            perr("[zig-secure] recv {d} open failed", .{i});
            return 8;
        };
        defer alloc.free(p);
        if (p.len != size) {
            perr("[zig-secure] recv {d} wrong size: got {d} want {d}", .{ i, p.len, size });
            return 6;
        }
        if (!std.mem.eql(u8, p, want)) {
            perr("[zig-secure] recv {d} plaintext mismatch", .{i});
            return 7;
        }
    }
    perr("[zig-secure] {s} {d} x {d}B on '{s}' OK", .{ if (expect_open) "opened" else "rejected", count, size, name });
    return 0;
}

fn runSecure(verb: []const u8, name: []const u8, count: usize, size: usize, alg_str: []const u8) u8 {
    const alg = secure.Alg.fromStr(alg_str) orelse {
        perr("[zig-secure] unknown algorithm '{s}'", .{alg_str});
        return 1;
    };
    if (std.mem.eql(u8, verb, "swrite")) return doSwrite(name, count, size, false, alg);
    if (std.mem.eql(u8, verb, "swrite-tamper")) return doSwrite(name, count, size, true, alg);
    if (std.mem.eql(u8, verb, "sread")) return doSread(name, count, size, secure.test_key, true, alg);
    if (std.mem.eql(u8, verb, "sread-reject")) return doSread(name, count, size, secure.test_key, false, alg);
    if (std.mem.eql(u8, verb, "sread-badkey")) return doSread(name, count, size, secure.wrong_key, false, alg);
    if (std.mem.eql(u8, verb, "sread-badkeyid")) return doSread(name, count, size, secure.wrong_id_key, false, alg);
    return 1;
}

fn isSecureVerb(verb: []const u8) bool {
    const verbs = [_][]const u8{ "swrite", "swrite-tamper", "sread", "sread-reject", "sread-badkey", "sread-badkeyid" };
    for (verbs) |v| if (std.mem.eql(u8, verb, v)) return true;
    return false;
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

// --- Sync-primitive verbs (scenario: primitives) ---------------------------
// Derived objects: mutex <name>_m, semaphore <name>_s, condition <name>_c.

fn openMutex(name: []const u8) ?Mutex {
    var mbuf: [256]u8 = undefined;
    return Mutex.open(derived(&mbuf, name, 'm')) catch {
        perr("[zig-prim] open mutex failed", .{});
        return null;
    };
}
fn openCondition(name: []const u8) ?Condition {
    var cbuf: [256]u8 = undefined;
    return Condition.open(derived(&cbuf, name, 'c')) catch {
        perr("[zig-prim] open condition failed", .{});
        return null;
    };
}
fn openSemaphore(name: []const u8) ?Semaphore {
    var sbuf: [256]u8 = undefined;
    // Semaphore.open appends its own "_s", matching the Rust/Swift ports.
    return Semaphore.open(derived(&sbuf, name, 's'), 0) catch {
        perr("[zig-prim] open semaphore failed", .{});
        return null;
    };
}

/// Lock the mutex and hold it (READY once held) so a peer can probe contention
/// or, after SIGKILL, robust dead-holder recovery.
fn doMhold(name: []const u8, secs: u64) u8 {
    var m = openMutex(name) orelse return 3;
    // No deinit: a `mhold` process is often SIGKILLed, and even on clean exit we
    // must not unlink the segment out from under a concurrent prober.
    m.lock();
    pout("READY", .{});
    channel.sleepNs(secs * std.time.ns_per_s);
    m.unlock();
    return 0;
}

fn doMtry(name: []const u8) u8 {
    var m = openMutex(name) orelse return 3;
    defer m.deinit();
    if (m.tryLock()) {
        m.unlock();
        pout("acquired", .{});
    } else {
        pout("busy", .{});
    }
    return 0;
}

fn doMlock(name: []const u8, ms: u64) u8 {
    var m = openMutex(name) orelse return 3;
    defer m.deinit();
    if (m.lockTimeout(@as(i128, ms) * std.time.ns_per_ms)) {
        m.unlock();
        pout("acquired", .{});
    } else {
        pout("timeout", .{});
    }
    return 0;
}

fn doSpost(name: []const u8, n: u32) u8 {
    var s = openSemaphore(name) orelse return 3;
    defer s.deinit();
    s.post(n);
    perr("[zig-prim] posted {d} on '{s}_s'", .{ n, name });
    return 0;
}

/// Wait for exactly `n` posts within the timeout, then verify no surplus token.
fn doSwait(name: []const u8, n: u32, ms: u64) u8 {
    var s = openSemaphore(name) orelse return 3;
    defer s.deinit();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!s.waitTimeout(@as(i128, ms) * std.time.ns_per_ms)) {
            perr("[zig-prim] sem wait {d} timed out", .{i});
            return 5;
        }
    }
    if (s.waitTimeout(500 * std.time.ns_per_ms)) {
        perr("[zig-prim] sem had a surplus token after {d} waits", .{n});
        return 6;
    }
    perr("[zig-prim] waited {d} posts on '{s}_s' OK", .{ n, name });
    return 0;
}

fn doCvwait(name: []const u8, ms: u64) u8 {
    var m = openMutex(name) orelse return 3;
    defer m.deinit();
    var c = openCondition(name) orelse return 3;
    defer c.deinit();
    m.lock();
    const woke = c.wait(&m, @as(i128, ms) * std.time.ns_per_ms);
    m.unlock();
    if (woke) {
        perr("[zig-prim] condition woke on '{s}_c'", .{name});
        return 0;
    }
    perr("[zig-prim] condition wait timed out", .{});
    return 5;
}

/// Broadcast repeatedly (looping avoids a notify-before-wait race).
fn doCvnotify(name: []const u8) u8 {
    var m = openMutex(name) orelse return 3;
    defer m.deinit();
    var c = openCondition(name) orelse return 3;
    defer c.deinit();
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        m.lock();
        c.broadcast();
        m.unlock();
        channel.sleepNs(100 * std.time.ns_per_ms);
    }
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

/// Async receive (scenario: async): wait on the Layer-1 readiness fd, woken by
/// any language's sender posting the notify, then drain the ring. Proves the
/// notify key is byte-exact — a C++/Rust/Swift `write` wakes this receiver.
fn doAread(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChanInner.open(alloc, "", name, .receiver) catch {
        perr("[zig-async] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();
    var sink = notify.Sink.open("", name);
    defer sink.close();

    const want = alloc.alloc(u8, size) catch return 5;
    defer alloc.free(want);
    fillPattern(want);

    const overall = deadline(20);
    var i: usize = 0;
    while (i < count) {
        // Greedily drain whatever is already in the ring (non-blocking recv).
        if (ch.recv(channel.nowNs()) catch return 5) |got| {
            defer alloc.free(got);
            if (got.len != size) {
                perr("[zig-async] recv {d} wrong size {d}", .{ i, got.len });
                return 6;
            }
            if (!std.mem.eql(u8, got, want)) {
                perr("[zig-async] recv {d} mismatch", .{i});
                return 7;
            }
            i += 1;
            continue;
        }
        // Nothing ready — park on the readiness fd until a sender posts.
        const rem_ns = overall - channel.nowNs();
        if (rem_ns <= 0) {
            perr("[zig-async] recv {d} timed out", .{i});
            return 5;
        }
        if (!sink.valid) {
            // Notify unavailable: fall back to a blocking (busy-poll) recv.
            const got = (ch.recv(deadline(8)) catch return 5) orelse return 5;
            defer alloc.free(got);
            if (got.len != size) return 6;
            if (!std.mem.eql(u8, got, want)) return 7;
            i += 1;
            continue;
        }
        const rem_ms: i32 = @intCast(@min(@divTrunc(rem_ns, std.time.ns_per_ms), std.math.maxInt(i32)));
        if (!sink.wait(rem_ms)) {
            perr("[zig-async] recv {d} timed out on readiness fd", .{i});
            return 5;
        }
        sink.drain();
    }
    perr("[zig-async] read {d} x {d}B async on '{s}' OK", .{ count, size, name });
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

// --- Multi-writer channel verbs (scenario: channel) ------------------------
// ipc::channel (N writers, N readers). Same msg framing as route over a
// multi-producer commit ring; the runner pairs two writers of (possibly
// different) languages into one reader, which expects 2*count messages.

fn doCwrite(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChannelInner.open(alloc, "", name, .sender) catch {
        perr("[zig-chan] connect(sender) failed", .{});
        return 3;
    };
    defer ch.deinit();
    if (!ch.waitForRecv(1, deadline(5))) {
        perr("[zig-chan] no receiver within 5s", .{});
        return 2;
    }
    const msg = alloc.alloc(u8, size) catch return 4;
    defer alloc.free(msg);
    fillPattern(msg);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ok = ch.send(msg, deadline(8)) catch false;
        if (!ok) {
            perr("[zig-chan] send {d} failed", .{i});
            return 4;
        }
    }
    perr("[zig-chan] wrote {d} x {d}B on '{s}'", .{ count, size, name });
    return 0;
}

fn doCread(name: []const u8, count: usize, size: usize) u8 {
    var ch = ChannelInner.open(alloc, "", name, .receiver) catch {
        perr("[zig-chan] connect(receiver) failed", .{});
        return 3;
    };
    defer ch.deinit();
    const want = alloc.alloc(u8, size) catch return 5;
    defer alloc.free(want);
    fillPattern(want);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const got = (ch.recv(deadline(8)) catch {
            perr("[zig-chan] recv {d} error", .{i});
            return 5;
        }) orelse {
            perr("[zig-chan] recv {d} timed out", .{i});
            return 5;
        };
        defer alloc.free(got);
        if (got.len != size) {
            perr("[zig-chan] recv {d} wrong size: got {d} want {d}", .{ i, got.len, size });
            return 6;
        }
        if (!std.mem.eql(u8, got, want)) {
            perr("[zig-chan] recv {d} payload mismatch", .{i});
            return 7;
        }
    }
    perr("[zig-chan] read {d} x {d}B on '{s}' OK", .{ count, size, name });
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
        // Clear the ring plus the derived primitive objects (mutex <name>_m,
        // semaphore <name>_s, condition <name>_c).
        channel.clearStorage("", name);
        var b: [256]u8 = undefined;
        Mutex.clearStorage(derived(&b, name, 'm'));
        Semaphore.clearStorage(derived(&b, name, 's'));
        Condition.clearStorage(derived(&b, name, 'c'));
        std.process.exit(0);
    }
    if (std.mem.eql(u8, verb, "caps")) {
        // Advertised capabilities: sync-primitive verbs ("prim"), the typed
        // protobuf codec, the AEAD secure envelope (pure Zig std.crypto), and the
        // Layer-1 notify/async readiness. All always available on macOS, so the
        // runner joins every scenario except multi-writer channel.
        const caps = "prim typed:protobuf notify async secure secure:aes256gcm secure:chacha20poly1305\n";
        _ = std.c.write(1, caps, caps.len);
        std.process.exit(0);
    }

    // Reaper verbs (scenario: reap) — hold takes an optional seconds arg.
    if (std.mem.eql(u8, verb, "hold")) {
        const secs: u64 = if (argv.len > 3) (std.fmt.parseInt(u64, argv[3], 10) catch 30) else 30;
        std.process.exit(doHold(name, secs));
    }
    if (std.mem.eql(u8, verb, "probe")) std.process.exit(doProbe(name));
    if (std.mem.eql(u8, verb, "count")) std.process.exit(doCount(name));

    // Sync-primitive verbs (scenario: primitives).
    if (std.mem.eql(u8, verb, "mhold")) {
        const secs: u64 = if (argv.len > 3) (std.fmt.parseInt(u64, argv[3], 10) catch 20) else 20;
        std.process.exit(doMhold(name, secs));
    }
    if (std.mem.eql(u8, verb, "mtry")) std.process.exit(doMtry(name));
    if (std.mem.eql(u8, verb, "mlock")) {
        const ms: u64 = if (argv.len > 3) (std.fmt.parseInt(u64, argv[3], 10) catch 5000) else 5000;
        std.process.exit(doMlock(name, ms));
    }
    if (std.mem.eql(u8, verb, "spost")) {
        const n: u32 = if (argv.len > 3) (std.fmt.parseInt(u32, argv[3], 10) catch 1) else 1;
        std.process.exit(doSpost(name, n));
    }
    if (std.mem.eql(u8, verb, "swait")) {
        const n: u32 = if (argv.len > 3) (std.fmt.parseInt(u32, argv[3], 10) catch 1) else 1;
        const ms: u64 = if (argv.len > 4) (std.fmt.parseInt(u64, argv[4], 10) catch 8000) else 8000;
        std.process.exit(doSwait(name, n, ms));
    }
    if (std.mem.eql(u8, verb, "cvwait")) {
        const ms: u64 = if (argv.len > 3) (std.fmt.parseInt(u64, argv[3], 10) catch 8000) else 8000;
        std.process.exit(doCvwait(name, ms));
    }
    if (std.mem.eql(u8, verb, "cvnotify")) std.process.exit(doCvnotify(name));

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
        } else if (std.mem.eql(u8, verb, "aread")) {
            break :blk doAread(name, count, size);
        } else if (std.mem.eql(u8, verb, "twrite")) {
            break :blk doTwrite(name, count, size);
        } else if (std.mem.eql(u8, verb, "tread")) {
            break :blk doTread(name, count, size);
        } else if (std.mem.eql(u8, verb, "cwrite")) {
            break :blk doCwrite(name, count, size);
        } else if (std.mem.eql(u8, verb, "cread")) {
            break :blk doCread(name, count, size);
        } else if (isSecureVerb(verb)) {
            const alg_str = if (argv.len > 5) argv[5] else "aes256gcm";
            break :blk runSecure(verb, name, count, size, alg_str);
        } else {
            perr("unknown verb '{s}'", .{verb});
            break :blk 1;
        }
    };
    std.process.exit(code);
}
