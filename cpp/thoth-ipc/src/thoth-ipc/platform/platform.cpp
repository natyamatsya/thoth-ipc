
#include "thoth-ipc/platform/detail.h"
#if defined(THOTH_IPC_OS_WIN)
#include "thoth-ipc/platform/win/shm_win.cpp"
#elif defined(THOTH_IPC_OS_LINUX) || defined(THOTH_IPC_OS_QNX) || defined(THOTH_IPC_OS_FREEBSD) || defined(THOTH_IPC_OS_APPLE)
#include "thoth-ipc/platform/posix/shm_posix.cpp"
#else/*IPC_OS*/
#   error "Unsupported platform."
#endif
