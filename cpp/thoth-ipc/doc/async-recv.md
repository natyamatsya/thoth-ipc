<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

# Async receive — readiness handles & stdexec senders

Two **opt-in, additive** layers that let a C++ consumer wait on a channel
*without dedicating a blocking thread per channel*, and multiplex many channels
on one event loop. Blocking `recv()` / `try_recv()` are unchanged; when the
layers are disabled there is **zero cost** — no extra members, no extra syscalls
on the send hot path, and the notify objects are never created.

- **Layer 1 — readiness handle** (`THOTH_IPC_NOTIFY_FD`): a per-receiver waitable
  kernel object, signalled on enqueue, exposed as `native_wait_handle()`.
  Usable directly from any reactor (`epoll` / `kqueue` / `poll` / Qt
  `QSocketNotifier` / `WaitForMultipleObjects`).
- **Layer 2 — stdexec sender** (`THOTH_IPC_STDEXEC`, C++23): `thoth::async_recv()`,
  a P2300 senders/receivers receive API driven by one process-global reactor
  thread. Built on Layer 1.

Motivation and design rationale: [`context/stdexec-async-recv-rfc.md`](../../../context/stdexec-async-recv-rfc.md).

## Why

`thoth::route::recv(timeout)` blocks on the sync primitive (macOS `__ulock_wait`,
Linux futex, Windows event). To *react* to messages a consumer must dedicate a
thread to a blocking `recv` loop, and those primitives have **no file
descriptor**, so a channel cannot be registered with an event loop and multiple
channels cannot share one thread. `try_recv()` avoids the thread but forces
polling (idle wakeups + latency). Layer 1 gives the channel an fd; Layer 2 folds
receives into a senders/receivers pipeline with structured cancellation.

## Build flags

| Option | Default | Effect |
|---|---|---|
| `THOTH_IPC_NOTIFY_FD` | `OFF` | Layer 1: enable `native_wait_handle()`. POSIX only for now. |
| `THOTH_IPC_NOTIFY_FIFO` | `OFF` | Force the portable FIFO backend even on macOS (default there is libnotify). No effect off Apple. |
| `THOTH_IPC_STDEXEC` | `OFF` | Layer 2: `thoth::async_recv()` + reactor. Requires C++23; **implies `THOTH_IPC_NOTIFY_FD`**. |

When `THOTH_IPC_STDEXEC` is on, the stdexec dependency is **injectable**:
`find_package(stdexec CONFIG)` is used if it resolves (e.g. from vcpkg/Conan or a
parent build); otherwise it is fetched via `FetchContent` at the pinned
NVIDIA/stdexec ref. `THOTH_IPC_NOTIFY_FD` and `THOTH_IPC_STDEXEC` are compiled as
`PUBLIC` definitions, so downstream code can feature-test them
(`#if defined(THOTH_IPC_STDEXEC)`).

## Layer 1 — the readiness handle

`native_wait_handle()` returns a native handle (an `int` fd on POSIX, a `HANDLE`
on Windows) that becomes readable/signalled whenever a message is enqueued for
that receiver, or `thoth::invalid_wait_handle` if the library was built without
`THOTH_IPC_NOTIFY_FD` or the channel is not connected as a receiver.

```cpp
thoth::route ch{"my.channel", thoth::receiver};
int fd = ch.native_wait_handle();          // register with your own reactor
// ... when the reactor reports fd readable:
//   1. drain fd (read until EAGAIN)
//   2. drain the channel: while ((b = ch.try_recv()), !b.empty()) handle(b);
```

**Contract (edge/level agnostic):** treat readability as "a message *may* be
available." On a wakeup, drain the fd and then `try_recv()` until empty. The
readiness signal and the message are independent objects; the enqueue-to-shm
happens-before the readiness signal, so draining after a wakeup never misses a
message.

The handle is owned by the channel and stays valid until disconnect/destruction
— **do not close it yourself.**

### Cross-process backends

libipc synchronises writer and reader *across processes*, so the notify object
must be a **named, cross-process, fd-bearing** primitive (a plain
self-pipe/eventfd is process-local and cannot carry a remote writer's signal).

| Platform | Backend | Primitive | Notes |
|---|---|---|---|
| macOS | libnotify (default) | `notify_register_file_descriptor` / `notify_post` | Native Darwin service; **multicast**, so one name per channel serves all readers. No filesystem node. |
| macOS | FIFO (`THOTH_IPC_NOTIFY_FIFO`) | `mkfifo` | Portable fallback. |
| Linux / other POSIX | FIFO | `mkfifo` | Default. |
| Windows | *not yet implemented* | named event (planned) | Building `THOTH_IPC_NOTIFY_FD` on Windows is a hard error for now. |

Because a FIFO is point-to-point, the FIFO backend honours broadcast (`route`
1→N, `channel` N→N) by giving **each reader connection slot its own FIFO** and
poking every connected slot on enqueue. libnotify is natively multicast, so it
needs only one name per channel. FIFO paths default to `/tmp`, overridable with
the `THOTH_IPC_NOTIFY_DIR` environment variable.

## Layer 2 — `thoth::async_recv()`

```cpp
#include "thoth-ipc/async_recv.h"

template <stdexec::scheduler Scheduler>
stdexec::sender auto async_recv(thoth::route& channel, Scheduler on);
```

Returns a sender whose **error channel is pruned** (never `set_error`): failures
travel as data on the value channel (the consuming project's ADR-0001 —
domain/exceptional errors as `std::expected`), so a downstream exception-free
pipeline stays exception-free. It completes:

- `set_value(thoth::recv_result)` — where `recv_result = std::expected<thoth::buff_t,
  thoth::recv_errc>` — with the message, or an `thoth::recv_errc`; **hopped onto the
  `on` scheduler** (via `continues_on`);
- `set_stopped()` when the receiver's `stop_token` is triggered.

`thoth::recv_errc` is a small enum: `no_readiness_handle` (channel lacks a
readiness fd — built without `THOTH_IPC_NOTIFY_FD`, or not a receiver),
`out_of_memory`, and `unknown`. Exceptions from the receive (e.g. `bad_alloc`)
are caught and mapped to a `recv_errc`, so nothing escapes as an exception.

A single **process-global reactor thread** (`thoth::detail::reactor`, one
`kqueue`/`epoll` for *all* async channels) drives completions, so N channels
cost one thread instead of N. Cancellation unregisters the channel from the
reactor and completes `set_stopped` — there is no thread to join.

### Example — a reader loop with no dedicated thread

```cpp
exec::repeat_effect_until(
    thoth::async_recv(cmd_channel, schedulers.io())
      | stdexec::then([&](thoth::buff_t b){ on_command(std::move(b)); }),
    [&]{ return stop.stop_requested(); });
```

### Dependency injection (concept, not vtable)

The reactor is injectable through a **C++23 concept**,
`thoth::detail::reactor_like`, rather than an abstract base — idiomatic for this
template-heavy library and free of virtual dispatch on the hot path. An
overload accepts any type modelling it:

```cpp
template <stdexec::scheduler Scheduler, detail::reactor_like R>
stdexec::sender auto async_recv(thoth::route& channel, Scheduler on, R& reactor);
```

A test can substitute a fake reactor that captures the registered waiter and
drives `on_ready()` deterministically — no real `kqueue`/`epoll` thread:

```cpp
struct fake_reactor {                              // models reactor_like
    thoth::detail::reactor_waiter* w = nullptr;
    void add(int, thoth::detail::reactor_waiter* x)    { w = x; }
    void remove(int, thoth::detail::reactor_waiter* x) { if (w == x) w = nullptr; }
};
// ... start(connect(async_recv(reader, sched, fake), rcvr));
// send a message, then: fake.w->on_ready();  // completion fires deterministically
```

(`reactor_waiter`, the op-side readiness callback, stays a small runtime
interface: the reactor's registry type-erases heterogeneous waiters into
`reactor_waiter*`.)

## Coroutines (`co_await`)

For consumers who prefer `.await`-style syntax (mirroring the Rust/Swift
`AsyncRoute`), there are two paths over the same Layer-1 fd + reactor:

**(a) With stdexec — free.** The `async_recv` sender is directly awaitable in any
sender-aware coroutine (P2300 `as_awaitable`), e.g. `exec::task`:

```cpp
#include <exec/task.hpp>
exec::task<void> pump(thoth::route& r) {
    auto sched = co_await stdexec::read_env(stdexec::get_scheduler);
    for (;;) {
        thoth::recv_result msg = co_await thoth::async_recv(r, sched);  // same reactor
        if (!msg) break;
        dispatch(msg->data(), msg->size());
    }
}
```

No extra library code — structured cancellation (stop-tokens) and composition all
still apply. This is the recommended path if you already use stdexec.

**(b) Without stdexec — `thoth-ipc/execution/coro_recv.h`.** A standalone C++20
awaiter that needs only `THOTH_IPC_NOTIFY_FD` (the reactor is compiled with Layer 1,
independent of stdexec) — no P2300 dependency:

```cpp
#include "thoth-ipc/execution/coro_recv.h"
thoth::coro::task<int> pump(thoth::route& r) {
    for (;;) {
        thoth::recv_result msg = co_await thoth::coro::async_recv_co(r);
        if (!msg) co_return 1;
        dispatch(msg->data(), msg->size());
    }
}
// drive it: pump(r).sync_wait();   // batteries-included minimal task
```

The awaiter parks the readiness fd on the reactor and resumes the coroutine
**on the reactor thread** (hop to your executor after if needed). Single‑consumer;
destroying the coroutine while a `co_await` is suspended is safe (the awaiter
unregisters synchronously in its destructor). Verified cross-process by the
`tools/xlang-runner` async matrix (harness `xcoro`, no stdexec).

## Semantics & caveats

- **Error channel:** pruned (ADR-0001). All outcomes ride the value channel as
  `std::expected<thoth::buff_t, thoth::recv_errc>`; cancellation is `set_stopped`.
  Because the channel is pruned and completions are `noexcept`, a genuinely
  exceptional failure that we do *not* map (nothing today — `try_recv`'s
  `bad_alloc` becomes `recv_errc::out_of_memory`) would hit the `noexcept`
  boundary and `std::terminate` rather than surface as `set_error`.
- **Cancellation race:** if a message is popped on the reactor thread at the
  exact instant `request_stop` wins, that one message is discarded as part of
  teardown. This is standard for async cancellation and is documented at the
  call site.
- **Reactor lifecycle:** the reactor is a lazy, process-global singleton, joined
  cleanly at static destruction. `remove()` is synchronous — once it returns,
  `on_ready()` for that waiter neither runs nor starts again, so the operation
  state is safe to destroy.
- **`thoth::buffer` move is `noexcept`**, as required for values to flow through
  P2300 completions (and for noexcept-move std containers).

## Non-goals

No change to the wire format or shm layout (stable, cross-language).

## Cross-language

The **Layer-1 notify protocol is now part of the cross-language ABI**: the Rust
port (`rust/thoth-ipc`, features `notify` / `async-tokio`) implements a byte-exact
`notify_source`/`notify_sink` (same libnotify key / FIFO paths — see
[`context/xlang-channel-abi.md`](../../../context/xlang-channel-abi.md) §8), so a
Rust `send()` wakes a C++ `async_recv` and a C++ `send()` wakes a Rust
`AsyncRoute::recv().await`. This is verified by the async matrix
(`tools/xlang-runner --scenario async`, CI: `.github/workflows/xlang.yml`).
Swift too: the notify source/sink are byte-exact (`Notify.swift`) and
`AsyncRoute.recv() async` (over the readiness fd via `DispatchSource`) is woken by
a C++/Rust/Swift sender — verified by the full 3-language async matrix.

## See also

- [`context/stdexec-async-recv-rfc.md`](../../../context/stdexec-async-recv-rfc.md) — full RFC.
- [`context/xlang-channel-abi.md`](../../../context/xlang-channel-abi.md) §8 — the byte-exact notify protocol.
- Headers: `include/thoth-ipc/ipc.h` (`native_wait_handle`),
  `include/thoth-ipc/async_recv.h` (senders), `include/thoth-ipc/execution/coro_recv.h`
  (coroutines), `include/thoth-ipc/execution/reactor.h`,
  `include/thoth-ipc/execution/recv_result.h`.
- Tests: `test/test_notify.cpp`, `test/test_async_recv.cpp`.
