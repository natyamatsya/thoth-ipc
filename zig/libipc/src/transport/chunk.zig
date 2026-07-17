// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc chunk storage (ipc.cpp): chunk_info_t / id_pool /
// find_storage / recycle_storage — byte-exact with the C++ chunk layout so a
// C++ sender's large (>64B) messages can be read by a Zig receiver.
// See context/xlang-channel-abi.md §6c. Only the RECEIVE path is implemented:
// this port's SENDER fragments (which C++/Rust/Swift receivers reassemble), so
// no chunk-storage send path is needed.

const std = @import("std");
const layout = @import("layout.zig");
const abi = @import("../abi_generated.zig"); // generated from abi/abi.json

pub const chunk_max_count: usize = abi.large_msg_cache;
pub const chunk_align: usize = abi.large_msg_align;
pub const chunk_header_size: usize = abi.chunk_header_size;
pub const chunk_info_size: usize = abi.chunk_info_size; // id_pool(34) + pad + lock

// chunk_info_t field offsets.
const ci_next_off: usize = 0; // next_[32] (u8 each)
const ci_cursor_off: usize = 32; // cursor_ (u8)
const ci_lock_off: usize = 36; // os_unfair_lock

/// ceil((chunk_header_size + size) / chunk_align) * chunk_align. The chunk-shm
/// name embeds this, so it must match C++ calc_chunk_size exactly.
pub fn calcChunkSize(size: usize) usize {
    const x = chunk_header_size + size;
    return (x + chunk_align - 1) / chunk_align * chunk_align;
}

pub fn chunkShmSize(chunk_size: usize) usize {
    return chunk_info_size + chunk_max_count * chunk_size;
}

inline fn cursorPtr(base: [*]u8) *u8 {
    return @ptrCast(base + ci_cursor_off);
}
inline fn nextPtr(base: [*]u8, id: usize) *u8 {
    return @ptrCast(base + ci_next_off + id);
}
inline fn lockPtr(base: [*]u8) *layout.os_unfair_lock {
    return @ptrCast(@alignCast(base + ci_lock_off));
}
inline fn connsPtr(base: [*]u8, chunk_size: usize, id: usize) *u32 {
    return @ptrCast(@alignCast(base + chunk_info_size + chunk_size * id));
}

/// C++ find_storage: pointer to the payload of chunk `id` (offset chunk_header_size).
pub fn payloadPtr(base: [*]u8, chunk_size: usize, id: i32) ?[*]u8 {
    if (id < 0 or id >= @as(i32, @intCast(chunk_max_count))) return null;
    const uid: usize = @intCast(id);
    return base + chunk_info_size + chunk_size * uid + chunk_header_size;
}

/// C++ id_pool::release under lock_.
fn poolRelease(base: [*]u8, id: usize) void {
    nextPtr(base, id).* = cursorPtr(base).*;
    cursorPtr(base).* = @intCast(id);
}

/// C++ recycle_storage / sub_rc<broadcast>: clear this receiver's bit from the
/// chunk conns; when it reaches 0 (last reader), release the id under lock_.
pub fn recycle(base: [*]u8, chunk_size: usize, id: i32, conn_id: u32) void {
    if (id < 0 or id >= @as(i32, @intCast(chunk_max_count))) return;
    const uid: usize = @intCast(id);
    const conns = connsPtr(base, chunk_size, uid);
    var k: u32 = 0;
    var is_last = false;
    while (true) {
        const cur = @atomicLoad(u32, conns, .acquire);
        const nxt = cur & ~conn_id;
        if (@cmpxchgWeak(u32, conns, cur, nxt, .release, .monotonic) == null) {
            is_last = (nxt == 0);
            break;
        }
        layout.adaptiveYield(&k);
    }
    if (is_last) {
        const lock = lockPtr(base);
        layout.os_unfair_lock_lock(lock);
        poolRelease(base, uid);
        layout.os_unfair_lock_unlock(lock);
    }
}

test "calcChunkSize matches C++ calc_chunk_size" {
    try std.testing.expectEqual(@as(usize, 1024), calcChunkSize(200));
    try std.testing.expectEqual(@as(usize, 3072), calcChunkSize(3000));
    try std.testing.expectEqual(@as(usize, 66560), calcChunkSize(65536));
    try std.testing.expectEqual(@as(usize, 1024), calcChunkSize(65)); // 8+65=73 -> 1024
}
