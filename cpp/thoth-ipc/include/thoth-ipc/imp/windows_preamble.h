#pragma once

// Canonical, library-wide inclusion of <Windows.h>. Include THIS header instead
// of <Windows.h> directly anywhere in libipc's Windows code.
//
// Why centralise: WIN32_LEAN_AND_MEAN drops the legacy thread-pool wait API
// (RegisterWaitForSingleObject / UnregisterWaitEx) that the reactor depends on.
// Because <Windows.h> is include-guarded, a single header that pulled in the lean
// form first would silently strip those symbols from every other header sharing
// the translation unit — action-at-a-distance breakage that is painful to
// diagnose. Including here (never lean, and via the MinGW/MSVC filename split)
// guarantees every TU that uses our win headers sees the full Win32 surface.

#if defined(__MINGW32__)
#  include <windows.h>
#else
#  include <Windows.h>
#endif
