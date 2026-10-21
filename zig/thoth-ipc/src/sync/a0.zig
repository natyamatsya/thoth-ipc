// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Linux inter-process mutex + condition core — a native Zig port of the
// alephzero (a0) robust PI futex mutex/condition the C++ Linux backend runs
// (`cpp/thoth-ipc/src/thoth-ipc/platform/linux/a0/mtx.c` + `ftx.h`; sync ABI
// backend id 5 = `linux_a0`), following the Rust port in
// rust/thoth-ipc/src/platform/linux.rs.
//
// Nothing is shared with C++ but the bytes and the kernel protocol. Both are
// fixed by abi/abi.json:
//   a0_mtx (24 B on LP64): next @0, prev @8   protocol `robust-list`
//                          ftx  @16 (u32)      protocol `pi-futex`
//   a0_cnd (4 B):          seq  @0  (u32)      protocol `requeue-pi-cond`
//
// The a0 protocol, in short:
//   * mutex word `ftx`: 0 = unlocked, else holder TID | FUTEX_WAITERS |
//     FUTEX_OWNER_DIED. Uncontended lock/unlock is a CAS 0<->tid; contention
//     goes to the kernel's priority-inheriting FUTEX_LOCK_PI / FUTEX_UNLOCK_PI,
//     which only accept the TID of the owning *thread* (error-checking mutex).
//   * robustness: every held mutex is linked through `next`/`prev` into the
//     holding thread's kernel robust list (set_robust_list), with
//     `list_op_pending` covering the window around each operation. When a
//     thread dies the kernel walks that list and sets FUTEX_OWNER_DIED on every
//     futex still holding its TID; the next locker takes it over owner-died.
//   * condition: a sequence word. A waiter reads it, unlocks, and sleeps in
//     FUTEX_WAIT_REQUEUE_PI; a waker bumps it and FUTEX_CMP_REQUEUE_PI moves the
//     sleepers onto the mutex futex, so they wake already owning the mutex. The
//     kernel rejects a plain FUTEX_WAKE for such a sleeper, so every wake needs
//     the paired mutex.
//
// Deadlines are absolute CLOCK_BOOTTIME timespecs (C++ `make_timespec`),
// converted per call to the clock each futex op takes: CLOCK_REALTIME for
// FUTEX_LOCK_PI, CLOCK_MONOTONIC for FUTEX_WAIT_REQUEUE_PI (`ftx.h`).
//
// a0 keeps every held mutex on the calling thread's robust list *at the address
// it was locked at*: a mutex must be unlocked before its mapping is dropped, and
// all threads of a process must share one mapping per name. Like C++ a0,
// registering this robust list replaces the C library's own.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("../abi_generated.zig");

const Atomic = std.atomic.Value;
const timespec = linux.timespec;

// --- Kernel ABI (<linux/futex.h>) -------------------------------------------

const futex_tid_mask: u32 = 0x3fff_ffff;
const futex_owner_died: u32 = 0x4000_0000;
/// a0's "unrecoverable" marker: what unlocking a never-made-consistent mutex
/// leaves in `ftx`.
const ftx_notrecoverable: u32 = futex_tid_mask | futex_owner_died;

/// `struct robust_list`.
const RobustList = extern struct {
    next: ?*RobustList,
};

/// `struct robust_list_head`: the per-thread list the kernel walks on exit.
const RobustListHead = extern struct {
    list: RobustList,
    futex_offset: c_long,
    list_op_pending: ?*RobustList,
};

/// `struct a0_mtx_s` (`a0/mtx.h`). It "inherits" `struct robust_list`: `next`
/// must be the first field, and the robust-list head's `futex_offset` is the
/// offset of `ftx`. `next`/`prev` are only ever touched by the holding thread.
pub const Mtx = extern struct {
    next: ?*Mtx,
    prev: ?*Mtx,
    ftx: Atomic(u32),
};

/// `a0_cnd_t` = `a0_ftx_t` = `uint32_t`: the condition's sequence word.
pub const Cnd = Atomic(u32);

comptime {
    // abi.json describes the LP64 layout (x86_64 / aarch64 Linux).
    std.debug.assert(@sizeOf(Mtx) == abi.a0_mtx_size);
    std.debug.assert(@alignOf(Mtx) == abi.a0_mtx_align);
    std.debug.assert(@offsetOf(Mtx, "next") == abi.a0_mtx_next_off);
    std.debug.assert(@offsetOf(Mtx, "prev") == abi.a0_mtx_prev_off);
    std.debug.assert(@offsetOf(Mtx, "ftx") == abi.a0_mtx_ftx_off);
    std.debug.assert(@sizeOf(Cnd) == abi.a0_cnd_size);
    std.debug.assert(@alignOf(Cnd) == abi.a0_cnd_align);
    // The kernel reads the head as `struct robust_list_head`, and a0 compares a
    // list entry against the head's address, which only works because `list`
    // is the head's first field.
    std.debug.assert(@offsetOf(RobustListHead, "list") == 0);
    std.debug.assert(@sizeOf(RobustListHead) == 3 * @sizeOf(usize));
}

pub const Error = error{
    /// The deadline passed before the mutex could be taken.
    Timeout,
    /// The mutex is held (try-lock), by this thread or another.
    WouldBlock,
    /// A previous owner died and it was unlocked without being made consistent.
    NotRecoverable,
    /// The calling thread is not the mutex's owner.
    NotOwner,
    /// The calling thread already holds the mutex (relocking a PI futex).
    Deadlock,
    /// An argument (a deadline, or `consistent` on a healthy mutex) is invalid.
    InvalidArgument,
    Unexpected,
};

/// How a lock (or a condition wait's relock) was obtained. Either way the
/// calling thread now holds the mutex.
pub const Acquired = enum {
    clean,
    /// Taken over from a dead owner. The protected state may be inconsistent;
    /// call `consistent` before unlocking or the mutex becomes unrecoverable.
    owner_died,
};

/// The outcome of a condition wait. The mutex is held again in every case.
pub const Wake = enum { signalled, timed_out, owner_died };

fn errorFrom(e: linux.E) Error {
    return switch (e) {
        .TIMEDOUT => error.Timeout,
        .BUSY, .AGAIN => error.WouldBlock,
        .NOTRECOVERABLE => error.NotRecoverable,
        .PERM => error.NotOwner,
        .DEADLK => error.Deadlock,
        .INVAL => error.InvalidArgument,
        else => error.Unexpected,
    };
}

// --- Per-thread state: robust-list head, init flag, cached TID ----------------
//
// The kernel reads the robust-list head during thread exit, after every TLS
// destructor has run. A `threadlocal` without a destructor lives in the
// thread's static TLS block, freed with the stack only once the kernel has
// finished the exit — the same storage a0's `A0_THREAD_LOCAL` head has.

threadlocal var robust_head: RobustListHead = .{
    .list = .{ .next = null },
    .futex_offset = 0,
    .list_op_pending = null,
};
threadlocal var robust_registered: bool = false;
threadlocal var tid_cache: u32 = 0;

var atfork_registered: Atomic(bool) = .init(false);

/// pthread_atfork child handler (a0 `a0_robust_reset` + `a0_tid_reset`): the
/// child's only thread has a new TID, and the kernel does not carry robust-list
/// registrations across fork, so both are redone on the next operation.
fn resetAfterFork() callconv(.c) void {
    robust_registered = false;
    tid_cache = 0;
}

fn registerAtfork() void {
    if (atfork_registered.swap(true, .acq_rel)) return;
    _ = std.c.pthread_atfork(null, null, resetAfterFork);
}

/// `a0_tid`: the calling thread's kernel TID, cached per thread.
fn tid() u32 {
    if (tid_cache == 0) {
        tid_cache = @bitCast(linux.gettid());
        registerAtfork();
    }
    return tid_cache;
}

// --- Robust-list bookkeeping (mtx.c robust_*) ---------------------------------

/// a0_barrier (`__sync_synchronize`): a SIGKILL can land on any instruction, so
/// the stores the kernel will read must be ordered as written. Zig has no
/// standalone fence; a seq_cst RMW is one.
inline fn barrier() void {
    var word: Atomic(u32) = .init(0);
    _ = word.fetchAdd(0, .seq_cst);
}

fn registerRobustList() void {
    if (robust_registered) return;
    registerAtfork();
    robust_head = .{
        .list = .{ .next = &robust_head.list },
        .futex_offset = @offsetOf(Mtx, "ftx"),
        .list_op_pending = null,
    };
    _ = linux.syscall2(.set_robust_list, @intFromPtr(&robust_head), @sizeOf(RobustListHead));
    robust_registered = true;
}

fn isHead(mtx: ?*Mtx) bool {
    return @intFromPtr(mtx) == @intFromPtr(&robust_head);
}

/// Mark `mtx` as the operation in flight (`robust_op_start`), so a death
/// mid-operation still has the kernel inspect it.
fn opStart(mtx: *Mtx) void {
    registerRobustList();
    robust_head.list_op_pending = @ptrCast(mtx);
    barrier();
}

fn opEnd() void {
    barrier();
    robust_head.list_op_pending = null;
}

/// `robust_op_add`: push `mtx` at the front of this thread's list. The head is
/// addressed as a `Mtx` only through `next` (offset 0 in both structs).
fn opAdd(mtx: *Mtx) void {
    const old_first: ?*Mtx = @ptrCast(robust_head.list.next);
    mtx.prev = @ptrCast(&robust_head);
    mtx.next = old_first;
    barrier();
    robust_head.list.next = @ptrCast(mtx);
    if (!isHead(old_first)) old_first.?.prev = mtx;
}

/// `robust_op_del`: unlink `mtx` from this thread's list.
fn opDel(mtx: *Mtx) void {
    const prev = mtx.prev.?;
    prev.next = mtx.next;
    if (!isHead(mtx.next)) mtx.next.?.prev = prev;
}

fn ownerTid(word: u32) u32 {
    return word & futex_tid_mask;
}
fn ownerDied(word: u32) bool {
    return word & futex_owner_died != 0;
}
fn notRecoverable(word: u32) bool {
    return word & ftx_notrecoverable == ftx_notrecoverable;
}

// --- Clocks (a0 clock.h) ------------------------------------------------------

fn clockNow(clock: linux.clockid_t) timespec {
    var ts: timespec = undefined;
    // Only fails for an invalid clock id or pointer; neither can happen here.
    std.debug.assert(linux.errno(linux.clock_gettime(clock, &ts)) == .SUCCESS);
    return ts;
}

fn toNs(ts: timespec) i128 {
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn fromNs(ns: i128) timespec {
    return .{
        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

/// `a0_clock_convert`: the same remaining time, re-anchored on `target`.
fn convertDeadline(deadline: timespec, target: linux.clockid_t) timespec {
    const remaining = toNs(deadline) - toNs(clockNow(.BOOTTIME));
    return fromNs(toNs(clockNow(target)) + remaining);
}

/// `linux_::detail::make_timespec`: an absolute CLOCK_BOOTTIME deadline
/// `timeout_ns` from now.
pub fn deadlineIn(timeout_ns: u64) timespec {
    return fromNs(toNs(clockNow(.BOOTTIME)) + timeout_ns);
}

// --- Futex ops (a0 ftx.h). Shared (non-private) futexes: the words live in shm.

fn futex(
    word: *Atomic(u32),
    cmd: linux.FUTEX_COMMAND,
    val: u32,
    param4: linux.futex_param4,
    word2: ?*Atomic(u32),
    val3: u32,
) linux.E {
    const op: linux.FUTEX_OP = .{ .cmd = cmd, .private = false };
    return linux.errno(linux.futex(&word.raw, op, val, param4, if (word2) |w| &w.raw else null, val3));
}

/// `a0_ftx_lock_pi`: FUTEX_LOCK_PI takes an absolute CLOCK_REALTIME timeout.
fn lockPi(ftx: *Atomic(u32), deadline: ?timespec) linux.E {
    const d = deadline orelse return futex(ftx, .LOCK_PI, 0, .{ .timeout = null }, null, 0);
    const wall = convertDeadline(d, .REALTIME);
    return futex(ftx, .LOCK_PI, 0, .{ .timeout = &wall }, null, 0);
}

/// `a0_ftx_wait_requeue_pi`: FUTEX_WAIT_REQUEUE_PI takes an absolute
/// CLOCK_MONOTONIC timeout.
fn waitRequeuePi(cnd: *Cnd, expected: u32, deadline: ?timespec, ftx: *Atomic(u32)) linux.E {
    const d = deadline orelse return futex(cnd, .WAIT_REQUEUE_PI, expected, .{ .timeout = null }, ftx, 0);
    const mono = convertDeadline(d, .MONOTONIC);
    return futex(cnd, .WAIT_REQUEUE_PI, expected, .{ .timeout = &mono }, ftx, 0);
}

// --- a0 mutex (mtx.c) ---------------------------------------------------------

/// `a0_mtx_timedlock_robust`: CAS fast path, else FUTEX_LOCK_PI (retried on
/// EINTR).
fn lockRobust(mtx: *Mtx, deadline: ?timespec) Error!Acquired {
    const me = tid();
    while (true) {
        // Can't lock if borked.
        if (notRecoverable(mtx.ftx.load(.monotonic))) return error.NotRecoverable;
        // Try to lock without kernel involvement.
        if (mtx.ftx.cmpxchgStrong(0, me, .seq_cst, .seq_cst) == null) return .clean;
        // Ask the kernel to lock.
        switch (lockPi(&mtx.ftx, deadline)) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| return errorFrom(e),
        }
    }
    return if (ownerDied(mtx.ftx.load(.monotonic))) .owner_died else .clean;
}

/// `a0_mtx_timedlock` (`a0_mtx_lock` for a null deadline).
pub fn lock(mtx: *Mtx, deadline: ?timespec) Error!Acquired {
    opStart(mtx);
    defer opEnd();
    const how = try lockRobust(mtx, deadline);
    opAdd(mtx);
    return how;
}

/// `a0_mtx_trylock`: CAS, and FUTEX_TRYLOCK_PI only to take over from a dead
/// owner. The C++ wrapper's try_lock is a zero-deadline timed lock instead, so
/// only the tests call this; it is kept so the whole a0 surface is ported.
pub fn tryLock(mtx: *Mtx) Error!Acquired {
    opStart(mtx);
    defer opEnd();
    // Try to lock without kernel involvement.
    const old = mtx.ftx.cmpxchgStrong(0, tid(), .seq_cst, .seq_cst) orelse {
        opAdd(mtx);
        return .clean;
    };
    // Is the lock still usable?
    if (notRecoverable(old)) return error.NotRecoverable;
    // Is the owner still alive?
    if (!ownerDied(old)) return error.WouldBlock;
    // Oh, the owner died. Ask the kernel to fix the state.
    switch (futex(&mtx.ftx, .TRYLOCK_PI, 0, .{ .timeout = null }, null, 0)) {
        .SUCCESS => {},
        // EAGAIN means that somebody else beat us to it.
        .AGAIN => return error.WouldBlock,
        // Anything else means we're borked.
        else => return error.NotRecoverable,
    }
    opAdd(mtx);
    return if (ownerDied(mtx.ftx.load(.monotonic))) .owner_died else .clean;
}

/// `a0_mtx_consistent`: the owner of an `.owner_died` mutex clears the flag.
pub fn consistent(mtx: *Mtx) Error!void {
    const word = mtx.ftx.load(.monotonic);
    // Why fix what isn't broken?
    if (!ownerDied(word)) return error.InvalidArgument;
    // Is it yours to fix?
    if (ownerTid(word) != tid()) return error.NotOwner;
    _ = mtx.ftx.fetchAnd(~futex_owner_died, .monotonic);
}

/// `a0_mtx_unlock`: owner only. Unlocking while still owner-died leaves the
/// mutex unrecoverable, as a0 does.
pub fn unlock(mtx: *Mtx) Error!void {
    const me = tid();
    const word = mtx.ftx.load(.monotonic);

    // Only the owner can unlock.
    if (ownerTid(word) != me) return error.NotOwner;

    // Acquired owner-died and never made consistent: unrecoverably borked.
    const new_word: u32 = if (ownerDied(word)) ftx_notrecoverable else 0;

    opStart(mtx);
    defer opEnd();
    opDel(mtx);

    // Exactly `tid` means no waiters: the kernel need not get involved.
    if (mtx.ftx.cmpxchgStrong(me, new_word, .seq_cst, .seq_cst) != null) {
        // Ask the kernel to wake up a waiter (a0 ignores the result).
        _ = futex(&mtx.ftx, .UNLOCK_PI, 0, .{ .timeout = null }, null, 0);
        if (new_word != 0) _ = mtx.ftx.fetchOr(new_word, .monotonic);
    }
}

// --- a0 condition (mtx.c a0_cnd_*). The caller holds `mtx`. ------------------

/// `a0_cnd_timedwait`: release `mtx`, sleep until woken or `deadline`, and
/// return holding `mtx` again. Unlike C++ (which reads it as success), an
/// owner-died relock is reported so the caller can make the mutex consistent.
pub fn wait(cnd: *Cnd, mtx: *Mtx, deadline: ?timespec) Error!Wake {
    // Don't unlock for a deadline that cannot be waited on.
    if (deadline) |d| if (d.sec < 0 or d.nsec < 0 or d.nsec >= std.time.ns_per_s or (d.sec == 0 and d.nsec == 0))
        return error.InvalidArgument;

    const seq = cnd.load(.monotonic);

    // Unblock other threads to do the things that will eventually signal this wait.
    try unlock(mtx);

    opStart(mtx);
    defer opEnd();

    // Priority-inheritance-aware wait until awoken or timeout.
    var woke: linux.E = undefined;
    while (true) {
        woke = waitRequeuePi(cnd, seq, deadline, &mtx.ftx);
        if (woke != .INTR) break;
    }

    const result: Wake = switch (woke) {
        // Requeued and woken: the kernel handed us the mutex.
        .SUCCESS => if (ownerDied(mtx.ftx.load(.monotonic))) .owner_died else .signalled,
        // We need to manually relock on timeout.
        .TIMEDOUT => blk: {
            _ = try lockRobust(mtx, null);
            break :blk .timed_out;
        },
        // Someone else grabbed and mutated the resource between the unlock and
        // the wait. No need to wait.
        .AGAIN => switch (try lockRobust(mtx, null)) {
            .clean => .signalled,
            .owner_died => .owner_died,
        },
        else => |e| return errorFrom(e),
    };
    opAdd(mtx);
    return result;
}

/// `a0_cnd_signal`: wake one waiter, requeued onto `mtx`.
pub fn signal(cnd: *Cnd, mtx: *Mtx) Error!void {
    return wake(cnd, mtx, 1);
}

/// `a0_cnd_broadcast`: wake every waiter, requeued onto `mtx`.
pub fn broadcast(cnd: *Cnd, mtx: *Mtx) Error!void {
    return wake(cnd, mtx, std.math.maxInt(i32));
}

/// `a0_cnd_wake`: bump the sequence, then requeue the sleepers onto the mutex
/// futex (waking one, the only count the kernel accepts); AGAIN means another
/// waker moved the sequence, so retry with it.
fn wake(cnd: *Cnd, mtx: *Mtx, max_requeue: u32) Error!void {
    var seq = cnd.fetchAdd(1, .monotonic) +% 1;
    while (true) {
        switch (futex(cnd, .CMP_REQUEUE_PI, 1, .{ .val2 = max_requeue }, &mtx.ftx, seq)) {
            .SUCCESS => return,
            .AGAIN => seq = cnd.load(.monotonic),
            else => |e| return errorFrom(e),
        }
    }
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

test "the robust list tracks a held mutex" {
    var m = std.mem.zeroes(Mtx);
    try testing.expectEqual(Acquired.clean, try lock(&m, null));
    try testing.expectEqual(@intFromPtr(&m), @intFromPtr(robust_head.list.next));
    try testing.expectEqual(@as(c_long, @offsetOf(Mtx, "ftx")), robust_head.futex_offset);
    try testing.expectEqual(tid(), ownerTid(m.ftx.raw));
    try testing.expectError(error.InvalidArgument, consistent(&m));
    try unlock(&m);
    try testing.expect(isHead(@ptrCast(robust_head.list.next)));
    try testing.expectEqual(0, m.ftx.raw);
    try testing.expectError(error.NotOwner, unlock(&m));
}

test "try-lock contention and owner checks" {
    var m = std.mem.zeroes(Mtx);
    _ = try tryLock(&m);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mp: *Mtx) !void {
            try testing.expectError(error.WouldBlock, tryLock(mp));
            try testing.expectError(error.NotOwner, unlock(mp));
        }
    }.run, .{&m});
    t.join();
    try unlock(&m);
}

test "a dead owner's mutex is taken over" {
    var m = std.mem.zeroes(Mtx);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mp: *Mtx) !void {
            _ = try lock(mp, null); // the thread exits holding it
        }
    }.run, .{&m});
    t.join();
    try testing.expect(ownerDied(m.ftx.raw));
    try testing.expectEqual(Acquired.owner_died, try lock(&m, null));
    try consistent(&m);
    try testing.expectEqual(tid(), m.ftx.raw & ftx_notrecoverable);
    try unlock(&m);
}

test "timed lock and condition wait time out" {
    var m = std.mem.zeroes(Mtx);
    var c: Cnd = .init(0);
    _ = try lock(&m, null);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mp: *Mtx) !void {
            try testing.expectError(error.Timeout, lock(mp, deadlineIn(50 * std.time.ns_per_ms)));
        }
    }.run, .{&m});
    t.join();
    try testing.expectEqual(Wake.timed_out, try wait(&c, &m, deadlineIn(50 * std.time.ns_per_ms)));
    try testing.expectEqual(tid(), ownerTid(m.ftx.raw)); // re-acquired after the timeout
    try unlock(&m);
}

test "a broadcast wakes a waiter holding the mutex" {
    var m = std.mem.zeroes(Mtx);
    var c: Cnd = .init(0);
    var ready: Atomic(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mp: *Mtx, cp: *Cnd, rp: *Atomic(bool)) !void {
            _ = try lock(mp, null);
            rp.store(true, .release);
            try testing.expectEqual(Wake.signalled, try wait(cp, mp, deadlineIn(5 * std.time.ns_per_s)));
            try unlock(mp);
        }
    }.run, .{ &m, &c, &ready });
    while (!ready.load(.acquire)) std.Thread.yield() catch {};
    // Lock+unlock: the waiter has released the mutex, so it is parked.
    _ = try lock(&m, null);
    try unlock(&m);
    try broadcast(&c, &m);
    t.join();
}
