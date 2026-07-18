#pragma once

// The value type shared by both async-receive front ends — the stdexec
// senders/receivers API (async_recv.h) and the coroutine API (coro_recv.h). It
// carries a received message or a recv_errc, so a pruned/exception-free pipeline
// stays data-only. No stdexec dependency: available whenever Layer 1
// (THOTH_IPC_NOTIFY_FD) is on.

#include "thoth-ipc/imp/detect_plat.h"

#if defined(THOTH_IPC_NOTIFY_FD)

#include <expected>

#include "thoth-ipc/ipc.h"

namespace thoth {

/// \brief Error codes carried on the async-receive value channel (the error type
/// of thoth::recv_result). Because the error channel is pruned, these are data.
enum class recv_errc {
    no_readiness_handle = 1, ///< channel has no native_wait_handle (build with
                             ///< THOTH_IPC_NOTIFY_FD and connect as a receiver)
    out_of_memory,           ///< allocation failed while receiving
    unknown,                 ///< any other exception surfaced by the receive
};

/// \brief Human-readable description of a recv_errc.
inline char const *recv_message(recv_errc e) noexcept {
    switch (e) {
    case recv_errc::no_readiness_handle:
        return "ipc async recv: channel has no readiness handle "
               "(build with THOTH_IPC_NOTIFY_FD and connect as a receiver)";
    case recv_errc::out_of_memory: return "ipc async recv: out of memory while receiving";
    case recv_errc::unknown:       return "ipc async recv: unknown error while receiving";
    }
    return "ipc async recv: unrecognized recv_errc";
}

/// \brief What an async receive delivers: a received message, or a recv_errc
/// describing why one could not be produced.
using recv_result = std::expected<thoth::buff_t, recv_errc>;

} // namespace thoth

#endif // THOTH_IPC_NOTIFY_FD
