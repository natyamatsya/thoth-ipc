
#include "thoth-ipc/mutex.h"

#include "thoth-ipc/utility/pimpl.h"
#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/mem/resource.h"
#include "thoth-ipc/platform/detail.h"
#include "thoth-ipc/sync/sync_abi.h"
#if defined(THOTH_IPC_OS_WIN)
#include "thoth-ipc/platform/win/mutex.h"
#elif defined(THOTH_IPC_OS_LINUX)
#include "thoth-ipc/platform/linux/mutex.h"
#elif defined(THOTH_IPC_OS_QNX) || defined(THOTH_IPC_OS_FREEBSD)
#include "thoth-ipc/platform/posix/mutex.h"
#elif defined(THOTH_IPC_OS_APPLE)
#  if defined(THOTH_IPC_APPLE_APP_STORE_SAFE)
#    include "thoth-ipc/platform/apple/mach/mutex.h"
#  else
#    include "thoth-ipc/platform/apple/mutex.h"
#  endif
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif

namespace ipc {
namespace sync {

class mutex::mutex_ : public ipc::pimpl<mutex_> {
public:
    ipc::detail::sync::mutex lock_;
    ipc::detail::sync_abi::guard abi_guard_;
};

mutex::mutex()
    : p_(p_->make()) {
}

mutex::mutex(char const * name)
    : mutex() {
    open(name);
}

mutex::~mutex() {
    close();
    p_->clear();
}

void const *mutex::native() const noexcept {
    return impl(p_)->lock_.native();
}

void *mutex::native() noexcept {
    return impl(p_)->lock_.native();
}

bool mutex::valid() const noexcept {
    return impl(p_)->lock_.valid();
}

bool mutex::open(char const *name) noexcept {
    THOTH_IPC_LOG();
    if (!is_valid_string(name)) {
        log.error("fail mutex open: name is empty");
        return false;
    }
    auto *self = impl(p_);
    if (!self->abi_guard_.open_mutex(name)) return false;
    if (self->lock_.open(name)) return true;
    self->abi_guard_.close();
    return false;
}

void mutex::close() noexcept {
    auto *self = impl(p_);
    self->lock_.close();
    self->abi_guard_.close();
}

void mutex::clear() noexcept {
    auto *self = impl(p_);
    self->lock_.clear();
    self->abi_guard_.clear();
}

void mutex::clear_storage(char const * name) noexcept {
    ipc::detail::sync_abi::guard::clear_mutex_storage(name);
    ipc::detail::sync::mutex::clear_storage(name);
}

bool mutex::lock(std::uint64_t tm) noexcept {
    return impl(p_)->lock_.lock(tm);
}

bool mutex::try_lock() noexcept(false) {
    return impl(p_)->lock_.try_lock();
}

bool mutex::unlock() noexcept {
    return impl(p_)->lock_.unlock();
}

} // namespace sync
} // namespace ipc
