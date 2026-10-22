// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Linux inter-process mutex + condition variable — a native Rust port of the
// alephzero (a0) robust PI futex mutex/condition the C++ Linux backend runs
// (`cpp/thoth-ipc/src/thoth-ipc/platform/linux/a0/mtx.c` + `ftx.h`, wrapped by
// `platform/linux/mutex.h` / `condition.h`; sync ABI backend id 5 = `linux_a0`).
//
// Nothing is shared with C++ but the bytes and the kernel protocol, exactly as
// apple.rs ports the C++ ulock mutex. Both are fixed by abi/abi.json:
//   a0_mtx (24 B on LP64): next @0, prev @8   protocol `robust-list`
//                          ftx  @16 (u32)      protocol `pi-futex`
//   a0_cnd (4 B):          seq  @0  (u32)      protocol `requeue-pi-cond`
// and the layouts below are const-asserted against the generated `abi` module.
// Each object lives in named shm `<name>` sized like every C++ sync object
// (`calc_size(payload)`: payload rounded up to 4 + a trailing `atomic<i32>`
// cross-process ref counter); the first opener (ref count was 0) zero-fills the
// payload, as `sync::obj_impl::open` does (`*h_ = A0_EMPTY` when `ref() <= 1`).
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
//     futex still holding its TID; the next locker gets EOWNERDEAD.
//   * condition: a sequence word. A waiter reads it, unlocks, and sleeps in
//     FUTEX_WAIT_REQUEUE_PI; a waker bumps it and FUTEX_CMP_REQUEUE_PI moves the
//     sleepers onto the mutex futex, so they wake already owning the mutex.
//
// Semantics mirrored from the C++ wrappers (`robust_mutex`, `condition`):
//   * `lock`/`lock_timeout`: EOWNERDEAD -> consistent + unlock, then retry (the
//     `robust_mutex::lock` loop), so a dead holder's lock is recovered and
//     re-acquired by the caller.
//   * `try_lock` is a timed lock with deadline "now + 0 ms", as in C++. On
//     EOWNERDEAD the C++ wrapper recovers the same way and then throws; Rust
//     instead retries and reports that result. A try_lock by the thread that
//     already holds the mutex (kernel EDEADLK; C++ throws) is `Ok(false)`.
//   * Timeouts are milliseconds; the deadline is CLOCK_BOOTTIME now + ms
//     (`linux_::detail::make_timespec`), converted per call to the clock each
//     futex op takes: CLOCK_REALTIME for FUTEX_LOCK_PI, CLOCK_MONOTONIC for
//     FUTEX_WAIT_REQUEUE_PI (`ftx.h`). `u32::MAX` ms is `thoth::invalid_value`,
//     i.e. no timeout, exactly as in C++.
//
// a0 keeps every held mutex on the calling thread's robust list *at the address
// it was locked at*. A mutex must therefore be unlocked before its mapping is
// dropped, and all threads of a process must share one mapping per name — the
// process-local shm cache (`posix::cached_shm_acquire`) guarantees the latter,
// as `curr_prog` does in C++. Only one robust list exists per thread: like C++
// a0, registering this one replaces the C library's own (glibc's robust
// pthread mutexes lose owner-died recovery on threads that use these mutexes).

use std::cell::Cell;
use std::io;
use std::mem::{offset_of, size_of};
use std::ptr::{self, addr_of_mut};
use std::sync::atomic::{fence, AtomicU32, Ordering};
use std::sync::{Arc, Once};

use libc::{c_int, c_long, timespec};

use super::posix::{self, CachedShm, PlatformShm};
#[cfg(target_pointer_width = "64")]
use crate::abi_generated as abi;

/// `thoth::invalid_value` (`include/thoth-ipc/def.h`): wait without timeout.
pub(crate) const INFINITE_MS: u64 = u32::MAX as u64;

// ---------------------------------------------------------------------------
// Kernel ABI (<linux/futex.h>). The futex ops come from `libc`; the robust-list
// structs and the futex-word bits are defined here so Android builds too.
// ---------------------------------------------------------------------------

const FUTEX_TID_MASK: u32 = 0x3fff_ffff;
const FUTEX_OWNER_DIED: u32 = 0x4000_0000;
/// a0's "unrecoverable" marker: what unlocking a never-made-consistent mutex
/// leaves in `ftx`.
const FTX_NOTRECOVERABLE: u32 = FUTEX_TID_MASK | FUTEX_OWNER_DIED;
const NS_PER_SEC: i64 = 1_000_000_000;

/// `struct robust_list`.
#[repr(C)]
struct RobustList {
    next: *mut RobustList,
}

/// `struct robust_list_head`: the per-thread list the kernel walks on exit.
#[repr(C)]
struct RobustListHead {
    list: RobustList,
    futex_offset: c_long,
    list_op_pending: *mut RobustList,
}

// ---------------------------------------------------------------------------
// The shared payloads: a0_mtx_t / a0_cnd_t.
// ---------------------------------------------------------------------------

/// `struct a0_mtx_s` (`a0/mtx.h`). It "inherits" `struct robust_list`: `next`
/// must be the first field, and the robust-list head's `futex_offset` is the
/// offset of `ftx`. `next`/`prev` are only ever touched by the holding thread.
#[repr(C)]
pub(crate) struct A0Mtx {
    next: *mut A0Mtx,
    prev: *mut A0Mtx,
    ftx: AtomicU32,
}

/// `a0_cnd_t` = `a0_ftx_t` = `uint32_t`: the condition's sequence word.
type A0Cnd = AtomicU32;

/// `sizeof(a0_mtx_t)` — the sync ABI mutex payload size.
pub(crate) const MUTEX_PAYLOAD_SIZE: usize = size_of::<A0Mtx>();
/// `sizeof(a0_cnd_t)` — the sync ABI condition payload size.
pub(crate) const CONDITION_PAYLOAD_SIZE: usize = size_of::<A0Cnd>();

// abi.json describes the LP64 layout (x86_64 / aarch64 Linux); C++ sync_abi.h
// asserts a0_mtx_t against the same constants.
#[cfg(target_pointer_width = "64")]
const _: () = {
    use std::mem::align_of;
    assert!(size_of::<A0Mtx>() == abi::a0_mtx_size);
    assert!(align_of::<A0Mtx>() == abi::a0_mtx_align);
    assert!(offset_of!(A0Mtx, next) == abi::a0_mtx_next_off);
    assert!(offset_of!(A0Mtx, prev) == abi::a0_mtx_prev_off);
    assert!(offset_of!(A0Mtx, ftx) == abi::a0_mtx_ftx_off);
    assert!(size_of::<A0Cnd>() == abi::a0_cnd_size);
    assert!(align_of::<A0Cnd>() == abi::a0_cnd_align);
};
// The kernel reads the head as `struct robust_list_head`, and a0 compares a
// list entry against the head's address (`robust_is_head`), which only works
// because `list` is the head's first field.
const _: () = {
    assert!(offset_of!(RobustListHead, list) == 0);
    assert!(size_of::<RobustListHead>() == 3 * size_of::<usize>());
};

/// Errno-style result of an a0 operation (`A0_SYSERR` of the C call). Note that
/// `Err(EOWNERDEAD)` from a lock or a condition wait means the mutex *is* held.
type A0Result = Result<(), c_int>;

#[inline]
fn errno() -> c_int {
    io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

// ---------------------------------------------------------------------------
// Per-thread state: robust-list head, init flag, cached TID (a0 mtx.c / tid.c).
// ---------------------------------------------------------------------------
//
// The kernel reads the robust-list head during thread exit (exit_mm ->
// exit_robust_list), after every user-space TLS destructor has run. Its storage
// must therefore outlive the thread's destructors, which a `thread_local!`
// holding a destructor-owned value would not guarantee.
//
// * Linux (glibc, musl): a `const`-initialised `thread_local!` of a type without
//   Drop compiles to a plain `#[thread_local]` static on these native-TLS
//   targets: no lazy init and no destructor registration. Its storage is the
//   thread's static TLS block, which the C library frees together with the
//   thread's stack only after the kernel has finished the exit (and signalled
//   it through CLONE_CHILD_CLEARTID, which is processed after the robust list).
//   This is the same storage a0's `A0_THREAD_LOCAL robust_list_head_t` has.
// * Android: Rust's std has no native TLS there and boxes thread-locals behind
//   a pthread key whose destructor frees them *before* the kernel walks the
//   list. The head is therefore heap-allocated once per thread and
//   intentionally leaked (3 words per thread that ever used one of these
//   mutexes); only the pointer to it lives in TLS.

#[cfg(not(target_os = "android"))]
thread_local! {
    static ROBUST_HEAD: std::cell::UnsafeCell<RobustListHead> = const {
        std::cell::UnsafeCell::new(RobustListHead {
            list: RobustList { next: ptr::null_mut() },
            futex_offset: 0,
            list_op_pending: ptr::null_mut(),
        })
    };
}

#[cfg(target_os = "android")]
thread_local! {
    static ROBUST_HEAD: Cell<*mut RobustListHead> = const { Cell::new(ptr::null_mut()) };
}

thread_local! {
    /// `a0_robust_init`: this thread's head is registered with the kernel.
    static ROBUST_INIT: Cell<bool> = const { Cell::new(false) };
    /// `a0_tid_cache`: this thread's kernel TID, 0 = not yet read.
    static TID_CACHE: Cell<u32> = const { Cell::new(0) };
}

/// This thread's robust-list head (stable for the thread's lifetime).
#[cfg(not(target_os = "android"))]
#[inline]
fn robust_head() -> *mut RobustListHead {
    ROBUST_HEAD.with(|h| h.get())
}

/// This thread's robust-list head (stable for the thread's lifetime).
#[cfg(target_os = "android")]
#[inline]
fn robust_head() -> *mut RobustListHead {
    ROBUST_HEAD.with(|h| {
        if h.get().is_null() {
            h.set(Box::into_raw(Box::new(RobustListHead {
                list: RobustList {
                    next: ptr::null_mut(),
                },
                futex_offset: 0,
                list_op_pending: ptr::null_mut(),
            })));
        }
        h.get()
    })
}

/// pthread_atfork child handler (a0 `a0_robust_reset` + `a0_tid_reset`): the
/// child's only thread has a new TID, and the kernel does not carry robust-list
/// registrations across fork, so both are redone on the next operation.
extern "C" fn reset_after_fork() {
    ROBUST_INIT.with(|i| i.set(false));
    TID_CACHE.with(|t| t.set(0));
}

// glibc provides `pthread_atfork` through libc_nonshared (musl and bionic in
// libc); the `libc` crate does not declare it for Linux.
extern "C" {
    fn pthread_atfork(
        prepare: Option<unsafe extern "C" fn()>,
        parent: Option<unsafe extern "C" fn()>,
        child: Option<unsafe extern "C" fn()>,
    ) -> c_int;
}

/// Register `reset_after_fork` once per process (a0's two `pthread_once`s).
fn register_atfork() {
    static ONCE: Once = Once::new();
    // SAFETY: registers a handler that only resets this module's thread-locals.
    ONCE.call_once(|| unsafe {
        pthread_atfork(None, None, Some(reset_after_fork));
    });
}

/// `a0_tid`: the calling thread's kernel TID, cached per thread.
#[inline]
fn tid() -> u32 {
    TID_CACHE.with(|t| {
        if t.get() == 0 {
            // SAFETY: gettid takes no arguments and cannot fail.
            t.set(unsafe { libc::syscall(libc::SYS_gettid) } as u32);
            register_atfork();
        }
        t.get()
    })
}

// ---------------------------------------------------------------------------
// Robust-list bookkeeping (mtx.c robust_*). Every function here touches only
// this thread's head and the next/prev links of mutexes this thread holds.
// a0_barrier (`__sync_synchronize`) is a SeqCst fence: a SIGKILL can land on any
// instruction, so the stores the kernel will read must be ordered as written.
// ---------------------------------------------------------------------------

/// `robust_init`: an empty list, registered with the kernel.
unsafe fn robust_init(head: *mut RobustListHead) {
    (*head).list.next = addr_of_mut!((*head).list);
    (*head).futex_offset = offset_of!(A0Mtx, ftx) as c_long;
    (*head).list_op_pending = ptr::null_mut();
    libc::syscall(libc::SYS_set_robust_list, head, size_of::<RobustListHead>());
}

/// `init_thread`.
fn init_thread() {
    if ROBUST_INIT.with(Cell::get) {
        return;
    }
    register_atfork();
    // SAFETY: the head is this thread's own, valid for the thread's lifetime.
    unsafe { robust_init(robust_head()) };
    ROBUST_INIT.with(|i| i.set(true));
}

unsafe fn robust_op_start(mtx: *mut A0Mtx) {
    init_thread();
    (*robust_head()).list_op_pending = mtx.cast();
    fence(Ordering::SeqCst);
}

unsafe fn robust_op_end(_mtx: *mut A0Mtx) {
    fence(Ordering::SeqCst);
    (*robust_head()).list_op_pending = ptr::null_mut();
}

#[inline]
fn robust_is_head(mtx: *mut A0Mtx) -> bool {
    mtx == robust_head().cast()
}

/// `robust_op_add`: push `mtx` at the front of this thread's list. The head is
/// addressed as an `A0Mtx` only through `next` (offset 0 in both structs).
unsafe fn robust_op_add(mtx: *mut A0Mtx) {
    let head = robust_head();
    let old_first: *mut A0Mtx = (*head).list.next.cast();

    (*mtx).prev = head.cast();
    (*mtx).next = old_first;

    fence(Ordering::SeqCst);

    (*head).list.next = mtx.cast();
    if !robust_is_head(old_first) {
        (*old_first).prev = mtx;
    }
}

/// `robust_op_del`: unlink `mtx` from this thread's list.
unsafe fn robust_op_del(mtx: *mut A0Mtx) {
    let prev = (*mtx).prev;
    let next = (*mtx).next;
    (*prev).next = next;
    if !robust_is_head(next) {
        (*next).prev = prev;
    }
}

#[inline]
fn ftx_tid(ftx: u32) -> u32 {
    ftx & FUTEX_TID_MASK
}

#[inline]
fn ftx_owner_died(ftx: u32) -> bool {
    ftx & FUTEX_OWNER_DIED != 0
}

#[inline]
fn ftx_notrecoverable(ftx: u32) -> bool {
    ftx & FTX_NOTRECOVERABLE == FTX_NOTRECOVERABLE
}

#[inline]
unsafe fn ftx_of<'a>(mtx: *mut A0Mtx) -> &'a AtomicU32 {
    &(*mtx).ftx
}

/// a0 `__sync_bool_compare_and_swap` (a full barrier).
#[inline]
fn cas(word: &AtomicU32, old: u32, new: u32) -> bool {
    word.compare_exchange(old, new, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
}

// ---------------------------------------------------------------------------
// Clocks (a0 clock.h): timespec arithmetic, and conversion of an absolute
// CLOCK_BOOTTIME deadline to the clock a futex op expects.
// ---------------------------------------------------------------------------

fn clock_now(clk: libc::clockid_t) -> Result<timespec, c_int> {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid out-pointer.
    if unsafe { libc::clock_gettime(clk, &mut ts) } == -1 {
        return Err(errno());
    }
    Ok(ts)
}

/// `a0_clock_add`.
// `time_t` / `c_long` are i32 on ILP32 targets, so the casts are not no-ops there.
#[allow(clippy::unnecessary_cast)]
fn clock_add(ts: timespec, add_nsec: i64) -> timespec {
    let mut sec = ts.tv_sec as i64 + add_nsec / NS_PER_SEC;
    let mut nsec = ts.tv_nsec as i64 + add_nsec % NS_PER_SEC;
    if nsec >= NS_PER_SEC {
        sec += 1;
        nsec -= NS_PER_SEC;
    } else if nsec < 0 {
        sec -= 1;
        nsec += NS_PER_SEC;
    }
    timespec {
        tv_sec: sec as _,
        tv_nsec: nsec as _,
    }
}

/// `a0_clock_convert`: the same remaining time, re-anchored on `target_clk`.
// `time_t` / `c_long` are i32 on ILP32 targets, so the casts are not no-ops there.
#[allow(clippy::unnecessary_cast)]
fn clock_convert(
    orig_clk: libc::clockid_t,
    orig_ts: timespec,
    target_clk: libc::clockid_t,
) -> Result<timespec, c_int> {
    let orig_now = clock_now(orig_clk)?;
    let target_now = clock_now(target_clk)?;
    let add_nsec = (orig_ts.tv_sec as i64 - orig_now.tv_sec as i64) * NS_PER_SEC
        + (orig_ts.tv_nsec as i64 - orig_now.tv_nsec as i64);
    Ok(clock_add(target_now, add_nsec))
}

/// `linux_::detail::make_timespec` (`calc_wait_time`): CLOCK_BOOTTIME now + `tm`
/// ms (a0 "mono" time).
fn make_deadline(tm: u64) -> Result<timespec, c_int> {
    let add_ns = tm.wrapping_mul(1_000_000) as i64;
    if add_ns < 0 {
        return Err(libc::EINVAL);
    }
    Ok(clock_add(clock_now(libc::CLOCK_BOOTTIME)?, add_ns))
}

// ---------------------------------------------------------------------------
// Futex ops (a0 ftx.h). Shared (non-private) futexes: the words live in shm.
// ---------------------------------------------------------------------------

/// `a0_futex`. The kernel truncates `op`/`val`/`val3` to 32 bits.
unsafe fn futex(
    uaddr: &AtomicU32,
    op: c_int,
    val: u32,
    timeout_or_val2: usize,
    uaddr2: *const AtomicU32,
    val3: u32,
) -> Result<c_long, c_int> {
    let r = libc::syscall(
        libc::SYS_futex,
        uaddr.as_ptr(),
        op as c_long,
        val as c_long,
        timeout_or_val2,
        uaddr2,
        val3 as c_long,
    );
    if r == -1 {
        Err(errno())
    } else {
        Ok(r)
    }
}

/// `a0_ftx_lock_pi`: FUTEX_LOCK_PI takes an absolute CLOCK_REALTIME timeout.
unsafe fn ftx_lock_pi(ftx: &AtomicU32, deadline: Option<&timespec>) -> A0Result {
    let Some(deadline) = deadline else {
        return futex(ftx, libc::FUTEX_LOCK_PI, 0, 0, ptr::null(), 0).map(drop);
    };
    let ts_wall = clock_convert(libc::CLOCK_BOOTTIME, *deadline, libc::CLOCK_REALTIME)?;
    let ts = ptr::addr_of!(ts_wall) as usize;
    futex(ftx, libc::FUTEX_LOCK_PI, 0, ts, ptr::null(), 0).map(drop)
}

/// `a0_ftx_trylock_pi`.
unsafe fn ftx_trylock_pi(ftx: &AtomicU32) -> A0Result {
    futex(ftx, libc::FUTEX_TRYLOCK_PI, 0, 0, ptr::null(), 0).map(drop)
}

/// `a0_ftx_unlock_pi`.
unsafe fn ftx_unlock_pi(ftx: &AtomicU32) -> A0Result {
    futex(ftx, libc::FUTEX_UNLOCK_PI, 0, 0, ptr::null(), 0).map(drop)
}

/// `a0_ftx_cmp_requeue_pi`: wake 1 (the only value the kernel accepts), requeue
/// up to `max_requeue` onto `requeue_ftx`, iff `*ftx == confirm_val`.
unsafe fn ftx_cmp_requeue_pi(
    ftx: &AtomicU32,
    confirm_val: u32,
    requeue_ftx: &AtomicU32,
    max_requeue: c_int,
) -> A0Result {
    let op = libc::FUTEX_CMP_REQUEUE_PI;
    futex(ftx, op, 1, max_requeue as usize, requeue_ftx, confirm_val).map(drop)
}

/// `a0_ftx_wait_requeue_pi`: FUTEX_WAIT_REQUEUE_PI takes an absolute
/// CLOCK_MONOTONIC timeout.
unsafe fn ftx_wait_requeue_pi(
    ftx: &AtomicU32,
    confirm_val: u32,
    deadline: Option<&timespec>,
    requeue_ftx: &AtomicU32,
) -> A0Result {
    let op = libc::FUTEX_WAIT_REQUEUE_PI;
    let Some(deadline) = deadline else {
        return futex(ftx, op, confirm_val, 0, requeue_ftx, 0).map(drop);
    };
    let ts_mono = clock_convert(libc::CLOCK_BOOTTIME, *deadline, libc::CLOCK_MONOTONIC)?;
    let ts = ptr::addr_of!(ts_mono) as usize;
    futex(ftx, op, confirm_val, ts, requeue_ftx, 0).map(drop)
}

// ---------------------------------------------------------------------------
// a0 mutex (mtx.c). `mtx` must point at a live, process-shared a0_mtx_t.
// ---------------------------------------------------------------------------

/// `a0_mtx_timedlock_robust`: CAS fast path, else FUTEX_LOCK_PI (retried on
/// EINTR). `Err(EOWNERDEAD)`: acquired from a dead owner, not yet consistent.
unsafe fn mtx_timedlock_robust(mtx: *mut A0Mtx, deadline: Option<&timespec>) -> A0Result {
    let tid = tid();
    let ftx = ftx_of(mtx);

    let mut syserr = libc::EINTR;
    while syserr == libc::EINTR {
        // Can't lock if borked.
        if ftx_notrecoverable(ftx.load(Ordering::Relaxed)) {
            return Err(libc::ENOTRECOVERABLE);
        }
        // Try to lock without kernel involvement.
        if cas(ftx, 0, tid) {
            return Ok(());
        }
        // Ask the kernel to lock.
        syserr = ftx_lock_pi(ftx, deadline).err().unwrap_or(0);
    }

    if syserr == 0 {
        if ftx_owner_died(ftx.load(Ordering::Relaxed)) {
            return Err(libc::EOWNERDEAD);
        }
        return Ok(());
    }
    Err(syserr)
}

/// `a0_mtx_timedlock_impl` (`a0_mtx_lock` without a deadline).
unsafe fn mtx_timedlock(mtx: *mut A0Mtx, deadline: Option<&timespec>) -> A0Result {
    robust_op_start(mtx);
    let r = mtx_timedlock_robust(mtx, deadline);
    if matches!(r, Ok(()) | Err(libc::EOWNERDEAD)) {
        robust_op_add(mtx);
    }
    robust_op_end(mtx);
    r
}

/// `a0_mtx_trylock`: CAS, and FUTEX_TRYLOCK_PI only to take over from a dead
/// owner. The C++ wrapper's try_lock is a zero-deadline timed lock instead (see
/// `PlatformMutex::try_lock`), so only the tests call this; it is kept so the
/// whole a0 mutex surface is ported.
#[cfg_attr(not(test), allow(dead_code))]
unsafe fn mtx_trylock(mtx: *mut A0Mtx) -> A0Result {
    robust_op_start(mtx);
    let r = mtx_trylock_impl(mtx);
    robust_op_end(mtx);
    r
}

#[cfg_attr(not(test), allow(dead_code))]
unsafe fn mtx_trylock_impl(mtx: *mut A0Mtx) -> A0Result {
    let tid = tid();
    let ftx = ftx_of(mtx);

    // Try to lock without kernel involvement.
    let old = match ftx.compare_exchange(0, tid, Ordering::SeqCst, Ordering::SeqCst) {
        Ok(_) => {
            robust_op_add(mtx);
            return Ok(());
        }
        Err(old) => old,
    };
    // Is the lock still usable?
    if ftx_notrecoverable(old) {
        return Err(libc::ENOTRECOVERABLE);
    }
    // Is the owner still alive?
    if !ftx_owner_died(old) {
        return Err(libc::EBUSY);
    }
    // Oh, the owner died. Ask the kernel to fix the state.
    match ftx_trylock_pi(ftx) {
        Ok(()) => {
            robust_op_add(mtx);
            if ftx_owner_died(ftx.load(Ordering::Relaxed)) {
                return Err(libc::EOWNERDEAD);
            }
            Ok(())
        }
        // EAGAIN means that somebody else beat us to it.
        Err(libc::EAGAIN) => Err(libc::EBUSY),
        // Anything else means we're borked.
        Err(_) => Err(libc::ENOTRECOVERABLE),
    }
}

/// `a0_mtx_consistent`: the owner clears FUTEX_OWNER_DIED.
unsafe fn mtx_consistent(mtx: *mut A0Mtx) -> A0Result {
    let ftx = ftx_of(mtx);
    let val = ftx.load(Ordering::Relaxed);
    // Why fix what isn't broken?
    if !ftx_owner_died(val) {
        return Err(libc::EINVAL);
    }
    // Is it yours to fix?
    if ftx_tid(val) != tid() {
        return Err(libc::EPERM);
    }
    ftx.fetch_and(!FUTEX_OWNER_DIED, Ordering::Relaxed);
    Ok(())
}

/// `a0_mtx_unlock`: owner only (EPERM). Unlocking while still owner-died leaves
/// the mutex FTX_NOTRECOVERABLE, as a0 does.
unsafe fn mtx_unlock(mtx: *mut A0Mtx) -> A0Result {
    let tid = tid();
    let ftx = ftx_of(mtx);
    let val = ftx.load(Ordering::Relaxed);

    // Only the owner can unlock.
    if ftx_tid(val) != tid {
        return Err(libc::EPERM);
    }

    // Acquired with EOWNERDEAD and never made consistent: unrecoverably borked.
    let new_val = if ftx_owner_died(val) {
        FTX_NOTRECOVERABLE
    } else {
        0
    };

    robust_op_start(mtx);
    robust_op_del(mtx);

    // Exactly `tid` means no waiters: the kernel need not get involved.
    if !cas(ftx, tid, new_val) {
        // Ask the kernel to wake up a waiter (a0 ignores the result).
        let _ = ftx_unlock_pi(ftx);
        if new_val != 0 {
            ftx.fetch_or(new_val, Ordering::Relaxed);
        }
    }

    robust_op_end(mtx);
    Ok(())
}

// ---------------------------------------------------------------------------
// a0 condition (mtx.c a0_cnd_*). The caller holds `mtx`.
// ---------------------------------------------------------------------------

/// `a0_cnd_timedwait_impl`.
///
/// Differs from the C in one reporting detail: a0 assigns the bare errno
/// `EOWNERDEAD` to its `a0_err_t` result after a successful wake, which
/// `A0_SYSERR` (and so the C++ wrapper) reads as success. Here it is reported
/// as `Err(EOWNERDEAD)`, the code a0 means, and `PlatformCondition::wait` makes
/// the mutex consistent instead of leaving it to turn unrecoverable on unlock.
unsafe fn cnd_timedwait(cnd: &A0Cnd, mtx: *mut A0Mtx, deadline: Option<&timespec>) -> A0Result {
    let init_cnd = cnd.load(Ordering::Relaxed);

    // Unblock other threads to do the things that will eventually signal this wait.
    mtx_unlock(mtx)?;

    robust_op_start(mtx);

    let ftx = ftx_of(mtx);
    let mut err;
    loop {
        // Priority-inheritance-aware wait until awoken or timeout.
        err = ftx_wait_requeue_pi(cnd, init_cnd, deadline, ftx);
        if err != Err(libc::EINTR) {
            break;
        }
    }

    // We need to manually lock on timeout. The timeout stays the result unless
    // the re-lock itself fails, which in C overwrites the thread-local errno
    // the C++ wrapper reads.
    if err == Err(libc::ETIMEDOUT) {
        if let Err(e) = mtx_timedlock_robust(mtx, None) {
            err = Err(e);
        }
    }
    // Someone else grabbed and mutated the resource between the unlock and
    // wait. No need to wait.
    if err == Err(libc::EAGAIN) {
        err = mtx_timedlock_robust(mtx, None);
    }

    robust_op_add(mtx);

    // If no higher priority error, check the previous owner didn't die.
    if err.is_ok() && ftx_owner_died(ftx.load(Ordering::Relaxed)) {
        err = Err(libc::EOWNERDEAD);
    }

    robust_op_end(mtx);
    err
}

/// `a0_cnd_timedwait`'s argument check: don't unlock for a bad deadline.
// `time_t` / `c_long` are i32 on ILP32 targets, so the casts are not no-ops there.
#[allow(clippy::unnecessary_cast)]
fn deadline_valid(ts: &timespec) -> bool {
    !(ts.tv_sec < 0
        || ts.tv_nsec < 0
        || (ts.tv_sec == 0 && ts.tv_nsec == 0)
        || ts.tv_nsec as i64 >= NS_PER_SEC)
}

/// `a0_cnd_wake`: bump the sequence, then requeue the sleepers onto the mutex
/// futex; EAGAIN means another waker moved the sequence, so retry with it.
unsafe fn cnd_wake(cnd: &A0Cnd, mtx: *mut A0Mtx, cnt: c_int) -> A0Result {
    let mut val = cnd.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
    loop {
        match ftx_cmp_requeue_pi(cnd, val, ftx_of(mtx), cnt) {
            Err(libc::EAGAIN) => val = cnd.load(Ordering::Relaxed),
            other => return other,
        }
    }
}

// ---------------------------------------------------------------------------
// Shared-memory plumbing.
// ---------------------------------------------------------------------------

#[inline]
fn check(r: A0Result) -> io::Result<()> {
    r.map_err(io::Error::from_raw_os_error)
}

/// Open `name` through `cache`, zero-filling the payload as its first opener.
fn acquire_zeroed(
    cache: &std::sync::Mutex<posix::ShmCache>,
    name: &str,
    size: usize,
) -> io::Result<Arc<CachedShm>> {
    posix::cached_shm_acquire(cache, name, size, |base| {
        // SAFETY: the mapping is at least `size` bytes, and as its first opener
        // (under the cache lock) nothing else uses it yet.
        unsafe { ptr::write_bytes(base, 0, size) };
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// PlatformMutex — a0_mtx_t in shared memory (C++ `robust_mutex`)
// ---------------------------------------------------------------------------

pub struct PlatformMutex {
    cached: Arc<CachedShm>,
    name: String,
}

impl PlatformMutex {
    /// Open (or create) the named mutex `name` (same shm name as C++).
    pub fn open(name: &str) -> io::Result<Self> {
        let cached = acquire_zeroed(posix::mutex_cache(), name, MUTEX_PAYLOAD_SIZE)?;
        Ok(Self {
            cached,
            name: name.to_string(),
        })
    }

    #[inline]
    fn raw(&self) -> *mut A0Mtx {
        self.cached.shm.as_mut_ptr().cast()
    }

    /// Mirrors C++ `robust_mutex::lock(tm)`: `Ok(true)` acquired, `Ok(false)`
    /// timed out. A dead owner's lock is made consistent, released and
    /// re-acquired.
    fn lock_for(&self, tm: u64) -> io::Result<bool> {
        loop {
            let r = if tm == INFINITE_MS {
                // SAFETY: `raw()` is this handle's live, mapped a0_mtx_t.
                unsafe { mtx_timedlock(self.raw(), None) }
            } else {
                let deadline = make_deadline(tm).map_err(io::Error::from_raw_os_error)?;
                // SAFETY: as above.
                unsafe { mtx_timedlock(self.raw(), Some(&deadline)) }
            };
            match r {
                Ok(()) => return Ok(true),
                Err(libc::ETIMEDOUT) => return Ok(false),
                Err(libc::EOWNERDEAD) => {
                    // SAFETY: EOWNERDEAD hands this thread the mutex.
                    check(unsafe { mtx_consistent(self.raw()) })?;
                    check(unsafe { mtx_unlock(self.raw()) })?;
                    // loop again
                }
                Err(e) => return Err(io::Error::from_raw_os_error(e)),
            }
        }
    }

    /// Lock (blocking, no timeout).
    pub fn lock(&self) -> io::Result<()> {
        if self.lock_for(INFINITE_MS)? {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(libc::ETIMEDOUT))
        }
    }

    /// Lock with a timeout in milliseconds (`u32::MAX` = no timeout, as C++).
    pub fn lock_timeout(&self, timeout_ms: u64) -> io::Result<bool> {
        self.lock_for(timeout_ms)
    }

    /// Try to lock without blocking: a timed lock with deadline now + 0, as C++.
    ///
    /// A mutex already held by the calling thread reports `Ok(false)` (busy),
    /// as `pthread_mutex_trylock` does, rather than the kernel's EDEADLK.
    pub fn try_lock(&self) -> io::Result<bool> {
        match self.lock_for(0) {
            Err(e) if e.raw_os_error() == Some(libc::EDEADLK) => Ok(false),
            other => other,
        }
    }

    /// Unlock (must be called by the locking thread; EPERM otherwise).
    pub fn unlock(&self) -> io::Result<()> {
        // SAFETY: `raw()` is this handle's live, mapped a0_mtx_t.
        check(unsafe { mtx_unlock(self.raw()) })
    }

    /// Raw pointer to the `a0_mtx_t` (consumed by `PlatformCondition`).
    pub(crate) fn native_ptr(&self) -> *mut u8 {
        self.cached.shm.as_mut_ptr()
    }

    /// Remove the shared memory backing this mutex (static helper).
    pub fn clear_storage(name: &str) {
        posix::cached_shm_purge(posix::mutex_cache(), name);
        PlatformShm::unlink_by_name(name);
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        posix::cached_shm_release(posix::mutex_cache(), &self.name);
    }
}

// ---------------------------------------------------------------------------
// PlatformCondition — a0_cnd_t in shared memory (C++ `condition`)
// ---------------------------------------------------------------------------

pub(crate) struct PlatformCondition {
    cached: Arc<CachedShm>,
    name: String,
}

impl PlatformCondition {
    pub(crate) fn open(name: &str) -> io::Result<Self> {
        let cached = acquire_zeroed(posix::cond_cache(), name, CONDITION_PAYLOAD_SIZE)?;
        Ok(Self {
            cached,
            name: name.to_string(),
        })
    }

    #[inline]
    fn cnd(&self) -> &A0Cnd {
        // SAFETY: the mapping holds an aligned u32 for as long as `self` lives.
        unsafe { &*self.cached.shm.as_mut_ptr().cast::<A0Cnd>() }
    }

    /// Mirrors C++ `condition::wait`: `Ok(true)` woken, `Ok(false)` timed out
    /// (the mutex is re-acquired either way). `mtx` is the paired mutex's
    /// `native_ptr()`, held by the calling thread.
    ///
    /// If the mutex comes back from a dead owner (EOWNERDEAD) it is made
    /// consistent and the wait reports a wake-up (callers re-check their
    /// predicate). C++ instead leaves it owner-died, so its next unlock makes
    /// it unrecoverable; see `cnd_timedwait`.
    pub(crate) fn wait(&self, mtx: *mut u8, timeout_ms: Option<u64>) -> io::Result<bool> {
        let mtx: *mut A0Mtx = mtx.cast();
        let tm = timeout_ms.unwrap_or(INFINITE_MS);
        let r = if tm == INFINITE_MS {
            // SAFETY: `mtx` is the caller's live a0_mtx_t, held by this thread.
            unsafe { cnd_timedwait(self.cnd(), mtx, None) }
        } else {
            let deadline = make_deadline(tm).map_err(io::Error::from_raw_os_error)?;
            if !deadline_valid(&deadline) {
                return Err(io::Error::from_raw_os_error(libc::EINVAL));
            }
            // SAFETY: as above.
            unsafe { cnd_timedwait(self.cnd(), mtx, Some(&deadline)) }
        };
        match r {
            Ok(()) => Ok(true),
            Err(libc::ETIMEDOUT) => Ok(false),
            Err(libc::EOWNERDEAD) => {
                // SAFETY: EOWNERDEAD means this thread holds the mutex.
                check(unsafe { mtx_consistent(mtx) })?;
                Ok(true)
            }
            Err(e) => Err(io::Error::from_raw_os_error(e)),
        }
    }

    /// `a0_cnd_signal`: wake one waiter, requeued onto `mtx`.
    pub(crate) fn notify(&self, mtx: *mut u8) -> io::Result<()> {
        // SAFETY: `mtx` is the paired mutex's live a0_mtx_t.
        check(unsafe { cnd_wake(self.cnd(), mtx.cast(), 1) })
    }

    /// `a0_cnd_broadcast`: wake every waiter, requeued onto `mtx`.
    pub(crate) fn broadcast(&self, mtx: *mut u8) -> io::Result<()> {
        // SAFETY: as for `notify`.
        check(unsafe { cnd_wake(self.cnd(), mtx.cast(), c_int::MAX) })
    }

    pub(crate) fn clear_storage(name: &str) {
        posix::cached_shm_purge(posix::cond_cache(), name);
        PlatformShm::unlink_by_name(name);
    }
}

impl Drop for PlatformCondition {
    fn drop(&mut self) {
        posix::cached_shm_release(posix::cond_cache(), &self.name);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique(tag: &str) -> String {
        format!("thoth_a0_{tag}_{}", std::process::id())
    }

    #[test]
    fn payload_sizes_match_abi() {
        assert_eq!(CONDITION_PAYLOAD_SIZE, 4);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(MUTEX_PAYLOAD_SIZE, abi::a0_mtx_size);
    }

    #[test]
    fn clock_add_normalises() {
        let ts = timespec {
            tv_sec: 10,
            tv_nsec: 900_000_000,
        };
        let up = clock_add(ts, 200_000_000);
        assert_eq!((up.tv_sec, up.tv_nsec), (11, 100_000_000));
        let down = clock_add(ts, -950_000_000);
        assert_eq!((down.tv_sec, down.tv_nsec), (9, 950_000_000));
    }

    #[test]
    fn robust_list_tracks_held_mutexes() {
        let name = unique("robust");
        PlatformMutex::clear_storage(&name);
        let m = PlatformMutex::open(&name).expect("open");
        m.lock().expect("lock");
        let head = robust_head();
        // SAFETY: this thread's own head; `m` is held, so it heads the list.
        unsafe {
            assert_eq!((*head).list.next.cast::<A0Mtx>(), m.raw());
            assert_eq!((*head).futex_offset as usize, offset_of!(A0Mtx, ftx));
            assert_eq!(ftx_tid(ftx_of(m.raw()).load(Ordering::Relaxed)), tid());
        }
        m.unlock().expect("unlock");
        // SAFETY: as above; the list is empty again (points back at the head).
        unsafe {
            assert!(robust_is_head((*head).list.next.cast()));
            assert_eq!(ftx_of(m.raw()).load(Ordering::Relaxed), 0);
        }
        drop(m);
        PlatformMutex::clear_storage(&name);
    }

    #[test]
    fn trylock_and_owner_checks() {
        let name = unique("trylock");
        PlatformMutex::clear_storage(&name);
        let m = Arc::new(PlatformMutex::open(&name).expect("open"));
        // SAFETY (all blocks below): `m` stays mapped for the whole test.
        assert_eq!(unsafe { mtx_trylock(m.raw()) }, Ok(()));
        let other = Arc::clone(&m);
        std::thread::spawn(move || {
            assert_eq!(unsafe { mtx_trylock(other.raw()) }, Err(libc::EBUSY));
            assert_eq!(unsafe { mtx_unlock(other.raw()) }, Err(libc::EPERM));
            assert!(!other.try_lock().expect("try_lock"));
        })
        .join()
        .unwrap();
        assert!(!m.try_lock().expect("relock by holder is busy"));
        assert_eq!(unsafe { mtx_consistent(m.raw()) }, Err(libc::EINVAL));
        m.unlock().expect("unlock");
        drop(m);
        PlatformMutex::clear_storage(&name);
    }

    /// A thread that exits holding the mutex: the kernel's robust-list walk
    /// marks it owner-died, and the next lock recovers it (as C++ does).
    #[test]
    fn owner_death_is_recovered() {
        let name = unique("death");
        PlatformMutex::clear_storage(&name);
        let m = Arc::new(PlatformMutex::open(&name).expect("open"));
        let holder = Arc::clone(&m);
        std::thread::spawn(move || holder.lock().expect("lock in exiting thread"))
            .join()
            .unwrap();
        // SAFETY (both blocks): `m` stays mapped for the whole test.
        let word = unsafe { ftx_of(m.raw()).load(Ordering::Relaxed) };
        assert!(
            ftx_owner_died(word),
            "kernel did not mark owner death: {word:#x}"
        );
        assert!(m.lock_timeout(1000).expect("recovering lock"));
        let word = unsafe { ftx_of(m.raw()).load(Ordering::Relaxed) };
        assert_eq!(word & FTX_NOTRECOVERABLE, tid());
        m.unlock().expect("unlock");
        drop(m);
        PlatformMutex::clear_storage(&name);
    }

    #[test]
    fn timed_lock_and_wait_time_out() {
        let name = unique("timeout");
        let cname = format!("{name}_c");
        PlatformMutex::clear_storage(&name);
        PlatformCondition::clear_storage(&cname);
        let m = Arc::new(PlatformMutex::open(&name).expect("open"));
        let c = PlatformCondition::open(&cname).expect("open cond");
        m.lock().expect("lock");
        let other = Arc::clone(&m);
        std::thread::spawn(move || assert!(!other.lock_timeout(50).expect("timed lock")))
            .join()
            .unwrap();
        assert!(!c.wait(m.native_ptr(), Some(50)).expect("timed wait"));
        m.unlock()
            .expect("unlock after the timed wait re-acquired it");
        drop(c);
        drop(m);
        PlatformMutex::clear_storage(&name);
        PlatformCondition::clear_storage(&cname);
    }
}
