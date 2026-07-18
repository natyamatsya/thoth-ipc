
#include "thoth-ipc/imp/detect_plat.h"
#if defined(LIBIPC_OS_WIN)
# include "thoth-ipc/platform/win/system.h"
#else
# include "thoth-ipc/platform/posix/system.h"
#endif
