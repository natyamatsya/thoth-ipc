#pragma once

// Layer 2 of the optional stdexec async-receive work (RFC:
// context/stdexec-async-recv-rfc.md): an opt-in senders/receivers (P2300)
// receive API.
//
//   template <stdexec::scheduler Scheduler>
//   sender-of<thoth::recv_result> async_recv(thoth::route& channel, Scheduler on);
//
// Following ADR-0001 (domain/exceptional errors travel as std::expected on the
// value channel), the sender's error channel is PRUNED — it never completes
// set_error. The returned sender completes:
//   * set_value(thoth::recv_result)  a message, or a recv_errc, hopped onto `on`;
//   * set_stopped()                when the receiver's stop_token is triggered.
// Exceptions from the receive (e.g. bad_alloc) are caught and mapped to a
// recv_errc, so a downstream ExpectedPipeline stays exception-free.
//
// A single process-global reactor thread (thoth::detail::reactor) multiplexes
// every async channel's Layer-1 fd, so N channels cost one thread instead of N.
// Only available when libipc is built with THOTH_IPC_STDEXEC (which also enables
// THOTH_IPC_NOTIFY_FD).

#include "thoth-ipc/imp/detect_plat.h"

#if defined(THOTH_IPC_STDEXEC)

#include <atomic>
#include <expected>
#include <new>
#include <optional>
#include <utility>

#include <stdexec/execution.hpp>

#include "thoth-ipc/ipc.h"
#include "thoth-ipc/execution/reactor.h"
#include "thoth-ipc/execution/wait_drain.h"  // detail::drain_wait_handle (no <unistd.h> here)
#include "thoth-ipc/execution/recv_result.h" // thoth::recv_errc / recv_result / recv_message

namespace thoth {

namespace detail {

// Operation state: waits (via the reactor) for the channel's fd to signal, reads
// one message, and completes on the receiver. Address-stable (the reactor holds
// `this`), so non-movable.
template <class Receiver, reactor_like R>
struct recv_op : reactor_waiter {
    thoth::route       *ch_;
    R                *reactor_; // injected multiplexer (never null after ctor)
    Receiver          rcvr_;
    thoth::wait_handle_t fd_   = thoth::invalid_wait_handle;
    bool              armed_ = false;
    std::atomic<bool> fired_{false}; // exactly one completion wins

    struct on_stop {
        recv_op *self;
        void operator()() noexcept { self->stop_requested(); }
    };
    using token_t = stdexec::stop_token_of_t<stdexec::env_of_t<Receiver>>;
    std::optional<stdexec::stop_callback_for_t<token_t, on_stop>> stop_cb_;

    recv_op(thoth::route *ch, R *r, Receiver rcvr)
        : ch_(ch), reactor_(r), rcvr_(std::move(rcvr)) {}
    recv_op(recv_op &&) = delete;

    void start() noexcept {
        auto tok = stdexec::get_stop_token(stdexec::get_env(rcvr_));
        if (tok.stop_requested()) {
            stdexec::set_stopped(std::move(rcvr_));
            return;
        }
        fd_ = ch_->native_wait_handle();
        if (fd_ == thoth::invalid_wait_handle) {
            // Pruned error channel: surface the misconfiguration as data.
            stdexec::set_value(std::move(rcvr_),
                               recv_result{std::unexpected(recv_errc::no_readiness_handle)});
            return;
        }
        stop_cb_.emplace(std::move(tok), on_stop{this});
        // A message may already be queued: try before paying for reactor arming.
        if (deliver_if_ready()) return;
        armed_ = true;
        reactor_->add(fd_, this); // fd is level-triggered: fires if data raced in
    }

    // Reactor thread. Drain the readiness handle, then read at most one message.
    disposition on_ready() noexcept override {
        detail::drain_wait_handle(fd_);
        return deliver_if_ready() ? disposition::remove : disposition::keep;
    }

    // Consumer thread (stop callback).
    void stop_requested() noexcept {
        if (fired_.exchange(true, std::memory_order_acq_rel)) return; // value won
        if (armed_) reactor_->remove(fd_, this); // synchronous: safe to complete
        stdexec::set_stopped(std::move(rcvr_));
    }

    // Completes the receiver iff a message (or an error) is ready. Returns false
    // only when the channel is currently empty — no completion, stay armed.
    // Exceptions from the receive are caught and mapped to a recv_errc so the
    // pruned (exception-free) value channel is honoured.
    bool deliver_if_ready() noexcept {
        recv_result result{std::unexpected(recv_errc::unknown)};
        try {
            thoth::buff_t buff = ch_->try_recv();
            if (buff.empty()) return false; // no message yet — keep waiting
            result = std::move(buff);
        } catch (std::bad_alloc const &) {
            result = std::unexpected(recv_errc::out_of_memory);
        } catch (...) {
            result = std::unexpected(recv_errc::unknown);
        }
        if (fired_.exchange(true, std::memory_order_acq_rel)) {
            // Cancellation won concurrently; the result is dropped as part of
            // teardown (documented cancellation race).
            return true;
        }
        stdexec::set_value(std::move(rcvr_), std::move(result));
        return true;
    }
};

// The custom sender feeding recv_op. Kept internal; async_recv() wraps it with
// continues_on so completions land on the caller's scheduler.
template <reactor_like R>
struct read_sender {
    using sender_concept = stdexec::sender_t;
    // Pruned error channel: value carries thoth::recv_result (message or recv_errc),
    // cancellation is set_stopped. No set_error — stays exception-free.
    using completion_signatures = stdexec::completion_signatures<
        stdexec::set_value_t(thoth::recv_result),
        stdexec::set_stopped_t()>;

    thoth::route *ch_;
    R          *reactor_;

    template <class Receiver>
    recv_op<Receiver, R> connect(Receiver rcvr) const {
        return recv_op<Receiver, R>{ch_, reactor_, std::move(rcvr)};
    }
};

} // namespace detail

/**
 * \brief Asynchronously receive one message from `channel`, without a dedicated
 *        blocking thread.
 *
 * \param channel  A receiver-mode thoth::route/thoth::channel exposing a readiness
 *                 handle (libipc built with THOTH_IPC_NOTIFY_FD).
 * \param on       Scheduler the completion is delivered on.
 * \returns A sender completing set_value(thoth::recv_result) / set_stopped(). The
 *          error channel is pruned; failures arrive as recv_errc in the value.
 *
 * Compose it into a reader loop, e.g. with exec::repeat_effect_until, in place
 * of a std::jthread + blocking recv().
 */
template <stdexec::scheduler Scheduler>
stdexec::sender auto async_recv(thoth::route &channel, Scheduler on) {
    return stdexec::continues_on(
        detail::read_sender<detail::reactor>{&channel, &detail::reactor::instance()},
        std::move(on));
}

/**
 * \brief As above, but multiplexed on a caller-supplied reactor.
 *
 * Lets a consumer run its own reactor instance, or a test inject a fake (any
 * type modelling thoth::detail::reactor_like) to drive on_ready() deterministically
 * without the real kqueue/epoll thread.
 */
template <stdexec::scheduler Scheduler, detail::reactor_like R>
stdexec::sender auto async_recv(thoth::route &channel, Scheduler on, R &reactor) {
    return stdexec::continues_on(
        detail::read_sender<R>{&channel, &reactor}, std::move(on));
}

} // namespace thoth

#endif // THOTH_IPC_STDEXEC
