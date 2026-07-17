// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Secure AEAD envelope v1 ("SIPC", doc/adr/0004), byte-exact with the
// C++/Rust/Swift SecureCodec. The AEAD is done with Zig's native std.crypto
// (AES-256-GCM / ChaCha20-Poly1305) — a standardized algorithm produces
// byte-identical ciphertext+tag to the OpenSSL-backed ports for the same
// key/nonce/plaintext/AAD, so no C crypto dependency is needed. Nonce = 12 B,
// tag = 16 B, AAD = empty (matching secure-crypto-c).
//
// Envelope layout (all little-endian):
//   magic[4]="SIPC"  version@4=1  algId(u16)@5  keyId(u32)@7
//   nonceSize(u16)@11  tagSize(u16)@13  ciphertextSize(u32)@15
//   then nonce ‖ ciphertext ‖ tag   (fixed header = 19 bytes)

const std = @import("std");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const NONCE_SIZE = 12;
const TAG_SIZE = 16;
const KEY_SIZE = 32;
const FIXED_HEADER = 19;

// macOS entropy source (getentropy(2), ≤256 B) for the per-seal random nonce.
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

pub const Alg = enum(u16) {
    aes256gcm = 1,
    chacha20poly1305 = 2,

    pub fn fromStr(s: []const u8) ?Alg {
        if (std.mem.eql(u8, s, "aes256gcm")) return .aes256gcm;
        if (std.mem.eql(u8, s, "chacha20poly1305")) return .chacha20poly1305;
        return null;
    }
};

pub const Key = struct { id: u32, bytes: [KEY_SIZE]u8 };

// The shared xlang test keys — byte-identical across the C++/Rust/Swift harnesses.
pub const test_key = Key{
    .id = 0x0A0B_0C0D,
    .bytes = blk: {
        var b: [KEY_SIZE]u8 = undefined;
        for (&b, 0..) |*x, i| x.* = @intCast(i); // 0x00..0x1F
        break :blk b;
    },
};
/// Same key id, different key material → AEAD open fails (fail-closed).
pub const wrong_key = Key{
    .id = 0x0A0B_0C0D,
    .bytes = .{
        0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B,
        0x3C, 0x2D, 0x1E, 0x0F, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    },
};
/// Same key material, different key id → the envelope key_id check rejects it.
pub const wrong_id_key = Key{ .id = 0x0A0B_0C0D + 1, .bytes = test_key.bytes };

fn aeadSeal(comptime C: type, key: [KEY_SIZE]u8, nonce: [NONCE_SIZE]u8, plain: []const u8, ct: []u8, tag: *[TAG_SIZE]u8) void {
    C.encrypt(ct, tag, plain, "", nonce, key);
}
fn aeadOpen(comptime C: type, key: [KEY_SIZE]u8, nonce: [NONCE_SIZE]u8, ct: []const u8, tag: [TAG_SIZE]u8, plain: []u8) bool {
    C.decrypt(plain, ct, tag, "", nonce, key) catch return false;
    return true;
}

fn seal(alg: Alg, key: [KEY_SIZE]u8, nonce: [NONCE_SIZE]u8, plain: []const u8, ct: []u8, tag: *[TAG_SIZE]u8) void {
    switch (alg) {
        .aes256gcm => aeadSeal(Aes256Gcm, key, nonce, plain, ct, tag),
        .chacha20poly1305 => aeadSeal(ChaCha20Poly1305, key, nonce, plain, ct, tag),
    }
}
fn openAead(alg: Alg, key: [KEY_SIZE]u8, nonce: [NONCE_SIZE]u8, ct: []const u8, tag: [TAG_SIZE]u8, plain: []u8) bool {
    return switch (alg) {
        .aes256gcm => aeadOpen(Aes256Gcm, key, nonce, ct, tag, plain),
        .chacha20poly1305 => aeadOpen(ChaCha20Poly1305, key, nonce, ct, tag, plain),
    };
}

/// Seal `plain` into a SIPC envelope. Caller owns the returned bytes.
pub fn sealMessage(alloc: std.mem.Allocator, alg: Alg, key: Key, plain: []const u8) ![]u8 {
    var nonce: [NONCE_SIZE]u8 = undefined;
    if (getentropy(&nonce, NONCE_SIZE) != 0) return error.Entropy;

    const ct = try alloc.alloc(u8, plain.len);
    defer alloc.free(ct);
    var tag: [TAG_SIZE]u8 = undefined;
    seal(alg, key.bytes, nonce, plain, ct, &tag);

    const total = FIXED_HEADER + NONCE_SIZE + plain.len + TAG_SIZE;
    const out = try alloc.alloc(u8, total);
    @memcpy(out[0..4], "SIPC");
    out[4] = 1;
    std.mem.writeInt(u16, out[5..7], @intFromEnum(alg), .little);
    std.mem.writeInt(u32, out[7..11], key.id, .little);
    std.mem.writeInt(u16, out[11..13], NONCE_SIZE, .little);
    std.mem.writeInt(u16, out[13..15], TAG_SIZE, .little);
    std.mem.writeInt(u32, out[15..19], @intCast(ct.len), .little);
    var o: usize = FIXED_HEADER;
    @memcpy(out[o .. o + NONCE_SIZE], &nonce);
    o += NONCE_SIZE;
    @memcpy(out[o .. o + ct.len], ct);
    o += ct.len;
    @memcpy(out[o .. o + TAG_SIZE], &tag);
    return out;
}

/// Open a SIPC envelope, fail-closed: null on bad framing, algorithm mismatch,
/// key-id mismatch, or AEAD authentication failure. Caller owns the plaintext.
pub fn openMessage(alloc: std.mem.Allocator, expected_alg: Alg, key: Key, env: []const u8) ?[]u8 {
    if (env.len < FIXED_HEADER) return null;
    if (!std.mem.eql(u8, env[0..4], "SIPC")) return null;
    if (env[4] != 1) return null;
    const alg_id = std.mem.readInt(u16, env[5..7], .little);
    const key_id = std.mem.readInt(u32, env[7..11], .little);
    const nonce_size = std.mem.readInt(u16, env[11..13], .little);
    const tag_size = std.mem.readInt(u16, env[13..15], .little);
    const ct_size = std.mem.readInt(u32, env[15..19], .little);

    if (alg_id != @intFromEnum(expected_alg)) return null;
    if (key_id != key.id) return null;
    if (nonce_size != NONCE_SIZE or tag_size != TAG_SIZE) return null;
    const payload = @as(usize, nonce_size) + ct_size + tag_size;
    if (env.len - FIXED_HEADER != payload) return null;

    const nonce = env[FIXED_HEADER..][0..NONCE_SIZE].*;
    const ct = env[FIXED_HEADER + NONCE_SIZE ..][0..ct_size];
    const tag = env[FIXED_HEADER + NONCE_SIZE + ct_size ..][0..TAG_SIZE].*;

    const plain = alloc.alloc(u8, ct_size) catch return null;
    if (!openAead(expected_alg, key.bytes, nonce, ct, tag, plain)) {
        alloc.free(plain);
        return null;
    }
    return plain;
}

test "seal/open round-trip both algorithms" {
    const a = std.testing.allocator;
    const msg = "the quick brown fox jumps over the lazy dog";
    for ([_]Alg{ .aes256gcm, .chacha20poly1305 }) |alg| {
        const env = try sealMessage(a, alg, test_key, msg);
        defer a.free(env);
        const opened = openMessage(a, alg, test_key, env) orelse return error.OpenFailed;
        defer a.free(opened);
        try std.testing.expectEqualSlices(u8, msg, opened);
        // wrong key material and wrong key id must both fail closed.
        try std.testing.expect(openMessage(a, alg, wrong_key, env) == null);
        try std.testing.expect(openMessage(a, alg, wrong_id_key, env) == null);
    }
}
