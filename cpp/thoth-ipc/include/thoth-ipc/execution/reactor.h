#pragma once

// A single process-global reactor thread that multiplexes every async channel's
// readiness fd (Layer 1's native_wait_handle) on one kqueue/epoll, replacing one
// blocking recv thread per channel. It has no stdexec dependency — only fds — so
// it is compiled with Layer 1 (THOTH_IPC_NOTIFY_FD) and is shared by both the
// stdexec senders/receivers front end (async_recv.h) and the coroutine front end
// (coro_recv.h).
//
// This header deliberately leaks no platform or <thread>/<mutex> details
// (pimpl), so it can sit in the public include tree.

#include "thoth-ipc/imp/detect_plat.h"
#include "thoth-ipc/ipc.h" // ipc::wait_handle_t (int fd on POSIX, HANDLE/void* on Windows)

#if defined(THOTH_IPC_NOTIFY_FD)

namespace ipc {
namespace detail {

// Interest registered with the reactor for one fd. on_ready() runs on the
// reactor thread when the fd is readable; it must not block and must not call
// the reactor's remove() on itself (return disposition::remove instead).
//
// This one stays a runtime interface (not a concept): the reactor's registry
// type-erases heterogeneous waiters into reactor_waiter*.
class reactor_waiter {
public:
    enum class disposition {
        keep,    // stay registered; the fd may fire again
        remove   // auto-unregister this waiter (it completed)
    };
    virtual disposition on_ready() noexcept = 0;

protected:
    ~reactor_waiter() = default;
};

// The fd-multiplexer contract async_recv() depends on. A concept rather than an
// abstract base: each recv_op knows its reactor type statically, so there is no
// need for virtual dispatch. Consumers (and tests) inject any type that models
// it — e.g. a fake that captures the registered waiter and drives on_ready()
// deterministically instead of running the real kqueue/epoll thread.
//
//   add(h, w)     : register interest in `h` becoming ready. Asynchronous.
//   remove(h, w)  : unregister. SYNCHRONOUS — once it returns, on_ready() for
//                   `w` is guaranteed neither running nor about to start, so the
//                   caller may destroy `w`. Never call it from within on_ready().
//
// `h` is an ipc::wait_handle_t: a readiness fd on POSIX (int), a waitable Event
// HANDLE on Windows (void*). On POSIX the value is used directly as the epoll/
// kqueue fd; on Windows it is registered with the thread-pool wait.
template <class R>
concept reactor_like = requires(R &r, wait_handle_t h, reactor_waiter *w) {
    r.add(h, w);
    r.remove(h, w);
};

// Lazy, process-global fd multiplexer (kqueue/epoll thread). Models
// reactor_like. Thread-safe.
class reactor {
public:
    static reactor &instance();

    void add(wait_handle_t h, reactor_waiter *w);
    void remove(wait_handle_t h, reactor_waiter *w);

    reactor(reactor const &) = delete;
    reactor &operator=(reactor const &) = delete;

private:
    reactor();
    ~reactor();

    struct impl;
    impl *p_;
};

} // namespace detail
} // namespace ipc

#endif // THOTH_IPC_NOTIFY_FD
