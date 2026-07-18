#include "thoth-ipc/waiter.h"

#include "thoth-ipc/platform/detail.h"
#if defined(LIBIPC_OS_WIN)
#include "thoth-ipc/platform/win/mutex.h"
#elif defined(LIBIPC_OS_LINUX)
#include "thoth-ipc/platform/linux/mutex.h"
#elif defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD)
#include "thoth-ipc/platform/posix/mutex.h"
#elif defined(LIBIPC_OS_APPLE)
#  if defined(LIBIPC_APPLE_APP_STORE_SAFE)
#    include "thoth-ipc/platform/apple/mach/mutex.h"
#  else
#    include "thoth-ipc/platform/apple/mutex.h"
#  endif
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif

namespace ipc {
namespace detail {

void waiter::init() {
    ipc::detail::sync::mutex::init();
}

} // namespace detail
} // namespace ipc
