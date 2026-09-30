// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Dead-connection reaper owner table (RFC: context/dead-connection-reaper-rfc.md,
// ABI §9). Byte-exact with cpp/thoth-ipc/src/thoth-ipc/liveness.h and the Rust/Swift
// ports: a per-cc_-bit table of { pid:int32 @0, start_tok:u64 @8 } (16 bytes
// each, 32 slots = 512 bytes) in a dedicated LV_CONN__ segment.
//
// A receiver records its {pid, start_token} on connect so any participant's
// reaper (of any language) can reclaim the slot if the process dies; a receiver
// reaps dead peers on connect. The start-token formula MUST match C++/Rust/Swift
// exactly, or a reaper would compute a mismatched token for a LIVE peer of a
// different language and falsely reap it (the matrix's `reap live` case checks
// precisely this).

const std = @import("std");
const shm = @import("../platform/shm.zig");
const shmname = @import("../platform/shmname.zig");
const layout = @import("layout.zig");
// Slot layout (size + field offsets) is generated from abi/abi.json by tools/abi.
const abi = @import("../abi_generated.zig");

const ShmHandle = shm.ShmHandle;

pub const max_slots: usize = 32; // one slot per cc_ bit (32-bit connection bitmask)
pub const slot_stride: usize = abi.liveness_slot_size; // sizeof(slot_owner) = 16
const pid_off: usize = abi.liveness_slot_pid_off; // int32 @0
const tok_off: usize = abi.liveness_slot_start_tok_off; // uint64 @8
pub const shm_size_bytes: usize = max_slots * slot_stride; // 512

// Darwin proc_pidinfo — no std.c wrapper; the BSD start time is the process
// incarnation id that defeats PID reuse (ABI §9).
const PROC_PIDTBSDINFO: c_int = 3;
const PROC_BSDINFO_SIZE: c_int = 136;
const PBI_START_TVSEC_OFF: usize = 120; // uint64 in proc_bsdinfo
const PBI_START_TVUSEC_OFF: usize = 128; // uint64 in proc_bsdinfo
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;

pub fn livenessName(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}__THOTH_SHM__LV_CONN__{s}", .{ prefix, name }) catch unreachable;
}

inline fn slotIndex(bit: u32) usize {
    return @ctz(bit);
}
inline fn pidPtr(lv: [*]u8, idx: usize) *u32 {
    return @ptrCast(@alignCast(lv + idx * slot_stride + pid_off));
}
inline fn tokPtr(lv: [*]u8, idx: usize) *u64 {
    return @ptrCast(@alignCast(lv + idx * slot_stride + tok_off));
}

pub fn selfPid() i32 {
    return std.c.getpid();
}

/// Process start token — byte-exact with C++/Rust/Swift: BSD start time packed
/// as tvsec * 1_000_000 + tvusec. 0 == "couldn't determine".
pub fn startToken(pid: i32) u64 {
    if (pid <= 0) return 0;
    var info: [136]u8 = undefined;
    const n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, PROC_BSDINFO_SIZE);
    if (n != PROC_BSDINFO_SIZE) return 0;
    const tvsec = std.mem.readInt(u64, info[PBI_START_TVSEC_OFF..][0..8], .little);
    const tvusec = std.mem.readInt(u64, info[PBI_START_TVUSEC_OFF..][0..8], .little);
    return tvsec *% 1_000_000 +% tvusec;
}

// Darwin sysctl — the kinfo_proc image read for the zombie check.
const CTL_KERN: c_int = 1;
const KERN_PROC: c_int = 14;
const KERN_PROC_PID: c_int = 1;
const KINFO_PROC_SIZE: usize = 648; // sizeof(struct kinfo_proc), arm64 and x86_64
const P_STAT_OFF: usize = 36; // kp_proc (@0) .p_stat
const SZOMB: u8 = 5;
extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;

/// Whether `pid` is a zombie: it has exited and only waits for its parent to
/// reap it, which may never happen (e.g. a parent that cannot wait for a child a
/// debugger traces). A zombie holds nothing, but kill(pid, 0) still succeeds for
/// it and its start token can no longer be read, so without this check it would
/// count as alive for as long as its parent lives. Byte-exact with C++ is_zombie
/// (liveness.h): sysctl KERN_PROC_PID (what ps reads; proc_pidinfo fails for
/// zombies), kp_proc.p_stat == SZOMB.
pub fn isZombie(pid: i32) bool {
    if (pid <= 0) return false;
    var mib = [_]c_int{ CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    var buf: [KINFO_PROC_SIZE]u8 = undefined;
    var len: usize = KINFO_PROC_SIZE;
    if (sysctl(&mib, 4, &buf, &len, null, 0) != 0 or len != KINFO_PROC_SIZE) return false;
    return buf[P_STAT_OFF] == SZOMB;
}

/// Is the recorded process (pid + token) still alive? Conservative: any
/// "can't determine" answer errs toward ALIVE so a live peer is never false-reaped.
fn isProcessAlive(pid: i32, tok: u64) bool {
    if (pid <= 0) return false;
    const rc = std.c.kill(pid, @enumFromInt(0)); // signal 0: existence check
    const esrch = @intFromEnum(std.c.E.SRCH);
    const exists = rc == 0 or std.c._errno().* != esrch;
    if (!exists) return false; // definitely gone
    if (isZombie(pid)) return false; // exited, just not reaped yet
    if (tok == 0) return true; // no recorded token → token-less fallback
    const cur = startToken(pid);
    if (cur == 0) return true; // couldn't read → don't risk a false reap
    return cur == tok; // mismatch ⇒ PID reused ⇒ our owner is gone
}

/// Record ownership of a freshly connected slot (after the cc_ bit is claimed).
pub fn setOwner(lv: [*]u8, bit: u32) void {
    if (bit == 0) return;
    const idx = slotIndex(bit);
    // Token first, then pid with release: a reader that sees our pid sees the token.
    @atomicStore(u64, tokPtr(lv, idx), startToken(selfPid()), .monotonic);
    @atomicStore(u32, pidPtr(lv, idx), @bitCast(selfPid()), .release);
}

/// Release ownership of a slot on clean disconnect.
pub fn clearOwner(lv: [*]u8, bit: u32) void {
    if (bit == 0) return;
    const idx = slotIndex(bit);
    @atomicStore(u32, pidPtr(lv, idx), 0, .release);
    @atomicStore(u64, tokPtr(lv, idx), 0, .monotonic);
}

/// Reap the dead receivers among `live`, clearing each dead bit from `cc`.
/// Lock-free (CAS-on-owner). Returns the reaped mask.
pub fn reapDeadReceivers(lv: [*]u8, live: u32, cc: *u32) u32 {
    var reaped: u32 = 0;
    var m = live;
    while (m != 0) {
        const bit = m & (~m +% 1); // lowest set bit
        m &= m -% 1;
        const idx = slotIndex(bit);
        const pp = pidPtr(lv, idx);
        const p = @atomicLoad(u32, pp, .acquire);
        if (p == 0) continue; // unknown owner — never false-reap
        const tok = @atomicLoad(u64, tokPtr(lv, idx), .monotonic);
        if (isProcessAlive(@bitCast(p), tok)) continue;
        // Only reap if the owner is still the dead PID we saw.
        if (@cmpxchgStrong(u32, pp, p, 0, .acq_rel, .monotonic) == null) {
            @atomicStore(u64, tokPtr(lv, idx), 0, .monotonic);
            _ = @atomicRmw(u32, cc, .And, ~bit, .acq_rel);
            reaped |= bit;
        }
    }
    return reaped;
}

// --- Sole-owner claim (a route's single-sender guard; xlang-channel-abi.md §2a)

/// `pid` of a sole-owner record whose claim is in flight: never taken over.
pub const owner_claiming: i32 = -1;

/// Claim a sole-owner record (one `slot_owner` at `o`) for this process: free,
/// or held by a dead process. False when a live process (this one included)
/// holds it, or a claim is in flight. Byte-exact with C++ `claim_sole_owner`
/// (liveness.h): CAS the pid to `owner_claiming` first, so no claimant can pair
/// the new pid with the previous holder's token; then the token, then the pid.
pub fn claimSoleOwner(o: [*]u8) bool {
    const pp = pidPtr(o, 0);
    const tp = tokPtr(o, 0);
    const cur: i32 = @bitCast(@atomicLoad(u32, pp, .acquire));
    if (cur == owner_claiming) return false;
    if (cur != 0 and isProcessAlive(cur, @atomicLoad(u64, tp, .acquire))) return false;
    if (@cmpxchgStrong(u32, pp, @bitCast(cur), @bitCast(owner_claiming), .acq_rel, .monotonic) != null) return false;
    @atomicStore(u64, tp, startToken(selfPid()), .monotonic);
    @atomicStore(u32, pp, @bitCast(selfPid()), .release);
    return true;
}

/// Release a sole-owner record this process holds (a clean shutdown).
pub fn releaseSoleOwner(o: [*]u8) void {
    const pp = pidPtr(o, 0);
    const me: u32 = @bitCast(selfPid());
    if (@atomicLoad(u32, pp, .acquire) != me) return;
    @atomicStore(u64, tokPtr(o, 0), 0, .monotonic);
    _ = @cmpxchgStrong(u32, pp, me, 0, .release, .monotonic);
}

test "a zombie is not alive" {
    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) std.c._exit(0);
    // Not waited for: the child is a zombie once it has exited.
    var zombie = false;
    var i: usize = 0;
    while (i < 300 and !zombie) : (i += 1) {
        zombie = isZombie(pid);
        if (!zombie) {
            const ts = std.c.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }
    const alive = isProcessAlive(pid, 0);
    _ = std.c.waitpid(pid, null, 0);
    try std.testing.expect(zombie);
    try std.testing.expect(!alive);
    try std.testing.expect(!isZombie(selfPid()));
}

test "shm size is 512" {
    try std.testing.expectEqual(@as(usize, 512), shm_size_bytes);
}
