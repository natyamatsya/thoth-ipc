
#include "libipc/condition.h"

#include "libipc/utility/pimpl.h"
#include "libipc/imp/log.h"
#include "libipc/mem/resource.h"
#include "libipc/platform/detail.h"
#include "libipc/sync/sync_abi.h"
#if defined(LIBIPC_OS_WIN)
#include "libipc/platform/win/condition.h"
#elif defined(LIBIPC_OS_LINUX)
#include "libipc/platform/linux/condition.h"
#elif defined(LIBIPC_OS_APPLE)
#  if defined(LIBIPC_APPLE_APP_STORE_SAFE)
#    include "libipc/platform/apple/mach/condition.h"
#  else
#    include "libipc/platform/apple/condition.h"
#  endif
#elif defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD)
#include "libipc/platform/posix/condition.h"
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif

namespace ipc {
namespace sync {

class condition::condition_ : public ipc::pimpl<condition_> {
public:
    ipc::detail::sync::condition cond_;
    ipc::detail::sync_abi::guard abi_guard_;
};

condition::condition()
    : p_(p_->make()) {
}

condition::condition(char const * name)
    : condition() {
    open(name);
}

condition::~condition() {
    close();
    p_->clear();
}

void const *condition::native() const noexcept {
    return impl(p_)->cond_.native();
}

void *condition::native() noexcept {
    return impl(p_)->cond_.native();
}

bool condition::valid() const noexcept {
    return impl(p_)->cond_.valid();
}

bool condition::open(char const *name) noexcept {
    LIBIPC_LOG();
    if (!is_valid_string(name)) {
        log.error("fail condition open: name is empty");
        return false;
    }
    auto *self = impl(p_);
    if (!self->abi_guard_.open_condition(name)) return false;
    if (self->cond_.open(name)) return true;
    self->abi_guard_.close();
    return false;
}

void condition::close() noexcept {
    auto *self = impl(p_);
    self->cond_.close();
    self->abi_guard_.close();
}

void condition::clear() noexcept {
    auto *self = impl(p_);
    self->cond_.clear();
    self->abi_guard_.clear();
}

void condition::clear_storage(char const * name) noexcept {
    ipc::detail::sync_abi::guard::clear_condition_storage(name);
    ipc::detail::sync::condition::clear_storage(name);
}

bool condition::wait(ipc::sync::mutex &mtx, std::uint64_t tm) noexcept {
    return impl(p_)->cond_.wait(mtx, tm);
}

bool condition::notify(ipc::sync::mutex &mtx) noexcept {
    return impl(p_)->cond_.notify(mtx);
}

bool condition::broadcast(ipc::sync::mutex &mtx) noexcept {
    return impl(p_)->cond_.broadcast(mtx);
}

} // namespace sync
} // namespace ipc
