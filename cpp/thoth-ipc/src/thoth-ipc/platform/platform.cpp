
#include "thoth-ipc/platform/detail.h"
#if defined(LIBIPC_OS_WIN)
#include "thoth-ipc/platform/win/shm_win.cpp"
#elif defined(LIBIPC_OS_LINUX) || defined(LIBIPC_OS_QNX) || defined(LIBIPC_OS_FREEBSD) || defined(LIBIPC_OS_APPLE)
#include "thoth-ipc/platform/posix/shm_posix.cpp"
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif
