// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/shm_name.h — produces POSIX
// shm-safe names byte-identical to the C++, Rust and Swift implementations.
// See context/xlang-channel-abi.md §1.

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("../transport/layout.zig");

/// macOS PSHMNAMLEN is 31; Linux allows up to ~255. 0 = no truncation.
pub const shm_name_max: usize = if (builtin.os.tag == .macos) 31 else 0;

/// FNV-1a 64-bit — identical to C++ fnv1a_64() and Rust fnv1a_64().
pub fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (data) |byte| {
        hash ^= @as(u64, byte);
        hash = hash *% 0x0000_0100_0000_01b3;
    }
    return hash;
}

/// Fixed-width 16-char lowercase hex, MSB-first (mirrors Swift toHex16 / Rust to_hex).
fn toHex16(val: u64, out: *[16]u8) void {
    const digits = "0123456789abcdef";
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        out[i] = digits[@intCast(v & 0xf)];
        v >>= 4;
    }
}

/// Produce a POSIX shm-safe name (with leading '/') into `buf`, returning the
/// used slice. When `shm_name_max > 0`, names whose POSIX form would exceed the
/// limit are shortened to `/<first-13-chars>_<16-hex-FNV-1a>`. Byte-identical to
/// the C++ make_shm_name() and the Swift/Rust ports.
pub fn makeShmName(buf: []u8, name: []const u8) []const u8 {
    // Build the '/'-prefixed form first.
    var tmp_buf: [512]u8 = undefined;
    var full: []const u8 = undefined;
    if (name.len > 0 and name[0] == '/') {
        full = name;
    } else {
        tmp_buf[0] = '/';
        @memcpy(tmp_buf[1 .. 1 + name.len], name);
        full = tmp_buf[0 .. 1 + name.len];
    }

    if (shm_name_max == 0 or full.len <= shm_name_max) {
        @memcpy(buf[0..full.len], full);
        return buf[0..full.len];
    }

    // 1 (underscore) + 16 (hex) = 17-byte suffix; keep up to prefix_len body bytes.
    const hash_suffix_len: usize = 17;
    const prefix_len: usize = if (shm_name_max > hash_suffix_len + 1)
        shm_name_max - hash_suffix_len - 1
    else
        0;

    var hex: [16]u8 = undefined;
    toHex16(fnv1a64(full), &hex);

    var n: usize = 0;
    buf[n] = '/';
    n += 1;
    if (prefix_len > 0) {
        const body = full[1..]; // drop leading '/'
        const take = @min(prefix_len, body.len);
        @memcpy(buf[n .. n + take], body[0..take]);
        n += take;
    }
    buf[n] = '_';
    n += 1;
    @memcpy(buf[n .. n + 16], &hex);
    n += 16;
    return buf[0..n];
}

// --- Byte-exact logical object names (C++ make_prefix) ----------------------
// make_prefix(prefix, TAG, name) = prefix + "__IPC_SHM__" + TAG + name.
// The default channel prefix is "" (see Swift Route.connect / Rust).

/// Ring: __IPC_SHM__QU_CONN__<name>__<DataSize>__<AlignSize>.
pub fn ringName(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__IPC_SHM__QU_CONN__{s}__{d}__{d}", .{
        prefix, name, layout.data_length, layout.align_size,
    }) catch unreachable;
}

/// cc_id endpoint-identity counter: __IPC_SHM__CA_CONN__ — PREFIX-GLOBAL (no
/// channel name), matching C++ cc_acc. A per-channel counter makes a C++ sender
/// and a Zig receiver collide on cc_id and the receiver silently drops messages.
pub fn ccIdName(buf: []u8, prefix: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__IPC_SHM__CA_CONN__", .{prefix}) catch unreachable;
}

/// Chunk storage: __IPC_SHM__CHUNK_INFO__<chunk_size> — prefix-global.
pub fn chunkShmName(buf: []u8, prefix: []const u8, chunk_size: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__IPC_SHM__CHUNK_INFO__{d}", .{ prefix, chunk_size }) catch unreachable;
}

test "fnv1a64 golden (notify hash input)" {
    // Golden from context/xlang-channel-abi.md §8: ("","xchan") notify hash.
    const h = fnv1a64("__IPC_SHM__NOTIFY__xchan");
    try std.testing.expectEqual(@as(u64, 0xd7484adebb2d170d), h);
}

test "makeShmName passthrough short" {
    var buf: [256]u8 = undefined;
    const out = makeShmName(&buf, "short");
    try std.testing.expectEqualStrings("/short", out);
}

test "makeShmName shortens over 31 on macOS" {
    if (shm_name_max == 0) return;
    var buf: [256]u8 = undefined;
    const long = "__IPC_SHM__QU_CONN__mychannel__64__8"; // > 31 with leading '/'
    const out = makeShmName(&buf, long);
    try std.testing.expect(out.len <= shm_name_max);
    try std.testing.expect(out[0] == '/');
    try std.testing.expect(out[out.len - 17] == '_');
}
