
#include "libipc/mutex.h"

#include "libipc/utility/pimpl.h"
#include "libipc/imp/log.h"
#include "libipc/mem/resource.h"
#include "libipc/platform/detail.h"
#include "libipc/sync/sync_abi.h"
#if defined(LIBIPC_OS_WIN)
#include "libipc/platform/win/mutex.h"
#elif defined(LIBIPC_OS_LINUX)
#include "libipc/platform/linux/mutex.h"
#elif defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD)
#include "libipc/platform/posix/mutex.h"
#elif defined(LIBIPC_OS_APPLE)
#  if defined(LIBIPC_APPLE_APP_STORE_SAFE)
#    include "libipc/platform/apple/mach/mutex.h"
#  else
#    include "libipc/platform/apple/mutex.h"
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
    LIBIPC_LOG();
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
