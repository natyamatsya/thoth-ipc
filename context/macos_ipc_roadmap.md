# macOS Low-Latency IPC Roadmap

## Current State & Bottleneck

The core `cpp-ipc` library on macOS currently suffers from severe latency degradation under contention (e.g., 2–3ms RTT in benchmarks vs. ~0.02ms in Rust). This is caused by the emulation of POSIX timed locks (`pthread_mutex_timedlock` and `sem_timedwait`), which macOS does not natively support. The emulation relies on a busy loop with escalating `std::this_thread::sleep_for()` calls, which destroys real-time performance.

## Objective

Bring C++ IPC performance on macOS to parity with the lock-free Rust port (`bench_ipc.rs`) by replacing the POSIX emulation layer with native, high-performance macOS primitives.

## Two-Pronged Approach

Because macOS restricts certain high-performance APIs (like `ulock`) from the Mac App Store, `cpp-ipc` must offer two configurable backends for macOS:

### 1. The `ulock` Backend (Default / High Performance)

* **Mechanism:** Use Darwin's undocumented `__ulock_wait` and `__ulock_wake` APIs with `UL_COMPARE_AND_WAIT_SHARED` flags.
* **Inspiration:** Rust's `parking_lot` crate and the modern Rust standard library.
* **Pros:** Absolute lowest latency, exact timeout support, matches Linux `futex` behavior.
* **Cons:** Uses private Apple APIs. Cannot be used in applications submitted to the Mac App Store.

### 2. The Mach Semaphore Backend (App Store Safe)

* **Mechanism:** Use public Mach port semaphores (`semaphore_create`, `semaphore_timedwait`, `semaphore_signal`).
* **Pros:** 100% public API, perfectly safe for Mac App Store distribution. Natively supports timeouts without polling/sleeping.
* **Cons:** Slightly higher overhead than `ulock` due to Mach port kernel transitions, but still vastly superior to the current `sleep_for` emulation.

## Execution Plan

### Phase 1: Establish Baseline & Inspiration ✅

* [x] Add the Rust `parking_lot` crate as a Git submodule in the `inspiration/` folder.
* [x] Analyze XNU source to extract `ulock` syscall signatures and flag definitions for shared memory.

### Phase 2: Implement `ulock` Backend ✅

* [x] Created `src/libipc/platform/apple/ulock.h` with C bindings for `__ulock_wait` and `__ulock_wake` (all flag constants from XNU).
* [x] Rewrote `ipc::detail::sync::mutex` (`platform/apple/mutex.h`) — 32-bit word-lock (0=unlocked, 1=locked, 2=locked+waiters), eliminates `pthread_mutex_t` and all `sleep_for` polling. Dead-holder recovery preserved via PID liveness check.
* [x] Created `src/libipc/platform/apple/condition.h` — sequence-counter condvar using `__ulock_wait/wake`, eliminates `pthread_cond_t`.
* [x] Rewrote `src/libipc/platform/apple/semaphore_impl.h` — atomic count + `__ulock_wait/wake`, eliminates `sem_t` and 100µs polling loop.
* [x] Updated `sync/condition.cpp` to select `apple/condition.h` on `LIBIPC_OS_APPLE`.
* [x] All 254 C++ unit tests pass.
* [ ] Run `bench_ipc` and record latency improvement vs. baseline.
* [ ] Update CMake to enable/disable the `ulock` backend via a flag (e.g., `LIBIPC_APPLE_APP_STORE_SAFE=OFF`).

### Phase 3: Implement Mach Semaphore Backend ✅

* [x] Created `platform/apple/mach/mutex.h` — word-lock + `semaphore_t` (SYNC_POLICY_FIFO) for blocking. Process-local semaphore table keyed by shm name.
* [x] Created `platform/apple/mach/condition.h` — sequence counter in shm + `semaphore_t` per process. `broadcast` uses `semaphore_signal_all`.
* [x] Created `platform/apple/mach/semaphore_impl.h` — atomic count in shm + `semaphore_t` for blocking. Eliminates all polling.
* [x] Added `LIBIPC_APPLE_APP_STORE_SAFE` CMake option (default OFF) that switches all three sync primitives to the Mach backend.
* [x] Both backends build and pass all 254 tests.

### Phase 4: Spinlock Tuning ✅

* [x] Added `arm64`/`aarch64` case to `IPC_LOCK_PAUSE_()` macro in `include/libipc/rw_lock.h` using `isb sy` (the correct ARM64 spin-wait hint, equivalent to x86 `pause`). Previously the macro fell through to the no-op compiler fence on Apple Silicon.
* [x] Both ulock and Mach backends already use `isb sy` in their own spin loops.
* [x] All 254 tests pass with both backends.
