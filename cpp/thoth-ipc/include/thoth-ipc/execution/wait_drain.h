#pragma once

// Drain a Layer-1 readiness handle after it signalled, keeping <unistd.h>/::read
// out of the public front-end headers (async_recv.h, coro_recv.h) so they stay
// platform-neutral. POSIX readiness is level-triggered (an fd carrying wake
// tokens that must be consumed); a Windows auto-reset Event self-resets when a
// wait wakes on it, so there is nothing to drain.

#include "thoth-ipc/imp/detect_plat.h"

#if defined(THOTH_IPC_NOTIFY_FD)

#include "thoth-ipc/ipc.h" // ipc::wait_handle_t

#if !defined(THOTH_IPC_OS_WIN)
#  include <unistd.h>
#endif

namespace ipc {
namespace detail {

inline void drain_wait_handle(wait_handle_t h) noexcept {
#if defined(THOTH_IPC_OS_WIN)
    (void)h; // auto-reset event self-resets on wake — nothing to drain
#else
    char buf[256];
    int fd = static_cast<int>(h);
    while (::read(fd, buf, sizeof(buf)) > 0) { /* discard readiness tokens */ }
#endif
}

} // namespace detail
} // namespace ipc

#endif // THOTH_IPC_NOTIFY_FD
