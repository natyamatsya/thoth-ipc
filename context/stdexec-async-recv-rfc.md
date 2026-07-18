# RFC: Optional stdexec async receive (senders/receivers) for libipc (C++)

- **Status:** Implemented (POSIX; Windows backend pending) — see *Implementation status* below.
- **Scope:** C++ `libipc` only (opt-in). The wire format is untouched. *(Update: the
  Layer-1 notify protocol has since been ported to Rust byte-exact so a Rust
  `send()` wakes a C++ `async_recv` and vice versa — see
  [`context/xlang-channel-abi.md`](xlang-channel-abi.md) §8. Swift not yet.)*
- **Motivating consumer:** Sourcetrail — the agent-UI control channel and the indexer's
  subprocess-result IPC, both of which currently dedicate a blocking thread per channel.
- **User docs:** [`cpp/thoth-ipc/doc/async-recv.md`](../cpp/thoth-ipc/doc/async-recv.md).

## Implementation status

Both layers landed opt-in and zero-cost when off, with a few deliberate refinements
over this draft:

- **Layer 1 backend.** A plain self-pipe/eventfd is process-local and cannot carry a
  *remote* writer's signal to the reader, so the notify object is a **named,
  cross-process** primitive: **libnotify** (`notify_post` / `notify_register_file_descriptor`)
  on macOS by default — native and multicast, so one name per channel serves all readers —
  with a **named-FIFO** fallback (Linux, or macOS via `LIBIPC_NOTIFY_FIFO`). The FIFO path
  is per reader-connection-slot to honour broadcast. Gated by `LIBIPC_NOTIFY_FD`; exposed as
  `native_wait_handle()`.
- **Layer 2.** `ipc::async_recv(route&, Scheduler)` (gated `LIBIPC_STDEXEC`, implies
  `LIBIPC_NOTIFY_FD`) + a process-global `kqueue`/`epoll` reactor thread. The reactor is
  injectable via a **C++23 concept** (`reactor_like`), not a vtable. `ipc::buffer`'s move
  ctor was made `noexcept` so `buff_t` can flow through P2300 completions. stdexec is a
  `find_package`-or-`FetchContent` dependency.
- **Pending:** the Windows named-event backend (Layer 1 is a hard error there for now) and
  the Sourcetrail consumer migration (tracked in Sourcetrail's roadmap).

## Summary

Add an **opt-in senders/receivers (P2300 / stdexec)** receive API so a C++ consumer can
wait on a channel **without a dedicated blocking thread** and compose receives into its own
execution framework (schedulers + structured cancellation). Two layers:

1. **Notify handle** (the enabler) — a per-platform waitable object signalled on enqueue, so
   a channel's readiness becomes *multiplexable* and *reactor-/event-loop-integratable*.
2. **`async_recv(scheduler) -> sender`** built on it, completing `set_value(buff_t)` on data
   and `set_stopped` on cancellation, on the caller's scheduler.

## Motivation

- `ipc::route`/`ipc::channel::recv(timeout)` blocks on the sync primitive (macOS
  `__ulock_wait`, Linux futex, Windows event). To *react* to messages, a consumer must
  dedicate a thread to the blocking `recv` loop.
- The only non-blocking primitive is `try_recv()`, which forces **polling** (perpetual idle
  wakeups + up-to-interval latency).
- ulock/futex have **no file descriptor**, so a channel cannot be registered with an event
  loop (`epoll` / `kqueue` / Qt `QSocketNotifier` / IOCP), and **multiple channels cannot be
  multiplexed on one thread** — it's one blocking thread *per channel*.
- Consumers on a senders/receivers model (e.g. Sourcetrail's `execution::ISchedulers` +
  stdexec) want to fold receives into their pipelines with structured cancellation, not
  hand-manage raw threads.

## Non-goals

- No change to the wire format or shm layout (stable, cross-language).
- (As proposed, C++-only. Since implemented, the Rust port gained a byte-exact
  notify layer that interoperates with this C++ reactor — see §8 of the xlang ABI.)
- Blocking `recv` / `try_recv` stay — this is **additive**.

## Design

### Layer 1 — Notify handle (opt-in, the enabler)

On enqueue, in addition to the existing ulock/futex wake, signal a waitable object:

| Platform | Primitive | Multiplex via |
|---|---|---|
| Linux | `eventfd` (semaphore mode) | `epoll` |
| macOS | `kqueue` `EVFILT_USER` (or a self-pipe) | `kqueue` |
| Windows | auto-reset event / IOCP packet | `WaitForMultipleObjects` / IOCP |

- Build-gated (e.g. `LIBIPC_NOTIFY_FD`); **zero cost when off** (no extra syscalls on the hot
  path; the notify object is not even created).
- Exposed as `native_wait_handle()` (an `int` fd on POSIX, `HANDLE` on Windows) so consumers
  running their *own* reactor (including Qt `QSocketNotifier`) can use Layer 1 alone.
- Correctness risk: the notify signal must stay consistent with the ulock/futex wake (no
  lost/spurious wakeups) — the same "waiters counter" care as the ulock cond thundering-herd
  fix (`context/benchmarks.md`).

### Layer 2 — stdexec async receive (opt-in, C++23)

Build-gated (`LIBIPC_STDEXEC`). A **single process-global reactor** (one `epoll`/`kqueue`
thread for *all* async channels — made possible by Layer 1's fd) drives sender completions:

```cpp
// Sender whose value completion is ipc::buff_t and whose stop completion honours the
// receiver's stop_token. Completion is scheduled on `on`.
template <stdexec::scheduler Scheduler>
sender-of<ipc::buff_t> async_recv(ipc::route& channel, Scheduler on);
```

- **Cancellation:** the sender observes the receiver's `stop_token`; `request_stop`
  unregisters the channel from the reactor and completes `set_stopped` — no thread to join.
- **Completion** hops onto the caller's `on` scheduler.
- **One reactor thread multiplexes all channels**, replacing one blocking thread per channel.

### Consumer usage (Sourcetrail)

Replaces the per-controller `jthread` + manual `inplace_stop_source`:

```cpp
// AgentControlController reader loop — no dedicated thread:
exec::repeat_effect_until(
    ipc::async_recv(m_cmd, schedulers->io())
      | stdexec::then([this](ipc::buff_t b){ onCommandBytes(std::move(b)); }),
    [this]{ return m_stop.stop_requested(); });
```

The same applies to the indexer's subprocess-result IPC (dedicated `jthread`s in
`TaskBuildIndex` today).

## Alternatives considered

1. **Sender over the existing blocking `recv` (no fd).** Gives the ergonomics + structured
   cancellation, but each `async_recv` still needs a thread blocked on the ulock (ulock can't
   be multiplexed). It **relocates** the consumer's thread into libipc without reducing the
   thread count. Acceptable only as a fallback if Layer 1 slips; not the primary path.
2. **Poll `try_recv()` on a timer.** No fd needed, but perpetual idle wakeups + latency —
   worse than a *sleeping* thread for low-traffic channels.
3. **Status quo (dedicated sleeping thread).** Correct and cheap (kernel wait, not a
   busy-spin); costs one thread per channel and non-composability. This RFC is the
   improvement over it — the win comes specifically from Layer 1 (fd → multiplexing).

## Platform notes / risks

- macOS `__ulock` has no fd; the fd source is `EVFILT_USER` (lowest overhead) or a self-pipe
  (simplest/portable). Start with the self-pipe, optimise to `EVFILT_USER`.
- Reactor thread lifecycle (lazy start, process-global, clean shutdown) needs its own design.
- Testing: extend the sync/smoke suites; add a multi-channel reactor stress + cancellation
  test.

## Rollout

1. **Layer 1** notify handle + `native_wait_handle()` (opt-in) — immediately usable by any
   external reactor (incl. Qt `QSocketNotifier`).
2. **Layer 2** `async_recv` sender + shared reactor (opt-in, C++23).
3. **Consumer migration** (Sourcetrail): `AgentControlController`, then `TaskBuildIndex` IPC,
   off dedicated `jthread`s — tracked in Sourcetrail `context/ROADMAP_STDEXEC_MIGRATION.md`.

## References

- libipc sync/waiter internals: `cpp/thoth-ipc/src/thoth-ipc/waiter.h`,
  `cpp/thoth-ipc/src/thoth-ipc/platform/apple/*`, `context/macos_ipc_roadmap.md`,
  `context/benchmarks.md`.
- Consumer design: Sourcetrail `context/DESIGN_AGENT_UI_CONTROL.md`,
  `context/ROADMAP_STDEXEC_MIGRATION.md`.
