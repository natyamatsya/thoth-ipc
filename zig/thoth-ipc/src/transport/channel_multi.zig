// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-writer `thoth::channel` (N writers, N readers, broadcast) — the Zig side
// of context/xlang-channel-multiwriter-rfc.md. Byte-exact with the C++
// prod_cons_impl<multi,multi,broadcast> (cpp/thoth-ipc/src/thoth-ipc/prod_cons.h
// L301-441): 96-byte slots with a per-slot `f_ct_` commit flag, a commit-index
// (`ct_`) header, the channel-specific 3-region `rc_` packing, and a shared
// per-channel `AC_CONN__` message-id counter (so concurrent writers don't
// collide on `id_`).
//
// Reuses the route port's shm / waiter / liveness / chunk / notify layers and
// the msg_t framing unchanged (only the ring element and push/pop differ). The
// open scaffolding and fragment reassembly are duplicated from channel.zig
// rather than shared, to avoid touching the proven single-writer route code;
// this is a candidate for DRY-ing once Rust/Swift land (see the RFC).

const std = @import("std");
const layout = @import("layout.zig");
const chunk = @import("chunk.zig");
const waiter = @import("waiter.zig");
const liveness = @import("liveness.zig");
const notify = @import("notify.zig");
const shm = @import("../platform/shm.zig");
const shmname = @import("../platform/shmname.zig");

const ShmHandle = shm.ShmHandle;
const Waiter = waiter.Waiter;

pub const Mode = enum { sender, receiver };
pub const Error = @import("channel.zig").Error;

// --- Multi-producer ring layout (generated from abi/abi.json by tools/abi) ---

const abi = @import("../abi_generated.zig");

const ring_user_size: usize = abi.channel_ring_size; // 96 B slot -> 24832 B ring
const elem_stride: usize = abi.channel_elem_size;
const elem_rc_off: usize = abi.channel_elem_rc_off;
const elem_fct_off: usize = abi.channel_elem_f_ct_off;
// Header offsets are identical to route (route's wt_ slot holds the channel ct_).
const off_ct: usize = layout.off_wt;

// Channel-specific rc_ bit-packing (prod_cons.h L307-313).
const rc_mask: u64 = abi.chan_rc_mask; // low 32: per-reader "needs to read" bitmask
const ep_mask: u64 = abi.chan_ep_mask; // low 56: rc bits + internal read-generation
const ep_incr: u64 = abi.chan_ep_incr; // epoch increment (top byte)
const ic_mask: u64 = abi.chan_ic_mask; // invert-carry mask
const ic_incr: u64 = abi.chan_ic_incr; // internal read-generation increment (bits 32..)

inline fn incRc(rc: u64) u64 {
    return (rc & ic_mask) | ((rc +% ic_incr) & ~ic_mask);
}
inline fn incMask(rc: u64) u64 {
    return incRc(rc) & ~rc_mask;
}

inline fn slotBase(base: [*]u8, idx: usize) [*]u8 {
    return base + layout.off_block + idx * elem_stride;
}
inline fn slotRc(sb: [*]u8) *u64 {
    return @ptrCast(@alignCast(sb + elem_rc_off));
}
inline fn slotFct(sb: [*]u8) *u64 {
    return @ptrCast(@alignCast(sb + elem_fct_off));
}

comptime {
    std.debug.assert(layout.off_block + elem_stride * layout.ring_size == 24768);
    std.debug.assert(elem_fct_off + 8 == elem_stride);
}

fn acIdName(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    // Shared per-channel message-id counter (C++ AC_CONN__<name>).
    return shmname.acConnName(buf, prefix, name);
}

const Frag = struct { offset: usize, buf: []u8 };

pub const ChannelInner = struct {
    alloc: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    mode: Mode,
    ring: ShmHandle,
    ccid: ShmHandle, // CA_CONN__ prefix-global endpoint identity
    acid: ShmHandle, // AC_CONN__ per-channel shared message-id counter
    liveness_shm: ShmHandle,
    conn_id: u32 = 0,
    cc_id: u32 = 0,
    read_cursor: u32 = 0,
    recv_cache: std.AutoHashMap(u32, Frag),
    chunk_shms: std.AutoHashMap(usize, ShmHandle),
    rd_waiter: Waiter,
    wt_waiter: Waiter,
    cc_waiter: Waiter,
    disconnected: bool = false,

    pub fn open(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8, mode: Mode) Error!ChannelInner {
        var rbuf: [256]u8 = undefined;
        var cbuf: [256]u8 = undefined;
        var abuf: [256]u8 = undefined;
        var lbuf: [256]u8 = undefined;
        // Same ring NAME as route (QU_CONN__<name>__64__8), distinct layout/size.
        var ring = try ShmHandle.acquire(shmname.ringName(&rbuf, prefix, name), ring_user_size, .create_or_open);
        errdefer ring.release();
        var ccid = try ShmHandle.acquire(shmname.ccIdName(&cbuf, prefix), 4, .create_or_open);
        errdefer ccid.release();
        var acid = try ShmHandle.acquire(acIdName(&abuf, prefix, name), 4, .create_or_open);
        errdefer acid.release();
        var liveness_shm = try ShmHandle.acquire(liveness.livenessName(&lbuf, prefix, name), liveness.shm_size_bytes, .create_or_open);
        errdefer liveness_shm.release();
        var rd_waiter = try Waiter.open(prefix, name, "RD_CONN__");
        errdefer rd_waiter.release();
        var wt_waiter = try Waiter.open(prefix, name, "WT_CONN__");
        errdefer wt_waiter.release();
        var cc_waiter = try Waiter.open(prefix, name, "CC_CONN__");
        errdefer cc_waiter.release();

        const base = ring.ptr();
        layout.initHeader(base); // shared conn_head_base DCLP (same as route)

        const counter: *u32 = @ptrCast(@alignCast(ccid.ptr()));
        var cc_id = @atomicRmw(u32, counter, .Add, 1, .monotonic) +% 1;
        if (cc_id == 0) cc_id = @atomicRmw(u32, counter, .Add, 1, .monotonic) +% 1;

        var self = ChannelInner{
            .alloc = alloc,
            .prefix = prefix,
            .name = name,
            .mode = mode,
            .ring = ring,
            .ccid = ccid,
            .acid = acid,
            .liveness_shm = liveness_shm,
            .cc_id = cc_id,
            .recv_cache = std.AutoHashMap(u32, Frag).init(alloc),
            .chunk_shms = std.AutoHashMap(usize, ShmHandle).init(alloc),
            .rd_waiter = rd_waiter,
            .wt_waiter = wt_waiter,
            .cc_waiter = cc_waiter,
        };

        if (mode == .receiver) {
            const cc = layout.u32ptr(base, layout.off_cc);
            const lv = self.liveness_shm.ptr();
            _ = liveness.reapDeadReceivers(lv, @atomicLoad(u32, cc, .acquire), cc);
            var k: u32 = 0;
            while (true) {
                const curr = @atomicLoad(u32, cc, .acquire);
                const next = curr | (curr +% 1);
                if (next == curr) return Error.ConnectFailed;
                if (@cmpxchgWeak(u32, cc, curr, next, .release, .monotonic) == null) {
                    self.conn_id = next ^ curr;
                    break;
                }
                layout.adaptiveYield(&k);
            }
            liveness.setOwner(lv, self.conn_id);
            self.read_cursor = @atomicLoad(u32, layout.u32ptr(base, off_ct), .acquire);
            self.cc_waiter.broadcast();
        }
        return self;
    }

    pub fn recvCount(self: *ChannelInner) usize {
        const cc = @atomicLoad(u32, layout.u32ptr(self.ring.ptr(), layout.off_cc), .acquire);
        return @popCount(cc);
    }

    pub fn disconnect(self: *ChannelInner) void {
        if (self.disconnected) return;
        if (self.mode == .receiver) {
            const cc = layout.u32ptr(self.ring.ptr(), layout.off_cc);
            _ = @atomicRmw(u32, cc, .And, ~self.conn_id, .acq_rel);
            liveness.clearOwner(self.liveness_shm.ptr(), self.conn_id);
        }
        self.disconnected = true;
    }

    pub fn deinit(self: *ChannelInner) void {
        self.disconnect();
        var it = self.recv_cache.valueIterator();
        while (it.next()) |f| self.alloc.free(f.buf);
        self.recv_cache.deinit();
        var cit = self.chunk_shms.valueIterator();
        while (cit.next()) |h| h.release();
        self.chunk_shms.deinit();
        self.cc_waiter.release();
        self.wt_waiter.release();
        self.rd_waiter.release();
        self.liveness_shm.release();
        self.acid.release();
        self.ccid.release();
        self.ring.release();
    }

    pub fn waitForRecv(self: *ChannelInner, count: usize, deadline_ns: i128) bool {
        var yk: u32 = 0;
        while (true) {
            if (self.recvCount() >= count) return true;
            if (layout.nowNs() >= deadline_ns) return false;
            layout.adaptiveYield(&yk);
        }
    }

    // --- Send (multi-producer): shared AC_CONN__ id, fragment, commit ---------

    pub fn send(self: *ChannelInner, data: []const u8, deadline_ns: i128) Error!bool {
        if (data.len == 0) return false;
        const base = self.ring.ptr();
        if (@atomicLoad(u32, layout.u32ptr(base, layout.off_cc), .monotonic) == 0) return false;

        const size = data.len;
        // Draw the message id from the SHARED per-channel counter so two writers
        // never collide in the receiver's reassembly cache (RFC Part B).
        const ac: *u32 = @ptrCast(@alignCast(self.acid.ptr()));
        const msg_id = @atomicRmw(u32, ac, .Add, 1, .monotonic);

        const full = size / layout.data_length;
        var offset: usize = 0;
        var i: usize = 0;
        while (i < full) : (i += 1) {
            const remain: i32 = @as(i32, @intCast(size)) - @as(i32, @intCast(offset)) - @as(i32, @intCast(layout.data_length));
            if (!try self.pushFragment(msg_id, remain, data[offset .. offset + layout.data_length], deadline_ns)) return false;
            offset += layout.data_length;
        }
        const tail = size - offset;
        if (tail > 0) {
            const remain: i32 = @as(i32, @intCast(tail)) - @as(i32, @intCast(layout.data_length));
            if (!try self.pushFragment(msg_id, remain, data[offset..], deadline_ns)) return false;
        }
        notify.post(self.prefix, self.name);
        return true;
    }

    /// Claim the next commit slot (C++ multi-producer push): `ct_` claim +
    /// `f_ct_ = ~ct` publish, per prod_cons.h L337-372. Busy-polls with a
    /// deadline while the target slot is still being read / not yet drained.
    fn pushFragment(self: *ChannelInner, msg_id: u32, remain: i32, payload: []const u8, deadline_ns: i128) Error!bool {
        const base = self.ring.ptr();
        const cc_p = layout.u32ptr(base, layout.off_cc);
        const ct_p = layout.u32ptr(base, off_ct);
        const epoch_p = layout.u64ptr(base, layout.off_epoch);

        var epoch = @atomicLoad(u64, epoch_p, .acquire);
        var claimed_ct: u32 = 0;
        var yk: u32 = 0;
        claim: while (true) {
            const cc: u64 = @atomicLoad(u32, cc_p, .monotonic);
            if (cc == 0) return false; // no reader
            const cur_ct = @atomicLoad(u32, ct_p, .monotonic);
            const sb = slotBase(base, cur_ct % layout.ring_size);
            const rc_p = slotRc(sb);
            const cur_rc = @atomicLoad(u64, rc_p, .monotonic);
            const rem_cc = cur_rc & rc_mask;
            if ((cc & rem_cc) != 0 and (cur_rc & ~ep_mask) == epoch) {
                // Slot still held by a live reader from the current epoch.
                if (layout.nowNs() >= deadline_ns) return false;
                layout.adaptiveYield(&yk);
                continue :claim;
            } else if (rem_cc == 0) {
                const cur_fl = @atomicLoad(u64, slotFct(sb), .acquire);
                if (cur_fl != @as(u64, cur_ct) and cur_fl != 0) {
                    // Previous lap's data not yet drained by the reader.
                    if (layout.nowNs() >= deadline_ns) return false;
                    layout.adaptiveYield(&yk);
                    continue :claim;
                }
            }
            const desired = incMask(epoch | (cur_rc & ep_mask)) | cc;
            if (@cmpxchgWeak(u64, rc_p, cur_rc, desired, .monotonic, .monotonic) == null) {
                // Won the slot; re-validate the epoch hasn't moved (force_push).
                // An acquire load is equivalent to the old self-CAS (a no-op store
                // publishes nothing) without the weak-CAS spurious-failure retry.
                const now = @atomicLoad(u64, epoch_p, .acquire);
                if (now == epoch) {
                    claimed_ct = cur_ct;
                    break :claim;
                }
                epoch = now;
            }
            layout.adaptiveYield(&yk);
        }

        // Only the winner of this slot reaches here — advance the commit index,
        // write the fragment, then publish the commit flag for readers.
        @atomicStore(u32, ct_p, claimed_ct +% 1, .release);
        const sb = slotBase(base, claimed_ct % layout.ring_size);
        layout.writeMsgHeader(sb, .{ .cc_id = self.cc_id, .id = msg_id, .remain = remain, .storage = false });
        @memcpy((sb + layout.msg_payload)[0..payload.len], payload);
        @atomicStore(u64, slotFct(sb), ~@as(u64, claimed_ct), .release);
        self.rd_waiter.broadcast();
        return true;
    }

    // --- Recv (multi-consumer): f_ct_ emptiness test + slot-free -------------

    pub fn recv(self: *ChannelInner, deadline_ns: i128) Error!?[]u8 {
        const base = self.ring.ptr();
        var yk: u32 = 0;
        while (true) {
            const cur = self.read_cursor;
            const sb = slotBase(base, cur % layout.ring_size);
            const fct = @atomicLoad(u64, slotFct(sb), .acquire);
            if (fct != ~@as(u64, cur)) {
                // Empty — the sender hasn't published this cursor's commit flag.
                if (layout.nowNs() >= deadline_ns) return null;
                layout.adaptiveYield(&yk);
                continue;
            }
            yk = 0;

            const h = layout.readMsgHeader(sb);
            const is_self = h.cc_id == self.cc_id;
            const r_size: i32 = @as(i32, @intCast(layout.data_length)) + h.remain;
            const keep = !is_self and r_size > 0;

            var storage_id: ?i32 = null;
            var frag: ?[]u8 = null;
            if (keep) {
                if (h.storage) {
                    storage_id = layout.i32ptr(sb, layout.msg_payload).*;
                } else {
                    const n: usize = if (h.remain <= 0) @intCast(r_size) else layout.data_length;
                    const f = try self.alloc.alloc(u8, n);
                    @memcpy(f, (sb + layout.msg_payload)[0..n]);
                    frag = f;
                }
            }

            // Consume: clear our rc_ bit (channel inc_rc protocol); the last
            // reader frees the slot by setting f_ct_ to the next-lap ct value.
            const cur_post = cur +% 1;
            const free_flag: u64 = @as(u64, cur_post) + (layout.ring_size - 1);
            const rc_p = slotRc(sb);
            var k: u32 = 0;
            while (true) {
                const cur_rc = @atomicLoad(u64, rc_p, .acquire);
                if ((cur_rc & rc_mask) == 0) {
                    @atomicStore(u64, slotFct(sb), free_flag, .release);
                    break;
                }
                const nxt_rc = incRc(cur_rc) & ~@as(u64, self.conn_id);
                if ((nxt_rc & rc_mask) == 0) @atomicStore(u64, slotFct(sb), free_flag, .release);
                if (@cmpxchgWeak(u64, rc_p, cur_rc, nxt_rc, .release, .monotonic) == null) break;
                layout.adaptiveYield(&k);
            }
            self.read_cursor = cur_post;
            self.wt_waiter.broadcast();

            if (!keep) continue;

            if (storage_id) |sid| {
                const msg_size: usize = @intCast(r_size);
                const out = try self.readStorage(sid, msg_size);
                if (out) |b| return b;
                continue;
            }

            const f = frag.?;
            if (self.recv_cache.fetchRemove(h.id)) |kv| {
                var entry = kv.value;
                @memcpy(entry.buf[entry.offset .. entry.offset + f.len], f);
                entry.offset += f.len;
                self.alloc.free(f);
                if (h.remain <= 0) return entry.buf;
                try self.recv_cache.put(h.id, entry);
            } else if (h.remain <= 0) {
                return f;
            } else {
                const buf = try self.alloc.alloc(u8, @intCast(r_size));
                @memcpy(buf[0..f.len], f);
                self.alloc.free(f);
                try self.recv_cache.put(h.id, .{ .offset = f.len, .buf = buf });
            }
        }
    }

    fn readStorage(self: *ChannelInner, sid: i32, msg_size: usize) Error!?[]u8 {
        const chunk_size = chunk.calcChunkSize(msg_size);
        const handle = try self.chunkShm(chunk_size);
        const base = handle.ptr();
        defer chunk.recycle(base, chunk_size, sid, self.conn_id);
        const p = chunk.payloadPtr(base, chunk_size, sid) orelse return null;
        const out = try self.alloc.alloc(u8, msg_size);
        @memcpy(out, p[0..msg_size]);
        return out;
    }

    fn chunkShm(self: *ChannelInner, chunk_size: usize) Error!ShmHandle {
        if (self.chunk_shms.get(chunk_size)) |h| return h;
        var nbuf: [256]u8 = undefined;
        const h = try ShmHandle.acquire(shmname.chunkShmName(&nbuf, self.prefix, chunk_size), chunk.chunkShmSize(chunk_size), .create_or_open);
        try self.chunk_shms.put(chunk_size, h);
        return h;
    }
};

test "channel ring constants" {
    try std.testing.expectEqual(@as(usize, 24832), ring_user_size);
    try std.testing.expectEqual(@as(usize, 96), elem_stride);
    // inc_rc rolls the internal read-generation (bits 32..55), leaving the top
    // byte (epoch) and low 32 (connection bits) untouched.
    try std.testing.expectEqual(@as(u64, 0x0000_0001_0000_0000), incRc(0));
    try std.testing.expectEqual(@as(u64, 0xAB00_0002_0000_00FF), incRc(0xAB00_0001_0000_00FF));
}
