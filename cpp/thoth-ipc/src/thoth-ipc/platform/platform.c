
#include "thoth-ipc/platform/detail.h"
#if defined(LIBIPC_OS_WIN)
#elif defined(LIBIPC_OS_LINUX)
#include "thoth-ipc/platform/linux/a0/err.c"
#include "thoth-ipc/platform/linux/a0/mtx.c"
#include "thoth-ipc/platform/linux/a0/strconv.c"
#include "thoth-ipc/platform/linux/a0/tid.c"
#include "thoth-ipc/platform/linux/a0/time.c"
#elif defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD) || defined(LIBIPC_OS_APPLE)
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif
