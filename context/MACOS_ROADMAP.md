# macOS Support Roadmap

Status: **All 254 tests pass.** Library compiles and runs on macOS with full IPC channel support.

---

## Completed

### 1. POSIX Shared Memory Name Length Limit ✅

macOS enforces `PSHMNAMLEN = 31` characters for `shm_open()` names. Implemented as a **zero-cost opt-in feature for all platforms** via `THOTH_IPC_SHM_NAME_MAX` CMake option (auto-enabled on macOS, defaults to 0/disabled elsewhere).

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

Added `THOTH_IPC_OS_APPLE` and `THOTH_IPC_OS_FREEBSD` branches to `test/imp/test_imp_detect_plat.cpp`.

### 6. `librt` Linking ✅

macOS doesn't have `librt`. Excluded Darwin from `-lrt` in `src/CMakeLists.txt`.

### 7. Platform Switch Files ✅

Added `THOTH_IPC_OS_APPLE` to all platform conditional includes:

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

## Completed (P2) — Nice to have

### 12. `os_unfair_lock` Intra-Process Fast Path ✅

`src/libipc/platform/apple/spin_lock.h` — lightweight 4-byte lock wrapping
`os_unfair_lock_t`. Wired into the Apple mutex as the process-local lock
(`curr_prog::lock`), replacing `std::mutex` for lower overhead on the handle
management path.

### 13. Memory-Mapped File Fallback ✅

`-DTHOTH_IPC_USE_FILE_SHM=ON` CMake option. Uses regular files in `/tmp/cpp-ipc/`
with `open()`/`mmap()` instead of `shm_open()`. Avoids the 31-char `PSHMNAMLEN`
limit entirely and sidesteps all macOS `ftruncate`/`fstat` quirks (files report
exact sizes). All 254 tests pass with this backend.

- `shm_posix.cpp`: `#if defined(THOTH_IPC_USE_FILE_SHM)` guards for `file_shm_open`/`file_shm_unlink`
- Names flattened into `/tmp/cpp-ipc/` with `/` → `_` replacement

### 14. Universal Binary CI ✅

Added `build-macos-universal` job to `.github/workflows/c-cpp.yml`:

- `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`
- `lipo -info` verification step

---

## Future Work

### Mach Ports

Mach ports provide capability-based cross-process IPC native to macOS. This would
be an alternative transport alongside the current shared-memory approach. Not
implemented — requires significant architecture changes (new channel backend,
port lifecycle management, message serialization).
