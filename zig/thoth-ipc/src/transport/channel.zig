// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// The thoth::route broadcast channel (single-writer, N-reader), ported byte-exact
// from the C++ prod_cons_impl<single,multi,broadcast> (cpp/thoth-ipc/src/thoth-ipc/
// prod_cons.h) and the Swift port (swift/thoth-ipc/.../Transport/Channel.swift).
// See context/xlang-channel-abi.md §5/§6/§6a/§6b.
//
// v1 scope: the mandatory core transport (sync + fanout scenarios). No named
// waiter (readers busy-poll the write cursor) and no LV_CONN__ liveness table
// (unpopulated slots are "safe by default" — a reaping peer skips pid==0), which
// are deferred to the reap phase. Large (>64B) messages are read via the
// receive-side chunk-storage decoder; this port's sender fragments.

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

pub const nowNs = layout.nowNs;
pub const sleepNs = layout.sleepNs;

pub const Mode = enum { sender, receiver };

pub const Error = error{
    ConnectFailed,
    SendFailed,
    Full,
    OutOfMemory,
} || shm.ShmError;

const Frag = struct { offset: usize, buf: []u8 };

pub const ChanInner = struct {
    alloc: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
    mode: Mode,
    ring: ShmHandle,
    ccid: ShmHandle,
    liveness_shm: ShmHandle, // LV_CONN__ owner table (dead-connection reaper)
    conn_id: u32 = 0,
    cc_id: u32 = 0,
    read_cursor: u32 = 0,
    send_seq: u32 = 0,
    recv_cache: std.AutoHashMap(u32, Frag),
    chunk_shms: std.AutoHashMap(usize, ShmHandle),
    // RD/WT/CC condition-variable waiters. This port busy-polls, so we only ever
    // signal them — to wake a blocked C++/Rust/Swift peer (reader parked when the
    // ring looks empty, sender parked when it looks full).
    rd_waiter: Waiter,
    wt_waiter: Waiter,
    cc_waiter: Waiter,
    disconnected: bool = false,

    pub fn open(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8, mode: Mode) Error!ChanInner {
        var rbuf: [256]u8 = undefined;
        var cbuf: [256]u8 = undefined;
        var ring = try ShmHandle.acquire(shmname.ringName(&rbuf, prefix, name), layout.ring_user_size, .create_or_open);
        errdefer ring.release();
        var ccid = try ShmHandle.acquire(shmname.ccIdName(&cbuf, prefix), 4, .create_or_open);
        errdefer ccid.release();
        var lbuf: [256]u8 = undefined;
        var liveness_shm = try ShmHandle.acquire(liveness.livenessName(&lbuf, prefix, name), liveness.shm_size_bytes, .create_or_open);
        errdefer liveness_shm.release();
        var rd_waiter = try Waiter.open(prefix, name, "RD_CONN__");
        errdefer rd_waiter.release();
        var wt_waiter = try Waiter.open(prefix, name, "WT_CONN__");
        errdefer wt_waiter.release();
        var cc_waiter = try Waiter.open(prefix, name, "CC_CONN__");
        errdefer cc_waiter.release();

        const base = ring.ptr();
        layout.initHeader(base); // byte-exact DCLP so a C++ peer does not re-zero the header

        // Allocate a unique endpoint identity from the prefix-global counter
        // (C++ cc_acc: fetch_add(1)+1, never 0).
        const counter: *u32 = @ptrCast(@alignCast(ccid.ptr()));
        var cc_id = @atomicRmw(u32, counter, .Add, 1, .monotonic) +% 1;
        if (cc_id == 0) cc_id = @atomicRmw(u32, counter, .Add, 1, .monotonic) +% 1;

        var self = ChanInner{
            .alloc = alloc,
            .prefix = prefix,
            .name = name,
            .mode = mode,
            .ring = ring,
            .ccid = ccid,
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
            // Reclaim slots held by dead peers before claiming one (byte-exact
            // reap-on-connect; safe by default — an unowned slot is skipped).
            _ = liveness.reapDeadReceivers(lv, @atomicLoad(u32, cc, .acquire), cc);
            var k: u32 = 0;
            while (true) {
                const curr = @atomicLoad(u32, cc, .acquire);
                const next = curr | (curr +% 1);
                if (next == curr) return Error.ConnectFailed; // all 32 slots taken
                if (@cmpxchgWeak(u32, cc, curr, next, .release, .monotonic) == null) {
                    self.conn_id = next ^ curr;
                    break;
                }
                layout.adaptiveYield(&k);
            }
            liveness.setOwner(lv, self.conn_id);
            self.read_cursor = @atomicLoad(u32, layout.u32ptr(base, layout.off_wt), .acquire);
            // Wake any sender parked in waitForRecv (CC waiter).
            self.cc_waiter.broadcast();
        }
        return self;
    }

    pub fn recvCount(self: *ChanInner) usize {
        const cc = @atomicLoad(u32, layout.u32ptr(self.ring.ptr(), layout.off_cc), .acquire);
        return @popCount(cc);
    }

    pub fn disconnect(self: *ChanInner) void {
        if (self.disconnected) return;
        if (self.mode == .receiver) {
            const cc = layout.u32ptr(self.ring.ptr(), layout.off_cc);
            _ = @atomicRmw(u32, cc, .And, ~self.conn_id, .acq_rel);
            liveness.clearOwner(self.liveness_shm.ptr(), self.conn_id);
        }
        self.disconnected = true;
    }

    pub fn deinit(self: *ChanInner) void {
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
        self.ccid.release();
        self.ring.release();
    }

    // --- Send (fragment into msg_t records, C++ ipc.cpp send) ---------------

    pub fn send(self: *ChanInner, data: []const u8, deadline_ns: i128) Error!bool {
        if (data.len == 0) return false;
        const base = self.ring.ptr();
        if (@atomicLoad(u32, layout.u32ptr(base, layout.off_cc), .monotonic) == 0) return false;

        const size = data.len;
        const msg_id = self.send_seq;
        self.send_seq +%= 1;

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
        // Layer 1: wake any async receiver parked on its readiness fd (byte-exact
        // with C++/Rust/Swift notify_post; a no-op if nobody is listening).
        notify.post(self.prefix, self.name);
        return true;
    }

    /// Claim the next ring slot (C++ broadcast push) and write one msg_t
    /// fragment, then advance wt_. Busy-polls while the target slot is still
    /// being read by a live receiver (v1 has no force_push/reaper eviction —
    /// deferred to the reap phase; in the matrix every reader is alive).
    fn pushFragment(self: *ChanInner, msg_id: u32, remain: i32, payload: []const u8, deadline_ns: i128) Error!bool {
        const base = self.ring.ptr();
        const cc_p = layout.u32ptr(base, layout.off_cc);
        const wt_p = layout.u32ptr(base, layout.off_wt);
        const epoch_p = layout.u64ptr(base, layout.off_epoch);

        var claimed_wt: u32 = 0;
        var yk: u32 = 0;
        claim: while (true) {
            const cc: u64 = @atomicLoad(u32, cc_p, .monotonic);
            if (cc == 0) return false; // no reader
            const epoch = @atomicLoad(u64, epoch_p, .monotonic);
            const wt = @atomicLoad(u32, wt_p, .monotonic);
            const sb = layout.slotBase(base, wt & 0xFF);
            const rc_p = layout.slotRc(sb);
            const cur_rc = @atomicLoad(u64, rc_p, .acquire);
            const rem_cc = cur_rc & layout.ep_mask;
            if ((cc & rem_cc) != 0 and (cur_rc & ~layout.ep_mask) == epoch) {
                // Slot still busy — a live reader has not consumed it yet.
                if (layout.nowNs() >= deadline_ns) return false;
                layout.adaptiveYield(&yk);
                continue :claim;
            }
            if (@cmpxchgWeak(u64, rc_p, cur_rc, epoch | cc, .release, .monotonic) == null) {
                claimed_wt = wt;
                break :claim;
            }
            layout.adaptiveYield(&yk);
        }

        const sb = layout.slotBase(base, claimed_wt & 0xFF);
        layout.writeMsgHeader(sb, .{ .cc_id = self.cc_id, .id = msg_id, .remain = remain, .storage = false });
        @memcpy((sb + layout.msg_payload)[0..payload.len], payload);
        _ = @atomicRmw(u32, wt_p, .Add, 1, .release);
        self.rd_waiter.broadcast(); // wake a reader parked on the empty ring
        return true;
    }

    // --- Recv (reassemble msg_t fragments by id_, C++ ipc.cpp recv) ---------

    /// Receive one full message. Returns an allocated slice the caller must free,
    /// or null on timeout. Large (storage_) messages are read from chunk shm.
    pub fn recv(self: *ChanInner, deadline_ns: i128) Error!?[]u8 {
        const base = self.ring.ptr();
        const wt_p = layout.u32ptr(base, layout.off_wt);
        var yk: u32 = 0;
        while (true) {
            const wc = @atomicLoad(u32, wt_p, .acquire);
            if (wc == self.read_cursor) {
                if (layout.nowNs() >= deadline_ns) return null;
                layout.adaptiveYield(&yk);
                continue;
            }
            yk = 0;

            const idx: usize = self.read_cursor & 0xFF;
            const sb = layout.slotBase(base, idx);
            const h = layout.readMsgHeader(sb);
            const is_self = h.cc_id == self.cc_id;
            const r_size: i32 = @as(i32, @intCast(layout.data_length)) + h.remain;
            const keep = !is_self and r_size > 0;

            // Read out of the slot BEFORE releasing it.
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

            // Release our rc_ bit (preserve epoch), advance the cursor — always.
            const rc_p = layout.slotRc(sb);
            var k: u32 = 0;
            while (true) {
                const cur_rc = @atomicLoad(u64, rc_p, .acquire);
                if ((cur_rc & layout.ep_mask) == 0) break;
                if (@cmpxchgWeak(u64, rc_p, cur_rc, cur_rc & ~@as(u64, self.conn_id), .release, .monotonic) == null) break;
                layout.adaptiveYield(&k);
            }
            self.read_cursor +%= 1;
            self.wt_waiter.broadcast(); // wake a sender parked on the full ring

            if (!keep) continue;

            // Large message via chunk storage (single msg_t — no reassembly).
            if (storage_id) |sid| {
                const msg_size: usize = @intCast(r_size);
                const out = try self.readStorage(sid, msg_size);
                if (out) |b| return b;
                continue;
            }

            // Inline fragment reassembly keyed by id_.
            const f = frag.?;
            if (self.recv_cache.fetchRemove(h.id)) |kv| {
                var entry = kv.value;
                @memcpy(entry.buf[entry.offset .. entry.offset + f.len], f);
                entry.offset += f.len;
                self.alloc.free(f);
                if (h.remain <= 0) {
                    return entry.buf;
                }
                try self.recv_cache.put(h.id, entry);
            } else if (h.remain <= 0) {
                return f; // single fragment
            } else {
                const buf = try self.alloc.alloc(u8, @intCast(r_size));
                @memcpy(buf[0..f.len], f);
                self.alloc.free(f);
                try self.recv_cache.put(h.id, .{ .offset = f.len, .buf = buf });
            }
        }
    }

    fn readStorage(self: *ChanInner, sid: i32, msg_size: usize) Error!?[]u8 {
        const chunk_size = chunk.calcChunkSize(msg_size);
        const handle = try self.chunkShm(chunk_size);
        const base = handle.ptr();
        defer chunk.recycle(base, chunk_size, sid, self.conn_id);
        const p = chunk.payloadPtr(base, chunk_size, sid) orelse return null;
        const out = try self.alloc.alloc(u8, msg_size);
        @memcpy(out, p[0..msg_size]);
        return out;
    }

    fn chunkShm(self: *ChanInner, chunk_size: usize) Error!ShmHandle {
        if (self.chunk_shms.get(chunk_size)) |h| return h;
        var nbuf: [256]u8 = undefined;
        const h = try ShmHandle.acquire(shmname.chunkShmName(&nbuf, self.prefix, chunk_size), chunk.chunkShmSize(chunk_size), .create_or_open);
        try self.chunk_shms.put(chunk_size, h);
        return h;
    }

    pub fn waitForRecv(self: *ChanInner, count: usize, deadline_ns: i128) bool {
        var yk: u32 = 0;
        while (true) {
            if (self.recvCount() >= count) return true;
            if (layout.nowNs() >= deadline_ns) return false;
            layout.adaptiveYield(&yk);
        }
    }
};

/// clearStorage: unlink this channel's ring and its per-channel AC_CONN__ msg-id
/// counter. The CA_CONN__ cc_id counter and the CHUNK_INFO__<size> chunk pools
/// are prefix-global (shared by every channel of this prefix), so a per-channel
/// clear must NOT unlink them — byte-exact with C++ route::clear_storage, which
/// clears neither. (Unlinking a live shared chunk pool splits a concurrent
/// channel's writer and reader across inodes; see the secure-scenario flake.)
pub fn clearStorage(prefix: []const u8, name: []const u8) void {
    var rbuf: [256]u8 = undefined;
    shm.ShmHandle.clearStorage(shmname.ringName(&rbuf, prefix, name));
    var abuf: [256]u8 = undefined;
    shm.ShmHandle.clearStorage(shmname.acConnName(&abuf, prefix, name));
    var lbuf: [256]u8 = undefined;
    shm.ShmHandle.clearStorage(liveness.livenessName(&lbuf, prefix, name));
}
