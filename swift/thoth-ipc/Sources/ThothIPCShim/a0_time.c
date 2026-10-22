// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// The vendored alephzero time.c that C++ builds (vendor/ links to
// cpp/thoth-ipc/src/thoth-ipc/platform/linux), compiled into the shim on
// Linux so Swift runs the same robust PI futex mutex and requeue-PI condition.

#if defined(__linux__)
#include "a0/time.c"
#endif
