// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Sync ABI guard sidecar (byte-exact with the C++/Rust/Swift SyncAbiGuard). Each
// named mutex/condition gets a companion stamp segment that records the wire ABI
// it was created with, so a peer of a different language fails fast on mismatch
// instead of corrupting shared state. Stamp = 6×u32:
//   [0] magic "LISA" (0x4C495341)  [1] major  [2] minor
//   [3] backend_id (2 = apple_ulock)  [4] primitive_id (1=mutex,2=condition)
//   [5] payload_size (8)

const std = @import("std");
const shm = @import("../platform/shm.zig");
// Numeric ABI constants/offsets are generated from abi/abi.json (single source
// of truth) by `tools/abi`; re-export the wire-visible ones so drift is caught.
const abi = @import("../abi_generated.zig");

const ShmHandle = shm.ShmHandle;

const MAGIC: u32 = abi.syncabi_magic; // "LISA" (0x4C495341)
const INIT_IN_PROGRESS: u32 = 0xFFFF_FFFF;
const VERSION_MAJOR: u32 = 1;
const VERSION_MINOR: u32 = 0;
const BACKEND_APPLE_ULOCK: u32 = abi.syncabi_backend_ulock; // apple_ulock = 2
const PAYLOAD_SIZE: u32 = 8; // both mutex (state+holder) and condition (seq+waiters)
const INIT_WAIT_LIMIT: u32 = 16_384;
const STAMP_SIZE: usize = abi.syncabi_stamp_size; // 6 x u32 = 24

comptime {
    // The stamp is 6 sequential u32 words; word(base, i) lives at i*4. Guard that
    // the word layout still matches the generated SyncAbi stamp field offsets.
    std.debug.assert(abi.syncabi_stamp_magic_off == 0 * 4);
    std.debug.assert(abi.syncabi_stamp_ver_major_off == 1 * 4);
    std.debug.assert(abi.syncabi_stamp_ver_minor_off == 2 * 4);
    std.debug.assert(abi.syncabi_stamp_backend_id_off == 3 * 4);
    std.debug.assert(abi.syncabi_stamp_primitive_id_off == 4 * 4);
    std.debug.assert(abi.syncabi_stamp_payload_size_off == 5 * 4);
    std.debug.assert(STAMP_SIZE == 6 * 4);
}

pub const Primitive = enum(u32) {
    mutex = 1,
    condition = 2,

    fn suffix(self: Primitive) []const u8 {
        return switch (self) {
            .mutex => abi.sync_abi_suffix_mutex,
            .condition => abi.sync_abi_suffix_condition,
        };
    }
};

pub const Error = error{SyncAbiMismatch} || shm.ShmError;

/// The guard segment, kept mapped for the primitive's lifetime (refcount holds it).
pub const Guard = struct {
    sidecar: ShmHandle,

    pub fn release(self: *Guard) void {
        self.sidecar.release();
    }
};

/// Open (or create) and validate the sidecar stamp for `<name><suffix>`.
pub fn ensure(name: []const u8, primitive: Primitive) Error!Guard {
    var buf: [256]u8 = undefined;
    const sidecar_name = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, primitive.suffix() }) catch unreachable;
    var sidecar = try ShmHandle.acquire(sidecar_name, STAMP_SIZE, .create_or_open);
    errdefer sidecar.release();
    try initOrValidate(sidecar.ptr(), primitive);
    return .{ .sidecar = sidecar };
}

inline fn word(base: [*]u8, i: usize) *u32 {
    return @ptrCast(@alignCast(base + i * 4));
}

fn initOrValidate(base: [*]u8, primitive: Primitive) Error!void {
    var spins: u32 = 0;
    while (true) {
        const magic = @atomicLoad(u32, word(base, 0), .acquire);
        if (magic == MAGIC) return validate(base, primitive);
        if (magic == INIT_IN_PROGRESS) {
            if (spins >= INIT_WAIT_LIMIT) return Error.SyncAbiMismatch;
            spins +%= 1;
            std.Thread.yield() catch {};
            continue;
        }
        spins = 0;
        if (magic == 0) {
            if (@cmpxchgWeak(u32, word(base, 0), 0, INIT_IN_PROGRESS, .acq_rel, .acquire) != null) continue;
            @atomicStore(u32, word(base, 1), VERSION_MAJOR, .monotonic);
            @atomicStore(u32, word(base, 2), VERSION_MINOR, .monotonic);
            @atomicStore(u32, word(base, 3), BACKEND_APPLE_ULOCK, .monotonic);
            @atomicStore(u32, word(base, 4), @intFromEnum(primitive), .monotonic);
            @atomicStore(u32, word(base, 5), PAYLOAD_SIZE, .monotonic);
            @atomicStore(u32, word(base, 0), MAGIC, .release);
            return;
        }
        return Error.SyncAbiMismatch; // some other, incompatible magic
    }
}

fn validate(base: [*]u8, primitive: Primitive) Error!void {
    if (@atomicLoad(u32, word(base, 1), .acquire) != VERSION_MAJOR) return Error.SyncAbiMismatch;
    if (@atomicLoad(u32, word(base, 2), .acquire) != VERSION_MINOR) return Error.SyncAbiMismatch;
    if (@atomicLoad(u32, word(base, 3), .acquire) != BACKEND_APPLE_ULOCK) return Error.SyncAbiMismatch;
    if (@atomicLoad(u32, word(base, 4), .acquire) != @intFromEnum(primitive)) return Error.SyncAbiMismatch;
    if (@atomicLoad(u32, word(base, 5), .acquire) != PAYLOAD_SIZE) return Error.SyncAbiMismatch;
}

pub fn clearStorage(name: []const u8, primitive: Primitive) void {
    var buf: [256]u8 = undefined;
    const sidecar_name = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, primitive.suffix() }) catch unreachable;
    ShmHandle.clearStorage(sidecar_name);
}
