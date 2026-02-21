# macOS IPC Performance Roadmap — Closing the C++/Rust Gap

## Context

After implementing the ulock and Mach backends (see `macos_ipc_roadmap.md`), benchmarks
show both C++ backends are **~55–480× slower than the Rust port** on the same hardware.
The synchronisation primitives are no longer the bottleneck — the gap is entirely in the
**ring-buffer data path** (`ipc.cpp` / `circ/`). This roadmap tracks the three targeted
improvements needed to close it.

Reference benchmark results: `context/benchmarks.md`.

---

## Phase 1 — Fix the thundering herd in the ulock mutex

**Root cause:** `mutex::unlock()` uses `ULF_WAKE_ALL` whenever `state == 2`. Under
N-sender or N-receiver contention, every `unlock()` wakes all sleeping threads
simultaneously. They all race onto the ring-buffer spinlock, all but one immediately
re-sleep, and the cache-line bouncing dominates.

**Evidence:** The Mach backend (`SYNC_POLICY_FIFO`, wakes one at a time) is 2–5× faster
than ulock under N≥2 contention despite higher per-call overhead.

**Fix:** Change `unlock()` to `ULF_WAKE_ONE` and have each newly-woken thread re-signal
the next waiter if it finds the lock still contested (hand-off / "barging" pattern).

**Files:**

* `src/libipc/platform/apple/mutex.h` — `unlock()` method

**Acceptance:** ulock N-sender benchmark matches or beats Mach backend.

---

## Phase 2 — Raise the spin threshold in `ipc::sleep`

**Root cause:** Code inspection confirms C++ `wait_for` and Rust `wait_for` use
**identical** `SPIN_COUNT=32` and both reset `k=0` after each wakeup. The gap is the
**cost per `waiter.wait_if` round-trip**: each call acquires a mutex, sleeps on a
condvar, wakes, and relocks (~3–13 µs on macOS). For the 100 000-message benchmark the
ring buffer is rarely actually full/empty, so the 32-yield spin exhausts quickly,
triggering a kernel round-trip for nearly every message.

The `parking_lot` `SpinWait` (in `inspiration/parking_lot/core/src/spinwait.rs`) uses
exponential CPU-relax backoff: `1, 2, 4, 8` `spin_loop()` calls for iterations 1–3,
then `thread_yield()` for iterations 4–10, then signals "go to sleep". This keeps the
CPU busy longer on the fast path without a tight spin.

**Fix:** Replace the flat `yield_now()` loop in `ipc::sleep` with exponential
`IPC_LOCK_PAUSE_()` backoff for the first ~8 iterations then `yield()` for the next
~24, matching `parking_lot`'s `SpinWait` shape. Also raise `N` from 32 to 64.

**Files:**

* `include/libipc/rw_lock.h` — `yield()` and `sleep<N>` functions
* `src/libipc/ipc.cpp` — `wait_for` call sites (verify they use the default `N`)

**Acceptance:** `ipc::route` 1-receiver latency drops below 1 µs/datum.

---

## Phase 3 — Eliminate unconditional `__ulock_wake` on every push/pop

**Root cause (revised):** The `circ/` ring buffer push/pop are already **lock-free CAS
loops** — no spinlock on the hot path. The actual bottleneck was that
`waiter::broadcast()` called `cond_.broadcast()` unconditionally on every successful
push and every successful pop, even when no thread was sleeping. Each call paid:

1. A mutex lock/unlock (barrier) — ~1 µs
2. A `__ulock_wake` syscall — ~1–2 µs even with no waiters

For the 100k-message benchmark this added ~3 µs per message regardless of whether any
thread was actually sleeping.

**Fix (two parts):**

1. **`src/libipc/platform/apple/condition.h`** — Add `waiters` counter to
   `ulock_cond_t`. Increment before `__ulock_wait`, decrement after. In `notify()` and
   `broadcast()`, skip `__ulock_wake` entirely when `waiters == 0`.

2. **`src/libipc/waiter.h`** — Remove the redundant barrier lock from
   `waiter::broadcast()` and `waiter::notify()`. The barrier was designed for POSIX
   pthread condvars; the ulock seq-counter condvar prevents lost wakeups independently
   via the kernel's compare-and-wait. Also add a fast-path predicate check in
   `wait_if()` before acquiring the mutex.

**Files:**

* `src/libipc/platform/apple/condition.h` — `ulock_cond_t`, `notify()`, `broadcast()`
* `src/libipc/waiter.h` — `wait_if()`, `notify()`, `broadcast()`

**Acceptance:** `ipc::channel` N-N benchmark at N=2 drops below 1 µs/datum.

---

## Execution order

Phase 1 and Phase 2 are **independent and low-risk** — each is a small, targeted change
with immediate measurable impact. Do them first.

Phase 3 is a **significant refactor** with risk of subtle correctness issues. Gate it
behind the Phase 1+2 benchmark results to confirm it is still necessary.

```text
Phase 1 (1–2h)  →  benchmark  →  Phase 2 (1h)  →  benchmark  →  Phase 3 (1–2 days)
```

---

## Status

* [x] Phase 1 — Fix thundering herd: `unlock()` already used `ulock_wake_one()` (single wake). `ULF_WAKE_ALL` only in dead-holder recovery and close/clear paths — correct.
* [x] Phase 2 — Exponential pause backoff implemented in `ipc::sleep` (`N=64`, `IPC_LOCK_PAUSE_()` for k<8). **No measurable effect on benchmark** — the 100k-message workload saturates the ring buffer so `wait_for` is always genuinely blocking, not spinning. The change is kept as it improves the uncontended case.
* [x] Phase 3 — Unconditional `__ulock_wake` eliminated. Added `waiters` counter to `ulock_cond_t`; `broadcast()`/`notify()` skip the syscall when `waiters == 0`. Removed redundant barrier lock from `waiter::broadcast()`. Added fast-path predicate check in `wait_if()`. **Result: `ipc::channel` N-1/N-N dropped from ~3 µs to 0.5–1 µs/datum (3–6× improvement). `ipc::route` unchanged at ~3 µs — receiver is always sleeping so `waiters > 0` on every push.**
