<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

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

1. `monotonic_buffer_resource` has a constructor taking `thoth::span<thoth::byte>`.
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
Compilation errors in `include/thoth-ipc/proto/process_manager.h`:
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
`include/thoth-ipc/proto/process_manager.h` — full Windows implementation behind
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
Compilation errors in `include/thoth-ipc/proto/service_registry.h`:
`'pid_t': undeclared identifier`, `'kill': identifier not found`,
`'getpid': identifier not found`.

**Root cause:**
The service registry uses `pid_t`, `kill(pid, 0)` for liveness detection, and
`getpid()` for the current process ID — all POSIX-only.

**Fix:**
`include/thoth-ipc/proto/service_registry.h` — platform-conditional types and APIs:

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
`include/thoth-ipc/proto/rt_prio.h` compiled but `set_realtime_priority()` was a
no-op on Windows, always returning `false`.

**Root cause:**
The `#else` branch (non-Apple) printed "not implemented" and returned `false`.
Windows has its own real-time scheduling mechanism: the **Multimedia Class
Scheduler Service (MMCSS)**.

**Fix:**
`include/thoth-ipc/proto/rt_prio.h` — added a `#elif defined(_WIN32)` branch that
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
thoth::proto::service_group group(registry, {
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
thoth::proto::service_group_config cfg;
cfg.service_name = "rt_audio";
cfg.executable   = service_bin;
cfg.replicas     = 2;
cfg.auto_respawn = true;
thoth::proto::service_group group(registry, cfg);
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

## 7. Mixed C++ Standard — C++23 Services with a C++17 Library

**Motivation:**
Process separation decouples the language standard of each component. The IPC
library and the host application are compiled as C++17 (the project default),
while the service processes are free to use any newer standard. This is a
concrete advantage of the out-of-process architecture: each binary is linked
independently, so there is no ODR or ABI conflict between standards.

**Implementation:**
The service targets override the C++ standard in their `CMakeLists.txt`:

```cmake
set_target_properties(rt_audio_service PROPERTIES
    CXX_STANDARD 23
    CXX_STANDARD_REQUIRED ON)
```

The host and the `ipc` library remain at `CMAKE_CXX_STANDARD 17`.

**C++23 features used in the service processes:**

| Feature                  | Replaces                          | File(s)                          |
| ------------------------ | --------------------------------- | -------------------------------- |
| `std::print` / `println` | `std::printf`                    | both `service.cpp`               |
| `std::expected<T, E>`   | manual bool + early return        | both `service.cpp`               |
| `std::format`            | printf-style format strings       | both `service.cpp`               |
| `std::numbers::pi_v<T>` | literal `3.14159265f`             | `audio_realtime/service.cpp`     |
| `using enum`             | fully-qualified enum values       | `audio_service/service.cpp`      |
| `std::string_view`       | `std::string` for read-only args  | both `service.cpp`               |
| Designated initializers  | field-by-field assignment         | both `service.cpp` (C++20 in MSVC) |

**Why this works:**
The service processes communicate with the host exclusively through shared
memory and IPC channels — byte-level protocols that are standard-agnostic. The
`ipc` library's public headers use only C++17 constructs, so they compile
cleanly under both `/std:c++17` and `/std:c++23`. The service's own `.cpp` file
is the only translation unit compiled as C++23.

**Build verification:**

```text
ipc.lib              → C++17  ✓
audio_host.exe       → C++17  ✓  (links ipc.lib)
audio_service.exe    → C++23  ✓  (links ipc.lib)
rt_audio_host.exe    → C++17  ✓  (links ipc.lib)
rt_audio_service.exe → C++23  ✓  (links ipc.lib)
test-ipc.exe         → C++17  ✓
```

All targets build and run correctly in the same CMake invocation.

---

## 8. Cross-language C++↔Rust parity (wire ABI, notify, async, reaper)

Bringing Windows C++↔Rust to the parity Linux and macOS already have (per
`context/windows-parity-rfc.md`). Swift is a macOS-only SwiftPM package and is out
of scope on Windows. Verified by the xlang matrices: sync 16/16, reap 8/8, async
36/36. See also ADR-0005 (the async readiness-handle contract).

### 8.1 Cross-process condition variable — shared waiter counter

**Symptom:** Rust↔Rust round-trips hung on Windows (even same-language): the
sender's `probe` saw the receiver connect and `send` reported success, but the
receiver's `recv` timed out having pulled nothing.

**Root cause:** the Rust Windows condition variable (`condition.rs`
`WindowsCondition`) kept its waiter counter in **process-local** memory ("for the
initial port we keep it in-process"). A condition var is emulated as
semaphore + mutex + counter (the SignalObjectAndWait pattern); `broadcast()` posts
the semaphore `counter` times. With a local counter the sender's count was always
0, so `broadcast()` posted nothing and receivers slept until timeout. The C++
side worked because `win/condition.h` keeps the counter in shared memory.

**Fix:** move the counter to shared memory named `{name}_COND_SHM_` (an `i32` at
offset 0, mutated under `lock_`), byte/behaviour-exact with `win/condition.h`, so
it is cross-process **and** cross-language.

### 8.2 Ring `AlignSize` is 8 on MSVC x64 (not 16)

The ring shm name embeds `AlignSize = min(DataSize, alignof(std::max_align_t))`.
MSVC x64 `alignof(std::max_align_t)` is **8** (vs 16 on Linux/macOS x86-64, where
`long double` is 16-aligned), so the Windows ring name is
`…__QU_CONN__<name>__64__8`. Rust's `RING_ALIGN` used `libc::max_align_t`, which is
unix-only and would compute 16; it now uses an explicit `8` on `windows` so both
sides emit the same name and the peers meet.

### 8.3 Named-object namespace is a compile-time parameter

All shared kernel objects (shm, mutex, semaphore, notify events) are qualified
with a namespace prefix, default **`Local\`** (session-local `BaseNamedObjects`),
switchable to `Global\` (services / cross-session) at build time:

- C++: CMake `THOTH_IPC_WIN_OBJ_NAMESPACE` → `THOTH_IPC_WIN_OBJ_NS` macro →
  `thoth::detail::win_object_name()` in `win/to_tchar.h`, applied at the three Win32
  name sites (`shm_win.cpp`, `win/mutex.h`, `win/semaphore.h`).
- Rust: the `win-global` feature → `platform::windows::win_object_name()`.

`Local\<n>` and a bare `<n>` resolve to the same per-session kernel object, so the
default is wire-compatible with today's unqualified names; the two languages must
agree at build time.

### 8.4 Single `<Windows.h>` preamble (`imp/windows_preamble.h`)

**Symptom:** the reactor failed to compile — `RegisterWaitForSingleObject` /
`UnregisterWaitEx` were "not a member of the global namespace" — even though a
standalone TU including `<Windows.h>` had them.

**Root cause:** `WIN32_LEAN_AND_MEAN` drops the legacy thread-pool wait API. Since
`<Windows.h>` is include-guarded, a header that pulled in the lean form first
(`liveness.h` had defined it) silently stripped those symbols from every other
header sharing the TU.

**Fix:** `include/thoth-ipc/imp/windows_preamble.h` is the single place the library
includes `<Windows.h>` — never lean — and every win header routes through it.
`proto/*` keep their own lean include (winsock ordering) and are left untouched.

### 8.5 Layer-1 notify — named auto-reset Events

Windows readiness is a waitable `HANDLE`, not an fd, so the notify backend uses
**one named auto-reset Event per reader connection slot** (mirroring the POSIX
FIFO-per-slot design, which is already broadcast-correct):

- On enqueue the sender `SetEvent`s every connected slot's Event except its own.
  `SetEvent` on an already-signaled auto-reset event is idempotent (stays
  signaled — the level-triggered behaviour the fd backends have).
- Each reader waits on its own slot's Event; the wait auto-resets it, so
  `drain()` is a no-op.
- Event name (a cross-process **and** cross-language ABI): `<ns>thothntf_<16-hex
  FNV-1a of "{prefix}__THOTH_SHM__NOTIFY__{name}">_<slot>`. Byte-exact between C++
  (`notify.h` `THOTH_IPC_NOTIFY_BACKEND_WINEVENT`) and Rust (`notify.rs`
  `#[cfg(windows)]`). C++ uses TCHAR-generic `::CreateEvent` + `get_sa()`.

### 8.6 Layer-2 reactor + async — thread-pool wait

The reactor multiplexes readiness handles. Windows can't epoll/kqueue a HANDLE, so
the Windows arm of `reactor.cpp` is a thin registry over the Win32 thread pool:
`add` = `RegisterWaitForSingleObject` (`WT_EXECUTEONLYONCE`, re-armed in the
callback on `disposition::keep`); synchronous `remove` =
`UnregisterWaitEx(wait, INVALID_HANDLE_VALUE)`, which blocks until any in-flight
callback returns. A `removed` flag + erase-under-lock, with `UnregisterWaitEx`
called **outside** the lock, avoids the re-arm/free race and a lock-ordering
deadlock. The reactor/async contract is `wait_handle_t`-typed (see ADR-0005), so
C++ stdexec `async_recv` and both coroutine paths work unchanged.

Rust's `AsyncRoute` has no `tokio::AsyncFd` on Windows, so it registers the Event
with the thread pool; each callback wakes a `tokio::sync::Notify` the task awaits,
then `recv()` re-polls `try_recv` (arming `notified().enable()` before the
re-check to avoid a lost wakeup). `UnregisterWaitEx` on drop precedes freeing the
callback's `Arc<Notify>`.

### 8.7 Dead-connection reaper — process start token

The reaper's owner table is platform-neutral; only three functions are OS-specific
(`liveness.h` / `liveness.rs`):

- `self_pid()` → `GetCurrentProcessId()` (Rust previously returned 0 on non-unix —
  a bug: a Windows receiver never populated the owner table).
- `start_token(pid)` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
  `GetProcessTimes`, packing the creation `FILETIME` (100-ns ticks since 1601) as
  `(dwHighDateTime << 32) | dwLowDateTime`. This is the Windows row of the xlang §9
  cross-language token formula — **C++ and Rust must pack identically**, which the
  reap matrix's cross-language "live" cases prove.
- `is_process_alive(pid, tok)` → `OpenProcess` + `GetExitCodeProcess ==
  STILL_ACTIVE`, then a start-token compare for PID reuse. Conservative: any
  "can't determine" (OpenProcess fails for a reason other than
  `ERROR_INVALID_PARAMETER`, or the token is unreadable) errs toward **alive** —
  a live peer is never false-reaped, mirroring the POSIX EPERM policy.

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
| Layer-1 readiness primitive      | fd (FIFO / libnotify)          | **named auto-reset Event `HANDLE`**         |
| Readiness drain                  | `::read` (level-triggered)     | **no-op** (auto-reset self-resets)          |
| Layer-2 async multiplexer        | epoll/kqueue reactor thread; tokio `AsyncFd` | **`RegisterWaitForSingleObject`** (thread pool); tokio `Notify` |
| Synchronous reactor `remove`     | ack on reactor thread          | **`UnregisterWaitEx(INVALID_HANDLE_VALUE)`** |
| Condition-var waiter counter     | in the shared `pthread`/ulock state | **shared shm counter** (`{name}_COND_SHM_`) |
| Ring `alignof(max_align_t)` (x64)| 16                             | **8** (folded into the shm name)            |
| Shared-object namespace          | filesystem path                | **`Local\` (default) / `Global\`** (compile-time) |
| Reaper start token               | BSD start time / `/proc` starttime | **`GetProcessTimes` creation FILETIME**     |
