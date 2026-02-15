# macOS Port — Technical Notes

This document records the platform-specific behaviors encountered while porting
`cpp-ipc` to macOS (Darwin / Apple Silicon + Intel). Each section describes the
symptom, root cause, and the fix applied.

---

## 1. PSHMNAMLEN — POSIX Shared Memory Name Limit

**Symptom:**
`shm_open()` and `sem_open()` fail with `ENAMETOOLONG` (errno 63) when the name
(including the mandatory leading `/`) exceeds **31 characters**.

**Root cause:**
macOS defines `PSHMNAMLEN = 31` in `<sys/posix_shm.h>`. The kernel rejects any
name longer than this. Linux has no practical limit (usually 255).

The library composes hierarchical names such as:

```text
/__IPC_SHM__QU_CONN__my_channel__64__8
```

These routinely reach 40–60 characters.

**Fix:**
A compile-time opt-in hashing layer (`src/libipc/platform/posix/shm_name.h`):

- **`LIBIPC_SHM_NAME_MAX`** CMake option (default 31 on Apple, 0 elsewhere).
- When a name exceeds the limit, it is shortened to
  `/<prefix>_<16-hex-FNV-1a-hash>` (exactly 31 chars).
- The prefix preserves a debuggable fragment of the original name
  (e.g. `__IPC_SHM__QU_CO`).
- When `LIBIPC_SHM_NAME_MAX=0`, the function reduces to a simple `/` prefixer
  that the compiler inlines away — **zero cost on Linux/FreeBSD/QNX**.

**Key detail:**
The hash input is the **full** original name (before truncation), so two
different long names that share the same prefix still produce distinct hashes.

---

## 2. ftruncate Returns EINVAL on Already-Sized Objects

**Symptom:**
`ftruncate(fd, size)` returns `-1` with `errno = EINVAL` when called on a POSIX
shared memory object that has **already been sized** — even if the requested size
is identical to the current size. On Linux, this is a no-op that succeeds.

**Root cause:**
The macOS kernel does not permit resizing (or re-sizing to the same value) of an
existing shared memory object via `ftruncate`. This is undocumented but
consistent across all macOS versions tested.

**Fix** (`shm_posix.cpp`, `get_mem()`):

When `ftruncate` fails with `EINVAL`:

1. **Same size** — `fstat` the fd; if the existing size `>=` the requested size
   (see §3 below), proceed to `mmap` without error.
2. **Different size** — the object is stale (leftover from a previous run).
   Close the fd, `shm_unlink`, `shm_open` a fresh object, and retry
   `ftruncate`.

The `#if defined(LIBIPC_OS_APPLE)` guard ensures this logic is compiled out on
other platforms where `ftruncate` behaves normally.

---

## 3. fstat Returns Page-Rounded Sizes for Shared Memory

**Symptom:**
After `ftruncate(fd, 520)`, `fstat` reports `st_size = 16384` (one 16 KB page).
Two handles to the same object see different "sizes" if one uses `ftruncate`'s
input and the other reads `fstat`.

**Root cause:**
The macOS kernel rounds POSIX shared memory object sizes **up to the VM page
boundary** (16 KB on Apple Silicon, 4 KB on Intel). The `fstat` system call
returns this rounded value, not the value originally passed to `ftruncate`.
Linux returns the exact `ftruncate` value.

**Impact:**
The library stores a reference counter (`info_t`) at the **end** of the mapped
region:

```cpp
// offset = size - sizeof(info_t)
acc_of(mem, size)
```

If handle A uses `size = 520` (from `calc_size`) and handle B uses
`size = 16384` (from `fstat`), they compute different offsets for the reference
counter. Handle B writes to uninitialized memory at offset 16376, while the
actual counter lives at offset 512. This manifests as:

- Reference counts stuck at 0 or 1 (writes go to the wrong location)
- The `conn_head_base::init()` DCLP pattern failing (second handle sees
  `constructed_ = false` because it reads a different memory location)
- Receivers never registering, causing "no receiver on this connection" errors
- Blocking `recv()` calls that never return (deadlock)

**Fix:**
Two changes in `shm_posix.cpp`:

1. **`ftruncate` EINVAL handler** — compare with `>=` instead of `==`:

   ```cpp
   // macOS rounds sizes to page boundaries, so fstat reports a larger value.
   if (::fstat(fd, &st) == 0
       && static_cast<std::size_t>(st.st_size) >= ii->size_)
   ```

2. **`open` mode preserves caller's size** — on macOS, the `open` case in
   `acquire()` does **not** zero the size. This ensures `get_mem()` uses
   `calc_size(caller_size)` instead of the page-rounded `fstat` value, so the
   reference counter offset matches the creator's:

   ```cpp
   case open:
   #if defined(LIBIPC_OS_APPLE)
       break;          // keep caller's size
   #else
       size = 0;       // Linux: read from fstat (returns exact value)
       break;
   #endif
   ```

---

## 4. dispatch_semaphore_t Is Process-Local

**Symptom:**
`SemaphoreTest.NamedSemaphoreSharing` hangs forever. Thread A waits on a
semaphore, thread B signals a semaphore with the same name — but thread A never
wakes.

**Root cause:**
`dispatch_semaphore_t` (Grand Central Dispatch) is a **process-local** primitive.
Two `dispatch_semaphore_create()` calls with "the same name" produce completely
independent objects — there is no kernel-level naming or sharing mechanism.
This differs fundamentally from POSIX named semaphores (`sem_open`), which are
shared across processes and across independent handles within the same process.

**Fix:**
Replaced `dispatch_semaphore_t` with POSIX named semaphores
(`src/libipc/platform/apple/semaphore_impl.h`):

- **`sem_open`** / **`sem_close`** / **`sem_unlink`** for lifecycle
- **`sem_wait`** for infinite waits
- **`sem_trywait`** in a polling loop (100 µs sleep) for timed waits, since
  macOS lacks `sem_timedwait`

**Side note — `dispatch_semaphore` SIGTRAP on release:**
During development, an intermediate implementation using `dispatch_semaphore_t`
also triggered `SIGTRAP` (trace trap) during object destruction.
`dispatch_release()` asserts at runtime that the semaphore's internal count is
≥ the value passed to `dispatch_semaphore_create()`. If any `wait` calls have
been made without matching `signal` calls, the process is killed with `SIGTRAP`.
This is a debugging aid from libdispatch, not a catchable signal.

---

## 5. pthread_mutex_timedlock Is Unavailable

**Symptom:**
Compilation error: `use of undeclared identifier 'pthread_mutex_timedlock'`.

**Root cause:**
macOS does not implement `pthread_mutex_timedlock()` (IEEE Std 1003.1 TMO
option). The function is absent from `<pthread.h>`.

**Fix:**
`src/libipc/platform/apple/mutex.h` — emulates timed lock with a polling loop:

```cpp
while (pthread_mutex_trylock(&mtx) != 0) {
    if (now >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::microseconds(100));
}
```

This trades precision (up to 100 µs overshoot) for simplicity. An adaptive
back-off strategy (spin → escalating sleep) is a potential future improvement.

---

## 6. Robust Mutexes Are Unavailable

**Symptom:**
Compilation error: `use of undeclared identifier 'PTHREAD_MUTEX_ROBUST'`.

**Root cause:**
macOS does not support `pthread_mutexattr_setrobust()`, `EOWNERDEAD`, or
`pthread_mutex_consistent()`. If a process dies while holding a
`PTHREAD_PROCESS_SHARED` mutex in shared memory, the mutex becomes permanently
locked.

**Fix:**
The Apple mutex implementation (`src/libipc/platform/apple/mutex.h`) simply omits
the robust attribute. The mutex is still `PTHREAD_PROCESS_SHARED` and functional
for the normal (non-crash) case.

**Known limitation:**
If a process crashes while holding a shared mutex, other processes will deadlock.
Potential future mitigations:

- PID-based liveness detection (`kill(holder_pid, 0)`)
- Advisory file locks as a crash-detection sidecar

---

## 7. std::aligned_alloc Minimum Alignment

**Symptom:**
`std::aligned_alloc(1, 1)` returns `nullptr` on macOS but succeeds on Linux.

**Root cause:**
The macOS libc implementation of `aligned_alloc` (and `posix_memalign`) requires
that `alignment >= sizeof(void*)` (8 on 64-bit). Smaller alignments are
rejected. The C standard technically allows this (it says "alignment shall be a
valid alignment supported by the implementation").

**Fix:**
`src/libipc/mem/new_delete_resource.cpp` — clamp alignment to `sizeof(void*)`:

```cpp
if (alignment < sizeof(void*)) alignment = sizeof(void*);
return std::aligned_alloc(alignment, ipc::round_up(bytes, alignment));
```

---

## 8. No librt on macOS

**Symptom:**
Linker error: `ld: library 'rt' not found`.

**Root cause:**
On Linux, `shm_open` / `shm_unlink` live in `librt`. On macOS, they are part of
libc — there is no separate `librt`.

**Fix:**
`src/CMakeLists.txt` — exclude Darwin from the `-lrt` link:

```cmake
$<$<NOT:$<OR:...$<STREQUAL:${CMAKE_SYSTEM_NAME},Darwin>>>:rt>
```

---

## Summary of macOS vs. Linux Behavioral Differences

| Behavior                         | Linux                     | macOS                             |
| -------------------------------- | ------------------------- | --------------------------------- |
| `shm_open` name limit           | ~255 chars                | **31 chars** (`PSHMNAMLEN`)       |
| `ftruncate` on sized shm        | no-op, succeeds           | **returns `EINVAL`**              |
| `fstat` on shm object           | exact `ftruncate` size    | **page-rounded size**             |
| `sem_timedwait`                  | available                 | **missing**                       |
| `pthread_mutex_timedlock`        | available                 | **missing**                       |
| `pthread_mutexattr_setrobust`    | available                 | **missing**                       |
| `dispatch_semaphore_t`           | N/A                       | **process-local only**            |
| `std::aligned_alloc(1, N)`       | succeeds                  | **returns `nullptr`**             |
| `librt`                          | required for shm          | **does not exist**                |
