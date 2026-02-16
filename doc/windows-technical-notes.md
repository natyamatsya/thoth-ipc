<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors -->

# Windows Port

This document records the platform-specific behaviors encountered while ensuring
`cpp-ipc` builds and runs correctly on Windows (MSVC). Each section describes
the symptom, root cause, and the fix applied.

---

## 1. MSVC Non-Conformant Template Instantiation

**Symptom:**
`error C2999: maximum template instantiation depth of 1000 exceeded` in
`generic.h` when compiling `monotonic_buffer_resource.cpp` and
`test_mem_memory_resource.cpp`.

**Root cause:**
MSVC's default (permissive) mode eagerly evaluates default template parameters
even when SFINAE should suppress instantiation. The recursion chain:

1. `monotonic_buffer_resource` has a constructor taking `ipc::span<ipc::byte>`.
   MSVC checks whether `bytes_allocator` can convert to `span<byte>`.
2. `span(U&&)` checks `is_continuous_container<bytes_allocator>`, which calls
   `countof(std::declval<bytes_allocator>())`.
3. `countof` has default template parameters
   `T = detail_countof::trait<C>` and `R = decltype(T::countof(...))`.
   MSVC eagerly evaluates these even when `trait<C>` is incomplete (no
   specialization for `<C, false, false>` when `C` is not an array).
4. The evaluation of `trait_has_size<bytes_allocator>` triggers further SFINAE
   checks that re-enter `span`'s converting constructor, creating an infinite
   loop.

GCC and Clang correctly apply two-phase name lookup and do not eagerly evaluate
the default parameters, so the recursion never occurs.

**Fix:**
`CMakeLists.txt` — enable MSVC's standard conformance mode:

```cmake
if (MSVC)
    add_compile_options(/permissive-)
```

`/permissive-` enforces standard two-phase name lookup and proper SFINAE rules,
matching GCC/Clang behavior. No changes to `generic.h` or `span.h` were needed.

---

## 2. Process Management — POSIX APIs Unavailable

**Symptom:**
Compilation errors in `include/libipc/proto/process_manager.h`:
`cannot open source file 'unistd.h'`, `'pid_t': undeclared identifier`,
`'posix_spawn': identifier not found`, etc.

**Root cause:**
The process manager was written using POSIX-only APIs:

| POSIX API          | Purpose                    |
| ------------------ | -------------------------- |
| `posix_spawn`      | spawn child processes      |
| `kill(pid, 0)`     | check process liveness     |
| `kill(pid, SIGTERM)`| request graceful shutdown  |
| `kill(pid, SIGKILL)`| force-kill a process      |
| `waitpid`          | wait for process exit      |
| `pid_t`            | process identifier type    |

None of these exist on Windows.

**Fix:**
`include/libipc/proto/process_manager.h` — full Windows implementation behind
`#ifdef _WIN32`:

| POSIX                  | Windows equivalent                          |
| ---------------------- | ------------------------------------------- |
| `pid_t`                | `DWORD` (process ID) + `HANDLE` (process)   |
| `posix_spawn`          | `CreateProcessA`                             |
| `kill(pid, 0)`         | `GetExitCodeProcess` → `STILL_ACTIVE`        |
| `kill(pid, SIGTERM)`   | `TerminateProcess(h, 1)`                     |
| `kill(pid, SIGKILL)`   | `TerminateProcess(h, 9)`                     |
| `waitpid(WNOHANG)`    | `WaitForSingleObject(h, ms)`                 |
| `WIFEXITED / WEXITSTATUS` | `GetExitCodeProcess`                      |

**Key detail — handle lifetime:**
On Windows, `CreateProcess` returns both a process ID (`DWORD`) and a process
handle (`HANDLE`). The handle is stored in `process_handle::hprocess` and is
required for all subsequent operations (`WaitForSingleObject`,
`GetExitCodeProcess`, `TerminateProcess`). The thread handle returned by
`CreateProcess` is closed immediately as it is not needed.

**Trade-off — graceful shutdown:**
Windows has no direct equivalent of `SIGTERM`. `TerminateProcess` is always a
hard kill (similar to `SIGKILL`). For true graceful shutdown on Windows, the
service process should monitor a named event or a control channel. The current
implementation uses `TerminateProcess` for both `request_shutdown` and
`force_kill`, which is acceptable for the demo use case.

---

## 3. Service Registry — PID Type and Liveness Check

**Symptom:**
Compilation errors in `include/libipc/proto/service_registry.h`:
`'pid_t': undeclared identifier`, `'kill': identifier not found`,
`'getpid': identifier not found`.

**Root cause:**
The service registry uses `pid_t`, `kill(pid, 0)` for liveness detection, and
`getpid()` for the current process ID — all POSIX-only.

**Fix:**
`include/libipc/proto/service_registry.h` — platform-conditional types and APIs:

- **PID type:** `pid_t` on POSIX, `DWORD` on Windows.
- **Liveness check:** `kill(pid, 0)` on POSIX; on Windows:

  ```cpp
  HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return false;
  DWORD code = 0;
  bool alive = ::GetExitCodeProcess(h, &code) && code == STILL_ACTIVE;
  ::CloseHandle(h);
  return alive;
  ```

  `PROCESS_QUERY_LIMITED_INFORMATION` is the minimum access right needed and
  works even for processes owned by other users (unlike `PROCESS_ALL_ACCESS`).

- **Current PID:** `getpid()` on POSIX, `_getpid()` (from `<process.h>`) on
  Windows.

**Key detail — shared memory layout:**
The `service_entry` struct is stored in shared memory. On Windows, `DWORD` is
4 bytes (same as `pid_t` on most POSIX platforms), so the struct layout remains
binary-compatible. The `flags` field provides padding alignment.

---

## 4. Real-Time Thread Priority via MMCSS

**Symptom:**
`include/libipc/proto/rt_prio.h` compiled but `set_realtime_priority()` was a
no-op on Windows, always returning `false`.

**Root cause:**
The `#else` branch (non-Apple) printed "not implemented" and returned `false`.
Windows has its own real-time scheduling mechanism: the **Multimedia Class
Scheduler Service (MMCSS)**.

**Fix:**
`include/libipc/proto/rt_prio.h` — added a `#elif defined(_WIN32)` branch that
registers the calling thread as a "Pro Audio" MMCSS task:

```cpp
DWORD taskIndex = 0;
HANDLE hTask = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);
```

**How MMCSS works:**

- The thread is boosted to priority **~26** (near real-time) for the duration of
  each audio period. This is the same mechanism used by WASAPI exclusive mode
  and professional DAWs (Cubase, Pro Tools, Reaper, etc.).
- **No elevation required** — any user-space process can call it.
- The system automatically throttles non-audio threads to prevent starvation.
- The "Pro Audio" task category is configured in the registry at
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Pro Audio`.

**Runtime dynamic linking:**

`Avrt.dll` is loaded via `LoadLibraryW` / `GetProcAddress` at runtime rather
than linked at compile time. This avoids a hard dependency on `Avrt.lib` and
handles gracefully the case where MMCSS is unavailable (e.g. Windows Server
Core).

**Fallback:**

If MMCSS is unavailable or `AvSetMmThreadCharacteristics` fails, the
implementation falls back to `SetThreadPriority(THREAD_PRIORITY_TIME_CRITICAL)`,
which gives priority **15** within `NORMAL_PRIORITY_CLASS` — usable but
significantly lower than MMCSS.

**Comparison with macOS:**

| Aspect                  | macOS                                    | Windows                                  |
| ----------------------- | ---------------------------------------- | ---------------------------------------- |
| API                     | `thread_policy_set` (Mach)               | `AvSetMmThreadCharacteristicsW` (MMCSS)  |
| Effective priority      | real-time band                           | ~26 (near real-time)                     |
| Period/deadline aware   | yes (period, computation, constraint)    | no (MMCSS uses registry-configured task) |
| Elevation required      | no                                       | no                                       |
| Fallback                | none needed                              | `SetThreadPriority(TIME_CRITICAL)` → 15  |

---

## 5. Designated Initializers Require C++20 on MSVC

**Symptom:**
`error C7555: use of designated initializers requires at least '/std:c++20'`
in `demo/audio_realtime/host.cpp` and `demo/audio_service/host.cpp`.

**Root cause:**
The demo host files used C++20 designated initializers:

```cpp
ipc::proto::service_group group(registry, {
    .service_name = "rt_audio",
    .executable   = service_bin,
    .replicas     = 2,
    .auto_respawn = true,
});
```

MSVC does not support designated initializers in C++17 mode, even with
`/permissive-`. GCC and Clang accept them as an extension in C++17.

**Fix:**
Replaced with C++17-compatible field-by-field assignment:

```cpp
ipc::proto::service_group_config cfg;
cfg.service_name = "rt_audio";
cfg.executable   = service_bin;
cfg.replicas     = 2;
cfg.auto_respawn = true;
ipc::proto::service_group group(registry, cfg);
```

---

## 6. `getpid()` in Demo Service Files

**Symptom:**
`'getpid': identifier not found` in `demo/audio_realtime/service.cpp` and
`demo/audio_service/service.cpp`.

**Root cause:**
The demo services called `::getpid()` (POSIX, from `<unistd.h>`) for diagnostic
logging. On Windows, the equivalent is `_getpid()` from `<process.h>`.

**Fix:**
A portable macro in each demo service file:

```cpp
#ifdef _WIN32
#  include <process.h>
#  define ipc_getpid() _getpid()
#else
#  include <unistd.h>
#  define ipc_getpid() ::getpid()
#endif
```

---

## Summary of Windows vs. POSIX Behavioral Differences

| Behavior                         | Linux / macOS                  | Windows                                    |
| -------------------------------- | ------------------------------ | ------------------------------------------ |
| Template SFINAE evaluation       | two-phase (standard)           | **eager** (requires `/permissive-`)         |
| Process spawn                    | `posix_spawn`                  | **`CreateProcessA`**                        |
| Process liveness check           | `kill(pid, 0)`                 | **`OpenProcess` + `GetExitCodeProcess`**    |
| Graceful shutdown signal         | `SIGTERM`                      | **`TerminateProcess`** (hard kill)          |
| Wait for process exit            | `waitpid`                      | **`WaitForSingleObject`**                   |
| Process ID type                  | `pid_t`                        | **`DWORD`**                                 |
| Current PID                      | `getpid()`                     | **`_getpid()`**                             |
| Real-time thread priority        | `SCHED_FIFO` / Mach policies   | **MMCSS "Pro Audio"** (fallback: `TIME_CRITICAL`) |
| Designated initializers (C++17)  | accepted (extension)           | **rejected** (requires C++20)               |
