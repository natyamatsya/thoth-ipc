#pragma once

// Path (b): a **stdexec-free** C++20-coroutine front end for async receive.
// `co_await ipc::async_recv_co(route)` suspends the coroutine, parks its
// readiness fd (Layer 1 native_wait_handle) on the shared process-global reactor
// (reactor.h — no stdexec), and resumes with an ipc::recv_result. Mirrors the
// stdexec recv_op, but resumes a coroutine handle instead of completing a P2300
// receiver. Needs only LIBIPC_NOTIFY_FD (+ C++20 coroutines, C++23 std::expected).
//
// For consumers who already use stdexec, prefer path (a): stdexec senders are
// awaitable, so `co_await ipc::async_recv(route, sched)` works in an exec::task<>
// with structured cancellation. This path is for coroutine users who do NOT want
// the stdexec dependency.
//
// Semantics: single-consumer (drive from one coroutine at a time). The coroutine
// resumes on the reactor thread — hop to your own executor after if needed.
// Destroying the coroutine while a co_await is suspended is safe: the awaiter
// synchronously unregisters from the reactor in its destructor.

#include "libipc/imp/detect_plat.h"

#if defined(LIBIPC_NOTIFY_FD)

#include <atomic>
#include <coroutine>
#include <exception>
#include <optional>
#include <semaphore>
#include <utility>

#include "libipc/ipc.h"
#include "libipc/execution/reactor.h"
#include "libipc/execution/wait_drain.h" // detail::drain_wait_handle (no <unistd.h> here)
#include "libipc/execution/recv_result.h"

namespace ipc {
namespace coro {

// Awaiter for a single async receive. Address-stable while suspended (the reactor
// holds `this`); lives on the awaiting coroutine's frame.
class recv_awaitable : public detail::reactor_waiter {
    ipc::route     *ch_;
    detail::reactor *reactor_;
    ipc::wait_handle_t fd_  = ipc::invalid_wait_handle;
    bool             armed_ = false;
    std::atomic<bool> done_{false}; // arbitrates on_ready vs destructor (cancel)
    std::coroutine_handle<> waiting_{};
    recv_result      result_{std::unexpected(recv_errc::unknown)};

public:
    explicit recv_awaitable(ipc::route &ch,
                            detail::reactor &r = detail::reactor::instance()) noexcept
        : ch_(&ch), reactor_(&r) {}
    recv_awaitable(recv_awaitable &&) = delete;
    recv_awaitable &operator=(recv_awaitable &&) = delete;

    ~recv_awaitable() {
        // Coroutine destroyed while parked: unregister synchronously so the
        // reactor never touches this dead frame.
        if (armed_ && !done_.exchange(true, std::memory_order_acq_rel)) {
            reactor_->remove(fd_, this);
        }
    }

    bool await_ready() noexcept {
        fd_ = ch_->native_wait_handle();
        if (fd_ == ipc::invalid_wait_handle) {
            result_ = std::unexpected(recv_errc::no_readiness_handle);
            return true; // complete synchronously, no suspend
        }
        return try_deliver(); // fast path: a message may already be queued
    }

    void await_suspend(std::coroutine_handle<> h) noexcept {
        waiting_ = h;
        armed_ = true;
        reactor_->add(fd_, this); // asynchronous; the fd is level-triggered
    }

    recv_result await_resume() noexcept { return std::move(result_); }

    // Reactor thread: drain the readiness fd, read one message, resume the coroutine.
    disposition on_ready() noexcept override {
        detail::drain_wait_handle(fd_);
        if (!try_deliver()) return disposition::keep; // spurious — stay parked
        armed_ = false;
        if (done_.exchange(true, std::memory_order_acq_rel)) {
            // Cancellation won (coroutine being destroyed); do not resume.
            return disposition::remove;
        }
        // resume() may run the coroutine to a point that destroys `this`; touch
        // nothing on `this` afterwards (returning a local enum is fine).
        waiting_.resume();
        return disposition::remove;
    }

private:
    bool try_deliver() noexcept {
        try {
            ipc::buff_t buff = ch_->try_recv();
            if (buff.empty()) return false;
            result_ = std::move(buff);
        } catch (std::bad_alloc const &) {
            result_ = std::unexpected(recv_errc::out_of_memory);
        } catch (...) {
            result_ = std::unexpected(recv_errc::unknown);
        }
        return true;
    }
};

/// Await one message from `channel` (a receiver-mode route/channel with a
/// readiness handle). `co_await ipc::coro::async_recv_co(ch)` -> ipc::recv_result.
inline recv_awaitable async_recv_co(ipc::route &channel) noexcept {
    return recv_awaitable{channel};
}
inline recv_awaitable async_recv_co(ipc::route &channel, detail::reactor &r) noexcept {
    return recv_awaitable{channel, r};
}

// ---------------------------------------------------------------------------
// A minimal batteries-included coroutine task, so path (b) is usable without any
// external coroutine library. Lazy; run it to completion with sync_wait().
// ---------------------------------------------------------------------------

template <class T>
class task {
public:
    struct promise_type {
        std::optional<T>          value_;
        std::exception_ptr        exc_;
        std::binary_semaphore    *done_ = nullptr;

        task get_return_object() noexcept {
            return task{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        auto final_suspend() noexcept {
            struct awaiter {
                bool await_ready() noexcept { return false; }
                void await_suspend(std::coroutine_handle<promise_type> h) noexcept {
                    if (auto *s = h.promise().done_) s->release();
                }
                void await_resume() noexcept {}
            };
            return awaiter{};
        }
        template <class U>
        void return_value(U &&v) { value_.emplace(std::forward<U>(v)); }
        void unhandled_exception() { exc_ = std::current_exception(); }
    };

    using handle = std::coroutine_handle<promise_type>;

    task(task &&o) noexcept : h_(std::exchange(o.h_, {})) {}
    task &operator=(task &&) = delete;
    ~task() { if (h_) h_.destroy(); }

    /// Run the coroutine to completion (blocking) and return its value. The
    /// coroutine may complete on the reactor thread; this blocks until it does.
    T sync_wait() {
        std::binary_semaphore done{0};
        h_.promise().done_ = &done;
        h_.resume();          // lazy start; suspends on the reactor if it awaits
        done.acquire();       // released at final_suspend (any thread)
        if (h_.promise().exc_) std::rethrow_exception(h_.promise().exc_);
        return std::move(*h_.promise().value_);
    }

private:
    explicit task(handle h) noexcept : h_(h) {}
    handle h_{};
};

// void specialization.
template <>
class task<void> {
public:
    struct promise_type {
        std::exception_ptr     exc_;
        std::binary_semaphore *done_ = nullptr;

        task get_return_object() noexcept {
            return task{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        auto final_suspend() noexcept {
            struct awaiter {
                bool await_ready() noexcept { return false; }
                void await_suspend(std::coroutine_handle<promise_type> h) noexcept {
                    if (auto *s = h.promise().done_) s->release();
                }
                void await_resume() noexcept {}
            };
            return awaiter{};
        }
        void return_void() noexcept {}
        void unhandled_exception() { exc_ = std::current_exception(); }
    };

    using handle = std::coroutine_handle<promise_type>;

    task(task &&o) noexcept : h_(std::exchange(o.h_, {})) {}
    task &operator=(task &&) = delete;
    ~task() { if (h_) h_.destroy(); }

    void sync_wait() {
        std::binary_semaphore done{0};
        h_.promise().done_ = &done;
        h_.resume();
        done.acquire();
        if (h_.promise().exc_) std::rethrow_exception(h_.promise().exc_);
    }

private:
    explicit task(handle h) noexcept : h_(h) {}
    handle h_{};
};

} // namespace coro
} // namespace ipc

#endif // LIBIPC_NOTIFY_FD
