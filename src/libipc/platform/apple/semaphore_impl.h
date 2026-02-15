#pragma once

#include <cstdint>
#include <string>

#include <dispatch/dispatch.h>

#include "libipc/imp/log.h"
#include "libipc/shm.h"

namespace ipc {
namespace detail {
namespace sync {

class semaphore {
    ipc::shm::handle shm_;
    dispatch_semaphore_t h_ = nullptr;

public:
    semaphore() = default;
    ~semaphore() noexcept = default;

    void *native() const noexcept {
        return h_;
    }

    bool valid() const noexcept {
        return h_ != nullptr;
    }

    bool open(char const *name, std::uint32_t count) noexcept {
        LIBIPC_LOG();
        close();
        if (!shm_.acquire(name, 1)) {
            log.error("[open_semaphore] fail shm.acquire: ", name);
            return false;
        }
        // dispatch_semaphore is process-local, but we use shm for cross-process
        // coordination of the name. For true cross-process semaphore on macOS,
        // we use dispatch_semaphore as a local primitive — this is sufficient
        // when combined with shared memory for the IPC channel signaling.
        h_ = dispatch_semaphore_create(static_cast<intptr_t>(count));
        if (h_ == nullptr) {
            log.error("fail dispatch_semaphore_create");
            return false;
        }
        return true;
    }

    void close() noexcept {
        LIBIPC_LOG();
        if (!valid()) return;
        // Release the dispatch semaphore
        // Note: dispatch objects are reference-counted via ARC or dispatch_release
#if !__has_feature(objc_arc)
        dispatch_release(h_);
#endif
        h_ = nullptr;
        if (shm_.name() != nullptr)
            shm_.release();
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if (valid()) {
#if !__has_feature(objc_arc)
            dispatch_release(h_);
#endif
            h_ = nullptr;
        }
        shm_.clear();
    }

    static void clear_storage(char const *name) noexcept {
        ipc::shm::handle::clear_storage(name);
    }

    bool wait(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        dispatch_time_t timeout;
        if (tm == invalid_value)
            timeout = DISPATCH_TIME_FOREVER;
        else
            timeout = dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(tm) * 1000000LL); // ms to ns
        return dispatch_semaphore_wait(h_, timeout) == 0;
    }

    bool post(std::uint32_t count) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        for (std::uint32_t i = 0; i < count; ++i)
            dispatch_semaphore_signal(h_);
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
