# ADR-0005: Cross-platform Layer-2 async readiness handle

- Status: Accepted
- Date: 2026-07-12
- Owners: libipc maintainers
- Relates to: [ADR-0001](0001-sync-backend-contract-across-languages.md) (sync
  backend contract), `context/stdexec-async-recv-rfc.md` (Layer 2),
  `context/windows-parity-rfc.md` (Windows port)

## Context

Layer 2 turns a channel's readiness into an awaitable so a consumer can
multiplex many channels without one blocking recv thread each. The Layer-1
notify primitive that signals readiness is a **different kind of kernel object
per OS**, and there is no portable object that is both waitable and
multiplexable everywhere:

- **POSIX** readiness is a **file descriptor** (a FIFO on Linux, a libnotify fd
  on macOS) — pollable with epoll/kqueue and level-triggered (a wake token must
  be consumed).
- **Windows** readiness is a **waitable `HANDLE`** — a named auto-reset Event,
  waitable with `WaitForMultipleObjects` / the thread-pool wait API, and
  one-shot (the wait itself consumes the signal).

The C++ reactor, `async_recv.h` (stdexec) and `coro_recv.h` originally hard-wired
`int fd` + `<unistd.h>`/`::read`. That is POSIX-only: a 64-bit Windows `HANDLE`
cannot round-trip through `int`, and there is no fd to `read`. We needed one
contract that both the stdexec front end and the coroutine front end depend on,
implemented natively on each OS, without a portable-but-slow fallback (e.g. a
per-channel polling thread).

## Decision

Model readiness as a single opaque, platform-typed handle and keep the reactor
contract in terms of it.

### 1) `ipc::wait_handle_t` is the readiness type

- C++ (`ipc.h`): `using wait_handle_t = int` (fd) on POSIX, `void*` (HANDLE) on
  Windows; `invalid_wait_handle` = `-1` / `nullptr`.
- Rust (`notify::WaitHandle`): `RawFd` on unix, `isize` (a HANDLE as a
  `Send`-safe pointer-sized int) on Windows; `INVALID_WAIT_HANDLE` = `-1` / `0`.
- `native_wait_handle()` returns it; the notify sink owns the underlying object's
  lifetime.

### 2) The reactor contract is handle-typed, not fd-typed

`reactor_like` and `reactor::add/remove` take `wait_handle_t`. On POSIX the value
is used directly as the epoll/kqueue fd (a `static_cast<int>` at the syscall
boundary — zero behaviour change); on Windows it is a HANDLE registered with the
wait. `add` is asynchronous; `remove` is **synchronous** (once it returns,
`on_ready()` for that waiter is neither running nor about to start), so a caller
may destroy the waiter. `remove` must never be called from within `on_ready()`.

### 3) Each OS uses its native readiness mechanism behind that contract

| | POSIX | Windows |
| --- | --- | --- |
| Notify object | FIFO / libnotify fd | named auto-reset Event |
| C++ reactor | one epoll/kqueue thread | `RegisterWaitForSingleObject` (thread pool) |
| Synchronous `remove` | ack'd on the reactor thread | `UnregisterWaitEx(INVALID_HANDLE_VALUE)` |
| Rust async | `tokio::AsyncFd` | thread-pool wait → `tokio::sync::Notify` |
| `drain_wait_handle` | `::read` the level-triggered tokens | no-op (auto-reset self-resets) |

The stdexec senders/receivers (`async_recv.h`), the coroutine path
(`coro_recv.h`) and `recv_result.h` are platform-neutral and unchanged across
OSes once the reactor and `drain_wait_handle` are handle-typed.

### 4) Level-triggered vs one-shot is absorbed by the backend

POSIX readiness is level-triggered, so `drain_wait_handle()` consumes pending
tokens before re-checking. A Windows auto-reset Event is one-shot, so
`drain_wait_handle()` is a no-op and re-arming is the backend's job (the reactor
re-registers on `disposition::keep`; the Rust wait auto-re-arms). Callers see one
uniform "wait, then `try_recv`" loop.

## Consequences

### Positive

- One reactor contract and one async API across POSIX and Windows; the front ends
  (stdexec, coroutine, Rust `AsyncRoute`) are written once.
- Native primitives on each OS — no portable polling thread, no per-recv thread.
- Adding a platform means implementing one notify backend + one reactor arm;
  nothing above the reactor changes.

### Trade-offs

- `wait_handle_t` is a type alias, not a strong type, so a POSIX `int` and a
  Windows HANDLE are not interchangeable — correct, but it relies on the notify
  backend and reactor arm agreeing per target.
- Windows callbacks run on arbitrary thread-pool threads (POSIX serialises on one
  reactor thread). Each callback touches only its own waiter/channel, so this is
  safe, but it is an intentional concurrency difference to keep in mind.
- The Windows `remove`/drop path must call `UnregisterWaitEx(INVALID_HANDLE_VALUE)`
  **outside** its lock (it blocks until in-flight callbacks return, which need the
  lock) or it deadlocks — a sharp edge the POSIX ack path does not have.

## Alternatives considered

1. **Keep the reactor fd-typed; fake an fd on Windows.** Rejected: a HANDLE does
   not fit in an `int`, and there is no readable fd to drain.
2. **A portable polling thread per channel (or a `spawn_blocking` wait per recv).**
   Rejected for the reactor/`AsyncFd` path: defeats the purpose of Layer 2
   (thread-per-channel) and wastes threads. `spawn_blocking` remains a valid
   simple fallback for non-tokio users.
3. **IOCP / `WaitOnAddress` on Windows instead of the thread-pool wait.** Deferred
   as a performance optimisation. `RegisterWaitForSingleObject` maps cleanly onto
   the existing synchronous-`remove` contract and is correct first; a more
   heavily optimised native demultiplexer can replace the Windows arm later
   without touching the contract or the front ends.
