#pragma once

#include <cstdint>
#include <system_error>

#include "thoth-ipc/imp/windows_preamble.h"

#include "thoth-ipc/imp/log.h"

#include "to_tchar.h"
#include "get_sa.h"

namespace thoth {
namespace detail {
namespace sync {

class mutex {
    HANDLE h_ = NULL;

public:
    mutex() noexcept = default;
    ~mutex() noexcept = default;

    static void init() {}

    HANDLE native() const noexcept {
        return h_;
    }

    bool valid() const noexcept {
        return h_ != NULL;
    }

    bool open(char const *name) noexcept {
        THOTH_IPC_LOG();
        close();
        h_ = ::CreateMutex(detail::get_sa(), FALSE, detail::to_tchar(detail::win_object_name(name)).c_str());
        if (h_ == NULL) {
            log.error("fail CreateMutex[", static_cast<unsigned long>(::GetLastError()), "]: ", name);
            return false;
        }
        return true;
    }

    void close() noexcept {
        if (!valid()) return;
        ::CloseHandle(h_);
        h_ = NULL;
    }

    void clear() noexcept {
        close();
    }

    static void clear_storage(char const * /*name*/) noexcept {
    }

    bool lock(std::uint64_t tm) noexcept {
        THOTH_IPC_LOG();
        DWORD ret, ms = (tm == invalid_value) ? INFINITE : static_cast<DWORD>(tm);
        for(;;) {
            switch ((ret = ::WaitForSingleObject(h_, ms))) {
            case WAIT_OBJECT_0:
                return true;
            case WAIT_TIMEOUT:
                return false;
            case WAIT_ABANDONED:
                log.warning("fail WaitForSingleObject[", ::GetLastError(), "]: WAIT_ABANDONED, try again.");
                if (!unlock()) {
                    return false;
                }
                break; // loop again
            default:
                log.error("fail WaitForSingleObject[", ::GetLastError(), "]: ", thoth::spec("#x")(ret));
                return false;
            }
        }
    }

    bool try_lock() noexcept(false) {
        THOTH_IPC_LOG();
        DWORD ret = ::WaitForSingleObject(h_, 0);
        switch (ret) {
        case WAIT_OBJECT_0:
            return true;
        case WAIT_TIMEOUT:
            return false;
        case WAIT_ABANDONED:
            unlock();
            THOTH_IPC_FALLTHROUGH;
        default:
            log.error("fail WaitForSingleObject[", ::GetLastError(), "]: ", thoth::spec("#x")(ret));
            throw std::system_error{static_cast<int>(ret), std::system_category()};
        }
    }

    bool unlock() noexcept {
        THOTH_IPC_LOG();
        if (!::ReleaseMutex(h_)) {
            log.error("fail ReleaseMutex[", ::GetLastError(), "]");
            return false;
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace thoth
