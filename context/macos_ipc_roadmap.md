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

### Phase 1: Establish Baseline & Inspiration (In Progress)

- [x] Add the Rust `parking_lot` crate as a Git submodule in the `inspiration/` folder.
* [ ] Analyze `parking_lot_core/src/thread_parker/darwin.rs` to extract the exact `ulock` syscall signatures and flag definitions for shared memory.

### Phase 2: Implement `ulock` Backend

- [ ] Create `src/libipc/platform/apple/ulock.h` with the C bindings for `__ulock_wait` and `__ulock_wake`.
* [ ] Rewrite `ipc::detail::sync::mutex` (in `platform/apple/mutex.h`) to use a 32-bit atomic state and `ulock` for blocking, eliminating `pthread_mutex_t`.
* [ ] Rewrite `ipc::detail::sync::condition` and `ipc::detail::sync::semaphore` to use `ulock`.
* [ ] Update CMake to enable/disable the `ulock` backend via a flag (e.g., `LIBIPC_APPLE_APP_STORE_SAFE=OFF`).
* [ ] Run `bench_ipc` and verify sub-microsecond latency.

### Phase 3: Implement Mach Semaphore Backend

- [ ] Rewrite the fallback path in `platform/apple/mutex.h`, `condition.h`, and `semaphore_impl.h` to use `semaphore_timedwait`.
* [ ] Ensure proper Mach port lifecycle management (avoiding port leaks across processes).
* [ ] Run `bench_ipc` to verify performance is acceptable and no polling loops remain.

### Phase 4: Spinlock Tuning

- [ ] Replace `std::this_thread::yield()` in `include/libipc/rw_lock.h` and circular buffer spin loops with native CPU pause instructions (`__builtin_arm_isb(15)` for Apple Silicon, `__builtin_ia32_pause()` for x86_64) for the first N backoff iterations before falling back to `ulock_wait` / `semaphore_timedwait`.
