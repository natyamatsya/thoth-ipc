
#include "thoth-ipc/imp/detect_plat.h"
#if defined(LIBIPC_CC_GNUC)
# include "thoth-ipc/platform/gnuc/demangle.h"
#else
# include "thoth-ipc/platform/win/demangle.h"
#endif
