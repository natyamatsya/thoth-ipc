#pragma once

#include <cstdint>

#include "thoth-ipc/imp/windows_preamble.h"

#include "thoth-ipc/imp/log.h"

#include "to_tchar.h"
#include "get_sa.h"

namespace thoth {
namespace detail {
namespace sync {

class semaphore {
    HANDLE h_ = NULL;

public:
    semaphore() noexcept = default;
    ~semaphore() noexcept = default;

    HANDLE native() const noexcept {
        return h_;
    }

    bool valid() const noexcept {
        return h_ != NULL;
    }

    bool open(char const *name, std::uint32_t count) noexcept {
        THOTH_IPC_LOG();
        close();
        h_ = ::CreateSemaphore(detail::get_sa(),
                               static_cast<LONG>(count), LONG_MAX,
                               detail::to_tchar(detail::win_object_name(name)).c_str());
        if (h_ == NULL) {
            log.error("fail CreateSemaphore[", static_cast<unsigned long>(::GetLastError()), "]: ", name);
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

    bool wait(std::uint64_t tm) noexcept {
        THOTH_IPC_LOG();
        DWORD ret, ms = (tm == invalid_value) ? INFINITE : static_cast<DWORD>(tm);
        switch ((ret = ::WaitForSingleObject(h_, ms))) {
        case WAIT_OBJECT_0:
            return true;
        case WAIT_TIMEOUT:
            return false;
        case WAIT_ABANDONED:
        default:
            log.error("fail WaitForSingleObject[", ::GetLastError(), "]: ", thoth::spec("#x")(ret));
            return false;
        }
    }

    bool post(std::uint32_t count) noexcept {
        THOTH_IPC_LOG();
        if (!::ReleaseSemaphore(h_, static_cast<LONG>(count), NULL)) {
            log.error("fail ReleaseSemaphore[", ::GetLastError(), "]");
            return false;
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace thoth
