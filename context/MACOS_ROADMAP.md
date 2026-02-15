# macOS Support Roadmap

Status: **Initial prototype working** — library compiles, core primitives (mutex, condition, semaphore, shm) functional, but higher-level IPC channels crash due to POSIX shared memory name length limits.

Test results on the initial prototype: **139/143 core tests pass**, Route/Channel tests (~80) crash.

---

## P0 — Critical (blocks all IPC channel usage)

### 1. POSIX Shared Memory Name Length Limit

macOS enforces `PSHMNAMLEN = 31` characters (including leading `/`) for `shm_open()` names. The library composes names like:

```
/__IPC_SHM__CC_CONN__<name>_WAITER_COND_
```

These routinely exceed 50+ characters, causing `ENAMETOOLONG` (errno 63), which cascades into null pointer dereferences and segfaults in Route/Channel tests.

**Fix:** Introduce a name-shortening layer in `shm_posix.cpp` (or an Apple-specific override) that hashes names exceeding the platform limit. For example, truncate to a prefix + SHA-256 suffix when `strlen(name) > PSHMNAMLEN`. This must be applied consistently so that both sides of an IPC channel resolve to the same shortened name.

**Affected code:**

- `src/libipc/platform/posix/shm_posix.cpp` — `shm_open()` call in `acquire()`
- `src/libipc/platform/posix/semaphore_impl.h` — `sem_open()` call in `open()`
- Indirectly: all callers of `ipc::make_prefix()` in `src/libipc/ipc.cpp`

**Estimated effort:** Small-medium. Single function change in the shm layer, but needs careful testing to ensure both endpoints resolve identically.

---

## P1 — Required for production quality

### 2. Robust Mutex Support

macOS does not support `pthread_mutexattr_setrobust()`, `EOWNERDEAD`, or `pthread_mutex_consistent()`. The current Apple mutex implementation simply omits the robust attribute.

**Impact:** If a process holding a shared mutex crashes, the mutex becomes permanently locked (deadlock). On Linux/FreeBSD, robust mutexes allow the next acquirer to detect and recover from this.

**Fix options (pick one):**

- **(a) Advisory lock watchdog:** Use `flock()` or `fcntl()` file locks as a sidecar. If the process holding the mutex dies, the OS auto-releases the file lock, and a watchdog thread can detect and reset the shared mutex.
- **(b) Process liveness check:** Store the PID of the lock holder in shared memory alongside the mutex. On timed-lock failure, check if the holder PID is still alive via `kill(pid, 0)`. If not, forcibly reinitialize the mutex.
- **(c) Document the limitation:** For applications where process crash during lock hold is rare or acceptable, document that robust mutexes are unavailable on macOS and recommend using timeouts.

**Estimated effort:** Medium for (a) or (b), trivial for (c).

### 3. `pthread_mutex_timedlock` Emulation

macOS lacks `pthread_mutex_timedlock()`. The current implementation polls with `pthread_mutex_trylock()` + `sleep_for(100µs)`.

**Impact:** Increased CPU usage during contention and up to 100µs latency overshoot on timeouts.

**Fix options:**

- **(a) Adaptive polling:** Start with spin-wait (no sleep), escalate to increasing sleep intervals (1µs → 10µs → 100µs → 1ms). Balances latency vs CPU.
- **(b) Condition-variable-based timed lock:** Wrap the mutex in a condition variable wait with timeout. More complex but precise timing.
- **(c) `os_unfair_lock` for intra-process:** Where cross-process sharing isn't needed, use Apple's `os_unfair_lock` which is significantly faster.

**Estimated effort:** Small for (a), medium for (b).

### 4. `sem_timedwait` Replacement

macOS lacks `sem_timedwait()`. The current implementation uses `dispatch_semaphore_t` from Grand Central Dispatch.

**Impact:** `dispatch_semaphore_t` is **process-local** — it cannot be shared across processes via shared memory. This means the current semaphore implementation only works for inter-thread signaling, not true cross-process IPC.

**Fix options:**

- **(a) Named POSIX semaphores + polling:** Use `sem_trywait()` in a timed polling loop (similar to the mutex approach). Named semaphores (`sem_open`) do work cross-process on macOS.
- **(b) Mach semaphores:** Use `semaphore_create()` / `semaphore_timedwait()` / `semaphore_signal()` from the Mach kernel API. These support timeouts natively but require Mach port transfer for cross-process use.
- **(c) Hybrid:** Use named POSIX semaphores for cross-process (`sem_wait`/`sem_post` work fine, only timed wait needs polling) and `dispatch_semaphore` for process-local fast path.

**Estimated effort:** Small for (a), medium for (b), medium for (c).

### 5. `aligned_alloc` Behavior Difference

`std::aligned_alloc(1, 1)` returns `nullptr` on macOS (alignment must be ≥ `sizeof(void*)` or a power of two ≥ the size). The test `memory_resource.new_delete_resource` fails because of this.

**Fix:** Guard `std::aligned_alloc` calls to ensure alignment is at least `sizeof(void*)` on macOS, or fall back to `posix_memalign` for small alignments.

**Affected code:** `src/libipc/mem/new_delete_resource.cpp`

**Estimated effort:** Trivial.

---

## P2 — Quality / completeness

### 6. Platform Detection Test

The `detect_plat.os` test has no branch for `LIBIPC_OS_APPLE`.

**Fix:** Add `#elif defined(LIBIPC_OS_APPLE)` to `test/imp/test_imp_detect_plat.cpp`.

**Estimated effort:** Trivial.

### 7. Shared Memory `ftruncate` Behavior

macOS returns `EINVAL` (errno 22) from `ftruncate()` on a POSIX shared memory object that has already been sized. Unlike Linux, macOS does not allow resizing an existing shm object.

**Impact:** `ShmTest.HandleModes` and `ShmTest.ReferenceCount` fail.

**Fix:** On macOS, when `ftruncate` fails with `EINVAL` on an already-mapped shm object, check if the existing size matches the requested size (via `fstat`). If it does, proceed without error. If it doesn't, treat as a genuine error.

**Affected code:** `src/libipc/platform/posix/shm_posix.cpp` — `get_mem()` function.

**Estimated effort:** Small.

### 8. CI / Testing Infrastructure

- Add macOS to the CI matrix (GitHub Actions `macos-latest` runner).
- Tag tests that are known-limited on macOS (e.g., robust mutex recovery tests) with `GTEST_SKIP()` when `LIBIPC_OS_APPLE` is defined.
- Add macOS-specific integration tests for cross-process IPC (fork + exec).

**Estimated effort:** Small-medium.

---

## P3 — Nice to have / optimization

### 9. Use macOS-Native IPC Where Beneficial

- **`dispatch_semaphore`** — For process-local signaling, this is faster than POSIX semaphores.
- **`os_unfair_lock`** — Apple's recommended lock primitive; adaptive and very fast for intra-process use.
- **Mach ports** — For cross-process communication, Mach ports offer capabilities that POSIX shared memory doesn't (capability-based security, memory region transfer via `mach_vm_remap`).
- **XPC Services** — For structured IPC with launchd integration, XPC is the macOS-native approach and offers sandboxing support.

### 10. Memory-Mapped File Fallback for Shared Memory

As an alternative to POSIX `shm_open` (which has the 31-char name limit), use regular files in a temporary directory (`/tmp/cpp-ipc/`) with `mmap()`. This removes the name length limit entirely and provides persistence across crashes. The tradeoff is slightly more complex cleanup logic.

### 11. Universal Binary Support

Ensure the library builds correctly for both `arm64` (Apple Silicon) and `x86_64` (Intel Mac) and as a Universal Binary (`CMAKE_OSX_ARCHITECTURES="arm64;x86_64"`). The current code has no architecture-specific issues, but this should be validated in CI.

---

## Summary of Effort

| Priority | Items | Effort |
|----------|-------|--------|
| **P0** | shm name length | ~1-2 days |
| **P1** | robust mutex, timedlock, semaphore, aligned_alloc | ~3-5 days |
| **P2** | test fixes, ftruncate, CI | ~2-3 days |
| **P3** | native APIs, mmap fallback, universal binary | ~5-10 days |

**Total estimated effort: ~2-3 weeks** to reach production-quality macOS support.

The P0 fix alone would unblock all Route/Channel tests and make the library usable for basic macOS IPC.
