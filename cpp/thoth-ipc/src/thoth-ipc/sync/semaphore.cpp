
#include "thoth-ipc/semaphore.h"

#include "thoth-ipc/utility/pimpl.h"
#include "thoth-ipc/imp/log.h"
#include "thoth-ipc/mem/resource.h"
#include "thoth-ipc/platform/detail.h"
#if defined(THOTH_IPC_OS_WIN)
#include "thoth-ipc/platform/win/semaphore.h"
#elif defined(THOTH_IPC_OS_LINUX) || defined(THOTH_IPC_OS_QNX) || defined(THOTH_IPC_OS_FREEBSD)
#include "thoth-ipc/platform/posix/semaphore_impl.h"
#elif defined(THOTH_IPC_OS_APPLE)
#  if defined(THOTH_IPC_APPLE_APP_STORE_SAFE)
#    include "thoth-ipc/platform/apple/mach/semaphore_impl.h"
#  else
#    include "thoth-ipc/platform/apple/semaphore_impl.h"
#  endif
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif

namespace thoth {
namespace sync {

class semaphore::semaphore_ : public thoth::pimpl<semaphore_> {
public:
    thoth::detail::sync::semaphore sem_;
};

semaphore::semaphore()
    : p_(p_->make()) {
}

semaphore::semaphore(char const * name, std::uint32_t count)
    : semaphore() {
    open(name, count);
}

semaphore::~semaphore() {
    close();
    p_->clear();
}

void const *semaphore::native() const noexcept {
    return impl(p_)->sem_.native();
}

void *semaphore::native() noexcept {
    return impl(p_)->sem_.native();
}

bool semaphore::valid() const noexcept {
    return impl(p_)->sem_.valid();
}

bool semaphore::open(char const *name, std::uint32_t count) noexcept {
    THOTH_IPC_LOG();
    if (!is_valid_string(name)) {
        log.error("fail semaphore open: name is empty");
        return false;
    }
    return impl(p_)->sem_.open(name, count);
}

void semaphore::close() noexcept {
    impl(p_)->sem_.close();
}

void semaphore::clear() noexcept {
    impl(p_)->sem_.clear();
}

void semaphore::clear_storage(char const * name) noexcept {
    thoth::detail::sync::semaphore::clear_storage(name);
}

bool semaphore::wait(std::uint64_t tm) noexcept {
    return impl(p_)->sem_.wait(tm);
}

bool semaphore::post(std::uint32_t count) noexcept {
    return impl(p_)->sem_.post(count);
}

} // namespace sync
} // namespace thoth
