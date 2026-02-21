#include "libipc/waiter.h"

#include "libipc/platform/detail.h"
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
namespace detail {

void waiter::init() {
    ipc::detail::sync::mutex::init();
}

} // namespace detail
} // namespace ipc
