# RFC: Windows parity for thoth-ipc (ABI, notify, async, reaper)

- **Status:** **Implemented (C++↔Rust) and validated on Windows — 2026-07-12.**
  All six phases landed; the sync (16/16), reap (8/8) and async (36/36) xlang
  matrices are green on `windows-latest`/MSVC. Original proposal (authored on
  macOS, untested there) retained below as the design record; see the corrections
  immediately following and the durable reference in
  [`../cpp/thoth-ipc/doc/windows-technical-notes.md`](../cpp/thoth-ipc/doc/windows-technical-notes.md)
  and [`../doc/adr/0005-cross-platform-async-readiness-handle.md`](../doc/adr/0005-cross-platform-async-readiness-handle.md).

## Corrections found during implementation

Three assumptions in the proposal below were wrong on real hardware:

1. **Sync was NOT fully working on Windows.** The proposal treated Windows sync
   primitives as done. In fact the Rust Windows **condition variable kept its
   waiter counter in process-local memory**, so every cross-process `broadcast()`
   was a no-op and receivers never woke — even Rust↔Rust. Fixed by moving the
   counter to shared memory (`{name}_COND_SHM_`), byte/behaviour-exact with C++
   `win/condition.h`. This, not the ABI, was the real Phase-1 blocker.
2. **AlignSize is 8 on windows-msvc x64, not 16.** MSVC `alignof(max_align_t)` == 8
   (vs 16 on Linux/macOS x86-64), so the ring name is `…__QU_CONN__<name>__64__8`.
   §1.2's "verify it equals 16 / use `align_of::<u128>()`" would have *broken*
   parity; Rust uses an explicit 8 on Windows.
3. **The reactor and async/coro headers were `int fd`-typed, not
   `wait_handle_t`-typed** (§3 assumed otherwise). Windows HANDLEs can't
   round-trip through `int`, so `reactor.{h,cpp}`, `async_recv.h`, `coro_recv.h`
   were widened to `thoth::wait_handle_t` (a bigger change than §3 implied). A
   `windows_preamble.h` was also added so a lean `<Windows.h>` in one header can
   never strip the thread-pool wait API from the reactor's TU.
- **Scope:** bring Windows **C++↔Rust** to the parity macOS and Linux already
  have: the byte-exact wire ABI, Layer-1 notify, Layer-2 async (C++ stdexec
  senders **and** both coroutine paths; Rust `AsyncRoute`), and the
  dead-connection reaper. **Swift is a macOS-only SwiftPM package and is out of
  scope on Windows.**
- **Relates to:** [`os-parity.md`](os-parity.md),
  [`xlang-channel-abi.md`](xlang-channel-abi.md) (§2 spin_lock, §8 notify, §9
  liveness), [`stdexec-async-recv-rfc.md`](stdexec-async-recv-rfc.md),
  [`dead-connection-reaper-rfc.md`](dead-connection-reaper-rfc.md).

## Current Windows state

What already works:
- **Sync primitives + shm** are implemented for Windows
  (`cpp/thoth-ipc/src/thoth-ipc/platform/win/{mutex,semaphore,condition}.h`,
  `shm_win.cpp`; Rust uses `windows-sys` `Win32_System_Memory`). C++↔C++
  messaging builds and runs on Windows (the `build-windows` CI job exercises it).
- **Ring/chunk `spin_lock`.** Windows has no `platform/win/spin_lock.h`, so it
  uses C++'s **generic** `thoth::spin_lock` (`rw_lock.h`) — an `atomic<u32>`
  test-and-set spin, the same lock the Linux parity work just matched. The Rust
  port's non-Apple `AtomicU32` TAS at `lc_`@4 / `lock_`@36 therefore **already
  covers Windows byte-for-byte in principle** — pending the layout verification in
  §1.

What is missing or stubbed (the work):
- **Notify (Layer 1):** C++ is a hard `#error` on Windows (`notify.h:36`); the
  Rust `notify` / `async-tokio` features are unix-only and do not compile on
  Windows. ❌
- **Reactor (Layer 2):** `reactor.cpp` has kqueue/epoll only. ❌
- **Async recv:** blocked on notify + reactor (C++), and on a Windows readiness
  primitive (Rust). ❌
- **Reaper liveness:** `is_process_alive` → `true`, `start_token` → `0`, and Rust
  `self_pid` → `0` on non-unix (`liveness.h:96,146`, `liveness.rs`
  `#[cfg(not(unix))]`). Safe (never false-reaps) but inert — and `self_pid == 0`
  means a Windows receiver does not even populate the owner table. ❌

`native_wait_handle()` already returns the right type on Windows —
`wait_handle_t = void*` (a `HANDLE`), invalid = `nullptr` (`ipc.h:28`).

## 1. Wire ABI — verify (should be nearly free)

The generic `spin_lock` already matches, so the DCLP init and chunk-pool critical
sections should serialise C++↔Rust on Windows with the `AtomicU32` TAS already in
the tree. Confirm:

1. `cargo check --lib --target x86_64-pc-windows-msvc` (base, `--features notify`,
   `--features async-tokio`) passes — the `offset_of!`/`size` const-asserts in
   `RingHeader` and `ChunkInfo` are the byte-exactness proof; they fail to compile
   if the Windows layout drifts.
2. **AlignSize risk.** The ring shm name embeds
   `AlignSize = min(64, alignof(max_align_t))` = **16** on x64. C++ computes it;
   the Rust port uses `align_of::<libc::max_align_t>()` (`channel.rs` `RING_ALIGN`).
   `libc::max_align_t` may not exist / may differ on `windows-msvc`. Verify it
   equals 16; if not, compute `AlignSize` a target-portable way (e.g.
   `align_of::<u128>()` on x64, or a per-target const) so both sides emit
   `QU_CONN__<name>__64__16`.
3. **Shm/object names.** Confirm C++ (`shm_win.cpp`) and the Rust Windows shm
   produce identical file-mapping names for the same channel, including the
   namespace (`Local\` vs `Global\`) and any `THOTH_IPC_SHM_NAME_MAX` FNV-shortening.
   Mismatch here means the peers never meet.

**Deliverable:** the sync xlang matrix (`--lang cpp/rust`) green on Windows.

## 2. Layer-1 notify — named-Event backend

POSIX readiness is an fd (epoll/kqueue-able); Windows readiness is a waitable
kernel object `HANDLE` (WaitForMultipleObjects-able). Mirror the POSIX **FIFO
per-slot** design (which is already broadcast-correct) rather than libnotify's
multicast:

- **Model:** one **named auto-reset Event per reader connection slot**. On
  enqueue the sender `SetEvent`s every connected slot's event except its own; each
  reader waits on its own slot's event.
  - *Why per-slot auto-reset:* an auto-reset event wakes exactly the intended
    reader and self-resets; `SetEvent` on an already-signaled event is idempotent
    (stays signaled ⇒ "unconsumed token still pending", the level-triggered
    behaviour the fd backends have). A single manual-reset event cannot be reset
    without racing, and would wake all N readers on every post. Per-slot also
    matches the owner/slot model and `ctz(connected_id)` indexing.
- **Naming (a Windows-internal C++↔Rust ABI):**
  `Local\ipcntf_<16-hex FNV-1a of "{prefix}__IPC_SHM__NOTIFY__{name}">_<slot>`,
  `slot = ctz(connected_id)`, `slot ∈ 0..31`. Same hash as the POSIX backends
  (`fnv1a_64`); C++ and Rust on Windows must agree byte-for-byte.
- **C++ (`notify.h`):** replace the `#error` with a
  `THOTH_IPC_NOTIFY_BACKEND_WINEVENT` block. `notify_source::signal(prefix, name,
  conns, self)` opens (`OpenEventW`/`CreateEventW`) and `SetEvent`s each connected
  slot (skip `self`), caching handles like the FIFO source caches fds.
  `notify_sink::open(prefix, name, slot_bit)` `CreateEventW`s its slot's event
  (auto-reset, initially non-signaled); `native_handle()` returns the `HANDLE`;
  `drain()` is a no-op (the wait auto-resets); `close()` `CloseHandle`s.
- **Rust (`notify.rs`):** a `#[cfg(windows)]` backend over `windows-sys`
  `Win32_System_Threading` (`CreateEventW`/`OpenEventW`/`SetEvent`) +
  `Win32_Foundation` (`CloseHandle`), exposing the same `NotifySource`/
  `NotifySink` API; `native_handle()` returns the `RawHandle`
  (`isize`/`HANDLE`). Make the `notify` feature compile on Windows.
- **Golden test:** extend the existing `notify_hash` golden unit test — the hash
  is platform-independent, so it already pins the name; add a Windows event-name
  assembly test.

## 3. Layer-2 reactor + async

### C++ reactor (`reactor.cpp`)

Windows can't epoll/kqueue a `HANDLE`. Two options:

- **(A) `RegisterWaitForSingleObject`** (Win32 thread-pool wait) — register each
  waiter's `HANDLE` with a callback that runs `on_ready()`. Scales past 64 handles
  and maps cleanly onto the existing contract: `add` = `RegisterWaitForSingleObject`
  (flags `WT_EXECUTEDEFAULT`; add `WT_EXECUTEONLYONCE` and re-register in
  `on_ready` if `disposition::keep`); `remove` =
  `UnregisterWaitEx(wait, INVALID_HANDLE_VALUE)`, which **blocks until pending
  callbacks finish** — satisfying the reactor's *synchronous* `remove()` contract
  (must not be called from within `on_ready`, same rule as POSIX).
- **(B)** a thread running `WaitForMultipleObjects` on ≤64 handles + a wake event,
  with grouping for >64. More code, no thread-pool dependency.

**Recommend (A):** the Windows reactor becomes a thin registry over the OS thread
pool. Add a `#elif defined(THOTH_IPC_OS_WIN)` arm to `reactor.cpp` (today `#else`
means epoll). The `reactor.h` interface and `reactor_waiter` contract are already
`wait_handle_t`-typed and unchanged.

**Payoff:** once the reactor waits `HANDLE`s, **C++ stdexec `async_recv` and both
coroutine paths work unchanged** — `recv_result`, `async_recv.h`, and
`coro_recv.h` are platform-neutral and only need `native_wait_handle()` + the
reactor.

### Rust async (`async_recv.rs`)

tokio has no `AsyncFd` on Windows. Options:

- **(A)** register the event `HANDLE` with `RegisterWaitForSingleObject`; the
  callback wakes the task's `Waker`; `recv()` re-polls `try_recv` after each wake
  (mirrors the unix `AsyncFd` loop, HANDLE-based, no per-recv thread).
- **(B)** `tokio::task::spawn_blocking` around a bounded `WaitForSingleObject` +
  `try_recv` (simplest; one blocking-pool thread per in-flight recv).

**Recommend (A)** for parity with the unix design. Put it behind `#[cfg(windows)]`
in the async module; the public `AsyncRoute::recv().await` API is identical. Make
`async-tokio` compile on Windows (tokio itself is fine there; only the `AsyncFd`
usage is unix).

## 4. Dead-connection reaper — Windows liveness

Only three functions are platform-specific; the owner table (`LV_CONN__`, 16-byte
`slot_owner`, offsets) is already platform-neutral.

- **`self_pid()`** → `GetCurrentProcessId()` (C++ already does this;
  **Rust currently returns 0 — a bug**: fix so Windows receivers populate the
  table).
- **`is_process_alive(pid, tok)`** → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
  FALSE, pid)`; if the handle opens, `GetExitCodeProcess == STILL_ACTIVE` (or
  `WaitForSingleObject(h, 0) == WAIT_TIMEOUT`) ⇒ alive, then compare the start
  token; `CloseHandle`. **Conservative:** any "can't determine" (open fails for a
  reason other than "no such process", or token unreadable) ⇒ **alive**, so a
  live-but-idle peer is never false-reaped — identical policy to POSIX.
- **`start_token(pid)`** → `GetProcessTimes(h, &creation, …)`; pack the creation
  `FILETIME` (100-ns ticks since 1601) into a u64 (`(dwHighDateTime << 32) |
  dwLowDateTime`). This is the Windows row of the §9 cross-language token formula
  — **C++ and Rust on Windows must pack identically.** 0 = couldn't determine.
- Implement in C++ `liveness.h` (replace the TODO stubs) and Rust `liveness.rs`
  (`#[cfg(windows)]`).

**Deliverable:** the reap matrix green C++↔Rust on Windows (a held receiver
`TerminateProcess`d is reclaimed; a live one is not).

## 5. Testing & CI

- Compile-time: `cargo check --target x86_64-pc-windows-msvc` (base + `notify` +
  `async-tokio`) must pass — this alone proves the byte-exact layout on Windows.
- A **Windows xlang job** in `.github/workflows/xlang.yml`. Because push triggers
  are disabled for budget, run it via `workflow_dispatch` / PR. It builds the C++
  harnesses (`THOTH_IPC_STDEXEC=ON` ⇒ `xlang_ipc`, `xasync`, `xcoro`) and the Rust
  harness (`--features async-tokio`) on `windows-latest`, then runs
  `xlang_matrix.py` with `--lang`, `--async-lang`, and `--reap-lang` for
  `cpp`/`rust`/`coro`.
- The harness `caps` verb already fails the async matrix fast if a Windows
  harness was built without notify/async; the Windows harnesses report
  `notify async` once §2/§3 land.
- The reap matrix's kill maps to `TerminateProcess` via the Python driver's
  `.kill()` — no driver change needed.

## 6. Phasing (each independently landable)

1. **ABI verify + AlignSize/shm-name fix** — sync matrix green on Windows. *(small)*
2. **Reaper liveness** (`self_pid`/`is_process_alive`/`start_token`) — reap matrix
   green; the reaper becomes functional (currently safe but inert). *(small)*
3. **Notify named-Event backend** (C++ + Rust) — a Windows readiness `HANDLE`.
   *(medium)*
4. **C++ reactor (`RegisterWaitForSingleObject`)** — C++ stdexec + coroutine async
   matrices green (no async_recv/coro changes). *(medium)*
5. **Rust Windows `AsyncRoute`** — Rust async matrix green. *(medium)*
6. **Windows CI job** — lock it in (manual/PR). *(small)*

Do 1–2 first: they are small, make the reaper work, and prove the ABI, before the
larger notify/reactor/async work in 3–5.

## 7. Open questions to resolve on Windows

- `libc::max_align_t` on `windows-msvc` for `AlignSize` — verify (=16) or replace.
- Object namespace: `Local\` (same session — the agent-bridge case) vs `Global\`
  (services / multi-session). Default `Local\`; make it configurable if a
  Windows-service peer ever needs `Global\` (also affects shm/mutex names).
- Whether `shm_win.cpp` already FNV-shortens names like the POSIX path
  (`THOTH_IPC_SHM_NAME_MAX`) — align the notify event names with whatever it does.
- `UnregisterWaitEx(…, INVALID_HANDLE_VALUE)` must satisfy the synchronous
  `remove()` contract without deadlocking — confirm it is never reached from
  inside a wait callback (same discipline as POSIX `remove()`).
- Auto-reset vs manual-reset for the case where a message arrives, the reader is
  mid-`try_recv`, and a second `SetEvent` fires — verify the "stays signaled ⇒
  next wait returns immediately" behaviour holds and doesn't drop a wakeup.
