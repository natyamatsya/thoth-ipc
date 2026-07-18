#pragma once

#include <cstdint>
#include <string>
#include <mutex>

#include "thoth-ipc/imp/windows_preamble.h"

#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/utility/scope_guard.h"
#include "thoth-ipc/platform/detail.h"
#include "thoth-ipc/mutex.h"
#include "thoth-ipc/semaphore.h"
#include "thoth-ipc/shm.h"

namespace thoth {
namespace detail {
namespace sync {

class condition {
    thoth::sync::semaphore sem_;
    thoth::sync::mutex lock_;
    thoth::shm::handle shm_;

    std::int32_t &counter() {
        return *static_cast<std::int32_t *>(shm_.get());
    }

public:
    condition() = default;
    ~condition() noexcept = default;

    auto native() noexcept {
        return sem_.native();
    }

    auto native() const noexcept {
        return sem_.native();
    }

    bool valid() const noexcept {
        return sem_.valid() && lock_.valid() && shm_.valid();
    }

    bool open(char const *name) noexcept {
        close();
        if (!sem_.open((std::string{name} + "_COND_SEM_").c_str())) {
            return false;
        }
        auto finally_sem = thoth::guard([this] { sem_.close(); }); // close when failed
        if (!lock_.open((std::string{name} + "_COND_LOCK_").c_str())) {
            return false;
        }
        auto finally_lock = thoth::guard([this] { lock_.close(); }); // close when failed
        if (!shm_.acquire((std::string{name} + "_COND_SHM_").c_str(), sizeof(std::int32_t))) {
            return false;
        }
        finally_lock.dismiss();
        finally_sem.dismiss();
        return valid();
    }

    void close() noexcept {
        if (!valid()) return;
        sem_.close();
        lock_.close();
        shm_.release();
    }

    void clear() noexcept {
        close();
    }

    static void clear_storage(char const *name) noexcept {
        thoth::shm::handle::clear_storage(name);
        thoth::sync::mutex::clear_storage(name);
        thoth::sync::semaphore::clear_storage(name);
    }

    bool wait(thoth::sync::mutex &mtx, std::uint64_t tm) noexcept {
        if (!valid()) return false;
        auto &cnt = counter();
        {
            THOTH_IPC_UNUSED std::lock_guard<thoth::sync::mutex> guard {lock_};
            cnt = (cnt < 0) ? 1 : cnt + 1;
        }
        DWORD ms = (tm == invalid_value) ? INFINITE : static_cast<DWORD>(tm);
        /**
         * \see
         *  - https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf
         *  - https://docs.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-signalobjectandwait
        */
        bool rs = ::SignalObjectAndWait(mtx.native(), sem_.native(), ms, FALSE) == WAIT_OBJECT_0;
        bool rl = mtx.lock(); // INFINITE
        if (!rs) {
            THOTH_IPC_UNUSED std::lock_guard<thoth::sync::mutex> guard {lock_};
            cnt -= 1;
        }
        return rs && rl;
    }

    bool notify(thoth::sync::mutex &) noexcept {
        if (!valid()) return false;
        auto &cnt = counter();
        if (!lock_.lock()) return false;
        bool ret = false;
        if (cnt > 0) {
            ret = sem_.post(1);
            cnt -= 1;
        }
        return lock_.unlock() && ret;
    }

    bool broadcast(thoth::sync::mutex &) noexcept {
        if (!valid()) return false;
        auto &cnt = counter();
        if (!lock_.lock()) return false;
        bool ret = false;
        if (cnt > 0) {
            ret = sem_.post(cnt);
            cnt = 0;
        }
        return lock_.unlock() && ret;
    }
};

} // namespace sync
} // namespace detail
} // namespace thoth
