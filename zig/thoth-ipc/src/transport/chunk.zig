// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc chunk storage (ipc.cpp): chunk_info_t / id_pool /
// find_storage / recycle_storage — byte-exact with the C++ chunk layout so a
// C++ sender's large (>64B) messages can be read by a Zig receiver.
// See context/xlang-channel-abi.md §6c. Both halves are implemented, but only
// the receive path is wired up: this port's SENDER fragments (which C++/Rust/
// Swift receivers reassemble), so `acquireStorage` is present for symmetry with
// the other ports — and so the id_pool conformance probes have something to
// compare — rather than because anything calls it.

const std = @import("std");
const layout = @import("layout.zig");
const abi = @import("../abi_generated.zig"); // generated from abi/abi.json

pub const chunk_max_count: usize = abi.large_msg_cache;
pub const chunk_align: usize = abi.large_msg_align;
pub const chunk_header_size: usize = abi.chunk_header_size;
pub const chunk_info_size: usize = abi.chunk_info_size; // id_pool(34) + pad + lock

// chunk_info_t field offsets.
const ci_next_off: usize = abi.chunk_info_next_off; // next_[32] (u8 each)
const ci_cursor_off: usize = abi.chunk_info_cursor_off; // cursor_ (u8)
const ci_prepared_off: usize = abi.chunk_info_prepared_off; // prepared_ (bool)
const ci_lock_off: usize = abi.chunk_info_lock_off; // thoth::spin_lock (atomic<u32> TAS)

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
inline fn lockPtr(base: [*]u8) *u32 {
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

inline fn preparedPtr(base: [*]u8) *u8 {
    return @ptrCast(base + ci_prepared_off);
}

/// C++ id_pool::prepare()/init(): build the free list `next_[i] = i+1` when the
/// pool is fresh. Fresh means the whole structure compares equal to a zeroed one
/// — C++ `id_pool::invalid()` is a memcmp over all of it — not merely that the
/// first link is zero: a partially written pool (a torn init) reads as fresh to
/// the narrower test and as used to C++, and the two would then disagree about
/// whether to rebuild the list. Call under lock_.
fn poolPrepare(base: [*]u8) void {
    var untouched = preparedPtr(base).* == 0 and cursorPtr(base).* == 0;
    if (untouched) {
        for (0..chunk_max_count) |i| {
            if (nextPtr(base, i).* != 0) {
                untouched = false;
                break;
            }
        }
    }
    if (untouched) {
        for (0..chunk_max_count) |i| nextPtr(base, i).* = @intCast(i + 1);
    }
    preparedPtr(base).* = 1;
}

/// C++ id_pool::acquire(): `id = cursor_; cursor_ = next_[id]`. -1 when empty.
fn poolAcquire(base: [*]u8) i32 {
    const cursor = cursorPtr(base).*;
    if (cursor >= chunk_max_count) return -1;
    const id: usize = cursor;
    cursorPtr(base).* = nextPtr(base, id).*;
    return @intCast(id);
}

pub const Acquired = struct { id: i32, payload: [*]u8 };

/// C++ acquire_storage: take a chunk id under lock_, stamp the chunk's conns
/// bitmask with the connections that must read it, and hand back the payload.
/// Null when the pool is exhausted — C++ then falls back to inline fragments,
/// which is what this port does for every message anyway.
pub fn acquireStorage(base: [*]u8, chunk_size: usize, conns: u32) ?Acquired {
    const lock = lockPtr(base);
    layout.spinLock(lock);
    poolPrepare(base);
    const id = poolAcquire(base);
    layout.spinUnlock(lock);
    if (id < 0) return null;
    @atomicStore(u32, connsPtr(base, chunk_size, @intCast(id)), conns, .monotonic);
    return .{ .id = id, .payload = payloadPtr(base, chunk_size, id).? };
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
        layout.spinLock(lock);
        poolRelease(base, uid);
        layout.spinUnlock(lock);
    }
}

test "calcChunkSize matches C++ calc_chunk_size" {
    try std.testing.expectEqual(@as(usize, 1024), calcChunkSize(200));
    try std.testing.expectEqual(@as(usize, 3072), calcChunkSize(3000));
    try std.testing.expectEqual(@as(usize, 66560), calcChunkSize(65536));
    try std.testing.expectEqual(@as(usize, 1024), calcChunkSize(65)); // 8+65=73 -> 1024
}

// --- Conformance probe -----------------------------------------------------
//
// Byte-level trace of the primitives whose *protocol* the ABI cannot express.
// Every port emits the same lines or one of them is wrong; C++ is the reference
// (see context/abi-consistency-review.md). No shared memory and no peer: a local
// zeroed buffer is deterministic and is the state a fresh shm segment is in.
//
// Only `spinlock` is covered here. This port implements the receiving half of
// chunk storage — recycle/poolRelease — and never allocates a chunk, so it has
// no prepare/acquire to probe. The harness reports that as an explicit
// `unsupported` line rather than skipping quietly.
pub const IdPoolTrace = struct {
    /// zeroed, prepared, after-acquire3, after-release1, after-reacquire
    images: [5][chunk_info_size]u8,
    /// the three acquires, then the one after the release
    ids: [4]i32,
};

/// prepare / acquire x3 / release / acquire, dumping the pool image at each
/// step — the full free-list trace the other ports emit.
pub fn probeIdPool() IdPoolTrace {
    var buf: [chunk_info_size]u8 align(8) = @splat(0);
    const base: [*]u8 = &buf;
    var t: IdPoolTrace = undefined;
    t.images[0] = buf;
    poolPrepare(base);
    t.images[1] = buf;
    for (0..3) |i| t.ids[i] = poolAcquire(base);
    t.images[2] = buf;
    poolRelease(base, 1);
    t.images[3] = buf;
    t.ids[3] = poolAcquire(base);
    t.images[4] = buf;
    return t;
}

/// A pool that is not all-zero but whose first link is: prepare() must leave it
/// alone, because C++ compares the whole structure.
pub fn probeIdPoolPartial() [2][chunk_info_size]u8 {
    var buf: [chunk_info_size]u8 align(8) = @splat(0);
    const base: [*]u8 = &buf;
    nextPtr(base, 5).* = 7;
    var out: [2][chunk_info_size]u8 = undefined;
    out[0] = buf;
    poolPrepare(base);
    out[1] = buf;
    return out;
}

/// Release on its own, from a pool seeded by writing its bytes rather than by
/// calling prepare(). This port implements the receiving half of chunk storage
/// and so has no prepare/acquire to probe — but it does have release, and this
/// exercises the real `poolRelease`. Returns the pool image after each step:
/// seeded, after release(1), after release(0).
pub fn probeIdPoolRelease() [3][chunk_info_size]u8 {
    var buf: [chunk_info_size]u8 align(8) = @splat(0);
    const base: [*]u8 = &buf;
    for (0..chunk_max_count) |i| nextPtr(base, i).* = @intCast(i + 1);
    cursorPtr(base).* = 3; // ids 0,1,2 handed out
    base[abi.chunk_info_prepared_off] = 1;
    var out: [3][chunk_info_size]u8 = undefined;
    out[0] = buf;
    poolRelease(base, 1);
    out[1] = buf;
    poolRelease(base, 0);
    out[2] = buf;
    return out;
}

/// The three observations, in order: the field before locking, while held, and
/// after release. Returned rather than printed so the harness owns formatting.
pub fn probeSpinLock() [3]u32 {
    var buf: [chunk_info_size]u8 align(8) = @splat(0);
    const base: [*]u8 = &buf;
    const lock = lockPtr(base);
    const init_v = @atomicLoad(u32, lock, .monotonic);
    layout.spinLock(lock);
    const held_v = @atomicLoad(u32, lock, .monotonic);
    layout.spinUnlock(lock);
    const free_v = @atomicLoad(u32, lock, .monotonic);
    return .{ init_v, held_v, free_v };
}

test "acquireStorage hands out distinct chunks and recycle returns them" {
    // The allocator half exists for symmetry — this port's sender fragments —
    // so nothing else exercises it. Round-trip it here rather than leaving it
    // to the cross-language probes alone.
    const chunk_size = calcChunkSize(200);
    const buf = try std.testing.allocator.alignedAlloc(u8, .of(u64), chunkShmSize(chunk_size));
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    const base: [*]u8 = buf.ptr;

    const conns: u32 = 0b101;
    const a = acquireStorage(base, chunk_size, conns).?;
    const b = acquireStorage(base, chunk_size, conns).?;
    try std.testing.expect(a.id != b.id);
    try std.testing.expectEqual(@as(i32, 0), a.id); // C++ hands out 0 first
    try std.testing.expectEqual(@as(i32, 1), b.id);
    try std.testing.expectEqual(conns, @atomicLoad(u32, connsPtr(base, chunk_size, 0), .monotonic));

    // Payloads are distinct, chunk_size apart, and past the per-chunk header.
    try std.testing.expectEqual(@intFromPtr(a.payload) + chunk_size, @intFromPtr(b.payload));
    try std.testing.expectEqual(
        @intFromPtr(base) + chunk_info_size + chunk_header_size,
        @intFromPtr(a.payload),
    );

    // Recycling by the last reader returns the id, which the next acquire reuses.
    recycle(base, chunk_size, a.id, conns);
    const c = acquireStorage(base, chunk_size, conns).?;
    try std.testing.expectEqual(a.id, c.id);
}

test "acquireStorage returns null once the pool is exhausted" {
    const chunk_size = calcChunkSize(64);
    const buf = try std.testing.allocator.alignedAlloc(u8, .of(u64), chunkShmSize(chunk_size));
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);
    const base: [*]u8 = buf.ptr;
    for (0..chunk_max_count) |_| try std.testing.expect(acquireStorage(base, chunk_size, 1) != null);
    // C++ falls back to inline fragments here rather than failing the send.
    try std.testing.expect(acquireStorage(base, chunk_size, 1) == null);
}
