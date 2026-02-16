# macOS Support Roadmap

Status: **All 254 tests pass.** Library compiles and runs on macOS with full IPC channel support.

---

## Completed

### 1. POSIX Shared Memory Name Length Limit ✅

macOS enforces `PSHMNAMLEN = 31` characters for `shm_open()` names. Implemented as a **zero-cost opt-in feature for all platforms** via `LIBIPC_SHM_NAME_MAX` CMake option (auto-enabled on macOS, defaults to 0/disabled elsewhere).

- `src/libipc/platform/posix/shm_name.h` — FNV-1a 64-bit hash, compiles away when disabled
- Applied in `shm_posix.cpp` (`acquire`, `remove`) and `semaphore_impl.h` (`open`, `clear_storage`)
- Names exceeding the limit are shortened to `/<prefix>_<16-hex-hash>` (31 chars)

### 2. macOS `ftruncate` Behavior ✅

macOS returns `EINVAL` from `ftruncate()` on already-sized shm objects AND rounds shm sizes to page boundaries (e.g., 16 → 16384 via `fstat`).

- `shm_posix.cpp` `get_mem()`: when `ftruncate` fails with `EINVAL`, check `fstat` size `>=` requested (not `==`); recreate stale mismatched objects
- `shm_posix.cpp` `acquire()`: on macOS, keep caller-provided size in `open` mode (don't zero it) so ref counter offset is consistent between creator and opener

### 3. `sem_timedwait` Replacement ✅

Replaced `dispatch_semaphore_t` (process-local, can't share between handles) with POSIX named semaphores (`sem_open`/`sem_wait`/`sem_post`) + polled `sem_trywait` for timed waits.

- `src/libipc/platform/apple/semaphore_impl.h` — full rewrite using named POSIX semaphores

### 4. `aligned_alloc` Behavior Difference ✅

macOS requires `alignment >= sizeof(void*)` for `std::aligned_alloc`. Added a clamp in `src/libipc/mem/new_delete_resource.cpp`.

### 5. Platform Detection Test ✅

Added `LIBIPC_OS_APPLE` and `LIBIPC_OS_FREEBSD` branches to `test/imp/test_imp_detect_plat.cpp`.

### 6. `librt` Linking ✅

macOS doesn't have `librt`. Excluded Darwin from `-lrt` in `src/CMakeLists.txt`.

### 7. Platform Switch Files ✅

Added `LIBIPC_OS_APPLE` to all platform conditional includes:

- `sync/mutex.cpp`, `sync/condition.cpp`, `sync/semaphore.cpp`, `sync/waiter.cpp`
- `platform/platform.cpp`, `platform/platform.c`

### 8. Apple Mutex ✅

`src/libipc/platform/apple/mutex.h` — handles lack of robust mutexes and `pthread_mutex_timedlock` via polled `pthread_mutex_trylock`.

### 9. Robust Mutex Emulation ✅

macOS lacks `pthread_mutexattr_setrobust()`. Implemented PID-based liveness detection:

- `robust_mutex_t` struct in shm: `pthread_mutex_t` + `std::atomic<pid_t> holder`
- On `lock()`/`try_lock()`: store `getpid()` after acquiring
- On `unlock()`: clear holder PID
- On timeout or contention: check `kill(holder_pid, 0)` — if `ESRCH`, holder is dead → reinitialize mutex and retry

### 10. Adaptive `pthread_mutex_timedlock` Emulation ✅

Replaced fixed 100µs polling with adaptive back-off:

- **Phase 1:** Spin ~1000 iterations (no sleep) for low-latency uncontended acquire
- **Phase 2:** Escalating sleep: 1µs × 100 → 10µs × 100 → 100µs × 100 → 1ms until deadline

### 11. CI / macOS GitHub Actions ✅

Added `build-macos` job to `.github/workflows/c-cpp.yml`:

- `macos-latest` runner
- Builds tests + benchmarks
- Runs full test suite + benchmark with 4 threads

---

## Remaining (P2) — Nice to have

### macOS-Native IPC Optimizations

- **`os_unfair_lock`** for intra-process fast path
- **Mach ports** for capability-based cross-process IPC

### Memory-Mapped File Fallback

Use `/tmp/cpp-ipc/` files with `mmap()` instead of `shm_open` to avoid the 31-char name limit entirely.

### Universal Binary Support

Validate `arm64` + `x86_64` Universal Binary builds in CI.
