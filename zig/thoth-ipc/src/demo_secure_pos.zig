// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Secure codec demo: a point-of-sale card pipeline (Zig endpoint).
//
// Domain: PCI-DSS P2PE mandates that cardholder data is encrypted at the point
// of capture and that intermediary software (the merchant's POS app) is
// cryptographically unable to read it. On a BROADCAST route every receiver sees
// every message, so application-layer AEAD is the only way to separate
// privileges on a shared bus: the pinpad seals each card event, the POS app sees
// only opaque envelopes (fail-closed), and only the payment gateway holds the key.
//
// Roles are wire-identical with the C++ and Rust counterparts
// (cpp/thoth-ipc/demo/secure_pos, rust/thoth-ipc/src/bin/demo_secure_pos.rs) —
// mix languages freely:
//   demo_secure_pos gateway [count]    payment gateway: opens sealed events
//   demo_secure_pos pos     [count]    merchant POS: has NO key, must reject
//   demo_secure_pos pinpad  [count]    card reader: seals + broadcasts events
//
// Start the receivers first; the pinpad waits for both. The AEAD is Zig's
// std.crypto AES-256-GCM in a SIPC v1 envelope (secure/secure.zig), byte-exact
// with the OpenSSL-backed ports.
//
// DEMO KEY ONLY: real deployments provision the key into the pinpad's secure
// element and the gateway's HSM/KMS — it never appears in source.

const std = @import("std");
const channel = @import("transport/channel.zig");
const secure = @import("secure/secure.zig");
const ChanInner = channel.ChanInner;

const alloc = std.heap.c_allocator;
const bus_name = "pos-bus";

/// Payment-processor key (DEMO ONLY — see header).
const processor_key = secure.Key{
    .id = 0x504F5301, // "POS",1
    .bytes = .{
        0x8f, 0x3a, 0x11, 0xc4, 0x5e, 0x92, 0x07, 0x6b, 0xd0, 0x24, 0xa9,
        0x71, 0x3c, 0xe8, 0x55, 0x1f, 0x60, 0xbb, 0x2d, 0x94, 0x48, 0x0e,
        0xf3, 0x87, 0x19, 0xc2, 0x6d, 0xaa, 0x35, 0x7e, 0x01, 0xd8,
    },
};

/// What the merchant POS app holds: not the processor key. Same key id (it
/// knows WHICH key sealed the event) but no key material — every open must
/// fail closed.
const merchant_no_key = secure.Key{ .id = processor_key.id, .bytes = @splat(0) };

/// One card capture. Canonical protobuf wire (field 1 bytes pan, field 2
/// varint amount_cents, field 3 varint seq) — byte-identical with C++ and Rust.
const CardEvent = struct {
    pan: []const u8,
    amount_cents: u64,
    seq: u32,

    fn putVarint(list: *std.ArrayList(u8), value: u64) !void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) try list.append(alloc, @as(u8, @truncate(v)) | 0x80);
        try list.append(alloc, @truncate(v));
    }

    /// The serialized message; caller owns it.
    fn encode(self: CardEvent) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(alloc);
        try list.append(alloc, 0x0A); // field 1, length-delimited
        try putVarint(&list, self.pan.len);
        try list.appendSlice(alloc, self.pan);
        try list.append(alloc, 0x10); // field 2, varint
        try putVarint(&list, self.amount_cents);
        try list.append(alloc, 0x18); // field 3, varint
        try putVarint(&list, self.seq);
        return list.toOwnedSlice(alloc);
    }

    fn getVarint(bytes: []const u8, at: *usize) ?u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (at.* < bytes.len) {
            const b = bytes[at.*];
            at.* += 1;
            v |= @as(u64, b & 0x7F) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift > 63) return null;
        }
        return null;
    }

    /// Parse the canonical wire; `pan` borrows from `bytes`.
    fn decode(bytes: []const u8) ?CardEvent {
        var at: usize = 0;
        if (at >= bytes.len or bytes[at] != 0x0A) return null;
        at += 1;
        const pan_len = getVarint(bytes, &at) orelse return null;
        if (bytes.len - at < pan_len) return null;
        const pan = bytes[at..][0..@intCast(pan_len)];
        at += @intCast(pan_len);
        if (at >= bytes.len or bytes[at] != 0x10) return null;
        at += 1;
        const amount_cents = getVarint(bytes, &at) orelse return null;
        if (at >= bytes.len or bytes[at] != 0x18) return null;
        at += 1;
        const seq = std.math.cast(u32, getVarint(bytes, &at) orelse return null) orelse return null;
        return .{ .pan = pan, .amount_cents = amount_cents, .seq = seq };
    }
};

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

/// "****-****-****-1111"
fn mask(buf: []u8, pan: []const u8) []const u8 {
    if (pan.len < 4) return "****";
    return std.fmt.bufPrint(buf, "****-****-****-{s}", .{pan[pan.len - 4 ..]}) catch "****";
}

/// Card reader: seals every event at the point of capture, then broadcasts.
fn pinpad(count: u32) u8 {
    var bus = ChanInner.open(alloc, "", bus_name, .sender) catch return 3;
    defer bus.deinit();
    out("[pinpad] waiting for POS + gateway to subscribe...", .{});
    if (!bus.waitForRecv(2, deadline(30))) {
        err("[pinpad] POS and gateway did not both subscribe within 30s", .{});
        return 1;
    }
    var seq: u32 = 0;
    while (seq < count) : (seq += 1) {
        const event = CardEvent{ .pan = "4111111111111111", .amount_cents = 1250 + @as(u64, seq) * 100, .seq = seq };
        const plain = event.encode() catch return 4;
        defer alloc.free(plain);
        // Seal per event: fresh nonce, AEAD tag, envelope v1 framing.
        const sealed = secure.sealMessage(alloc, .aes256gcm, processor_key, plain) catch {
            err("[pinpad] seal failed", .{});
            return 1;
        };
        defer alloc.free(sealed);
        if (!(bus.send(sealed, deadline(5)) catch false)) {
            err("[pinpad] send failed", .{});
            return 1;
        }
        var mbuf: [32]u8 = undefined;
        out("[pinpad] captured {s} for {d}c -> sealed event #{d} ({d}B on the bus)", .{
            mask(&mbuf, event.pan), event.amount_cents, seq, sealed.len,
        });
        channel.sleepNs(400 * std.time.ns_per_ms);
    }
    out("[pinpad] done.", .{});
    return 0;
}

/// Receive one raw envelope; null (with a note) on a timeout or an error.
fn recvEnvelope(bus: *ChanInner, role: []const u8) ?[]u8 {
    const env = (bus.recv(deadline(30)) catch null) orelse {
        err("[{s}] no event within 30s", .{role});
        return null;
    };
    return env;
}

/// Payment gateway: the only key holder — opens and processes each event.
fn gateway(count: u32) u8 {
    var bus = ChanInner.open(alloc, "", bus_name, .receiver) catch return 3;
    defer bus.deinit();
    out("[gateway] subscribed (holds the processor key).", .{});
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const env = recvEnvelope(&bus, "gateway") orelse return 1;
        defer alloc.free(env);
        const plain = secure.openMessage(alloc, .aes256gcm, processor_key, env);
        defer if (plain) |p| alloc.free(p);
        const event = if (plain) |p| CardEvent.decode(p) else null;
        const ev = event orelse {
            err("[gateway] REJECTED an event (bad envelope?)", .{});
            return 1;
        };
        var mbuf: [32]u8 = undefined;
        out("[gateway] authorised {s} for {d}c (event #{d})", .{ mask(&mbuf, ev.pan), ev.amount_cents, ev.seq });
    }
    out("[gateway] done.", .{});
    return 0;
}

/// Merchant POS app: subscribed to the same bus, but with no key material —
/// AEAD must fail closed on every event. It can meter/route the opaque
/// envelopes, which is exactly what keeps it out of PCI scope.
fn pos(count: u32) u8 {
    var bus = ChanInner.open(alloc, "", bus_name, .receiver) catch return 3;
    defer bus.deinit();
    out("[pos] subscribed (no processor key).", .{});
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const env = recvEnvelope(&bus, "pos") orelse return 1;
        defer alloc.free(env);
        if (secure.openMessage(alloc, .aes256gcm, merchant_no_key, env)) |p| {
            alloc.free(p);
            err("[pos] SECURITY FAILURE: opened a sealed event without the key!", .{});
            return 1;
        }
        out("[pos] event #{d}: sealed envelope observed — cannot decrypt (as required)", .{i});
    }
    out("[pos] done.", .{});
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
    const role: []const u8 = if (argv.len > 1) argv[1] else "";
    const count: u32 = if (argv.len > 2) std.fmt.parseInt(u32, argv[2], 10) catch 5 else 5;

    if (std.mem.eql(u8, role, "pinpad")) std.process.exit(pinpad(count));
    if (std.mem.eql(u8, role, "gateway")) std.process.exit(gateway(count));
    if (std.mem.eql(u8, role, "pos")) std.process.exit(pos(count));
    if (std.mem.eql(u8, role, "clear")) {
        channel.clearStorage("", bus_name); // so the next run starts fresh
        std.process.exit(0);
    }
    err("usage: demo_secure_pos <pinpad|gateway|pos> [count] | clear", .{});
    std.process.exit(2);
}

test "card event wire round-trips" {
    const ev = CardEvent{ .pan = "4111111111111111", .amount_cents = 1350, .seq = 1 };
    const bytes = try ev.encode();
    defer alloc.free(bytes);
    // 0A 10 <16 B pan> 10 C6 0A 18 01 — the protobuf C++ and Rust write.
    try std.testing.expectEqual(@as(usize, 23), bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xC6, 0x0A, 0x18, 0x01 }, bytes[18..]);
    const back = CardEvent.decode(bytes) orelse return error.DecodeFailed;
    try std.testing.expectEqualStrings(ev.pan, back.pan);
    try std.testing.expectEqual(ev.amount_cents, back.amount_cents);
    try std.testing.expectEqual(ev.seq, back.seq);
}
